-- COE Conciliación · v3.5 · Cortes retroactivos (desde el 1 de enero de 2026)
-- Administración o Contabilidad crean un corte de una fecha pasada como borrador, suben los comprobantes
-- en uno o varios momentos y lo cierran con PIN. Queda marcado como retroactivo (quién y cuándo lo subió).
-- No borra datos.

alter table con_turnos add column if not exists retroactivo boolean not null default false;
alter table con_turnos add column if not exists retro_por uuid references con_usuarios(id);
alter table con_turnos add column if not exists retro_en timestamptz;
alter table con_turnos drop constraint if exists con_turnos_estado_check;
alter table con_turnos add constraint con_turnos_estado_check
  check (estado in ('abierto','cuadrado','revisar','sobrante','faltante','sin_cierre','retro'));

-- Edición de comprobantes del borrador retroactivo
create or replace function _con_puede_editar(p_u con_usuarios, t con_turnos) returns boolean
language sql stable as $$
  select ((t.usuario_id = p_u.id or coalesce(t.responsable_id, t.usuario_id) = p_u.id or p_u.rol = 'admin')
          and (t.estado = 'abierto' or (t.estado = 'sin_cierre' and t.aclarado_en is null)))
      or (t.estado = 'retro' and p_u.rol in ('admin','contabilidad'))
$$;

do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('con_registrar_evidencia(uuid,uuid,text,text,text,text)'::regprocedure);
  if position('''retro''' in v) = 0 then
    a := $a$  if coalesce(t.responsable_id, t.usuario_id) <> u.id and t.usuario_id <> u.id and u.rol <> 'admin' then$a$;
    b := $b$  if not (t.estado = 'abierto' or u.rol = 'admin' or (t.estado = 'sin_cierre' and t.aclarado_en is null)) then$b$;
    if position(a in v) = 0 or position(b in v) = 0 then raise exception 'con_registrar_evidencia: patrón'; end if;
    v := replace(v, a, $n$  if coalesce(t.responsable_id, t.usuario_id) <> u.id and t.usuario_id <> u.id and u.rol <> 'admin'
     and not (t.estado = 'retro' and u.rol = 'contabilidad') then$n$);
    v := replace(v, b, $n$  if not (t.estado = 'abierto' or u.rol = 'admin' or (t.estado = 'sin_cierre' and t.aclarado_en is null)
          or (t.estado = 'retro' and u.rol = 'contabilidad')) then$n$);
    execute v;
  end if;
end $$;

-- Lista de cortes retroactivos y catálogo para crear uno
create or replace function con_retro_lista(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  return jsonb_build_object(
    'turnos', coalesce((select jsonb_agg(x order by x->>'orden' desc) from (
        select jsonb_build_object('id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja', c.nombre, 'sucursal', s.nombre,
          'usuario', uu.nombre, 'estado', t.estado, 'dif_total', t.dif_total, 'retro_en', t.retro_en,
          'retro_por', (select nombre from con_usuarios where id = t.retro_por),
          'docs', (select count(*) from con_evidencias e where e.turno_id = t.id and e.lectura_estado not in ('descartado','rechazado')),
          'orden', case when t.estado = 'retro' then '2' else '1' end || to_char(t.retro_en, 'YYYYMMDDHH24MISS')) x
        from con_turnos t join con_cajas c on c.id = t.caja_id join con_sucursales s on s.id = c.sucursal_id
        join con_usuarios uu on uu.id = t.usuario_id
        where t.retroactivo and _con_ve_sucursal(u, s.id)
          and (t.estado = 'retro' or t.retro_en > now() - interval '90 days')) q), '[]'::jsonb),
    'cajas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre, 'sucursal', s.nombre,
          'sucursal_id', s.id, 'modo', c.modo_efectivo) order by s.nombre, c.nombre)
        from con_cajas c join con_sucursales s on s.id = c.sucursal_id
        where c.activa and s.activa and c.modo_efectivo <> 'pagos' and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'usuarios', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre,
          'sucursales', (select coalesce(jsonb_agg(sucursal_id), '[]'::jsonb) from con_usuario_sucursal where usuario_id = x.id))
          order by x.nombre)
        from con_usuarios x where x.rol in ('cajero','supervisor','admin')), '[]'::jsonb),
    'minimo', '2026-01-01');
end $$;

create or replace function con_retro_crear(p_token uuid, p_caja uuid, p_fecha date, p_turno text, p_cajera uuid,
                                           p_fondo_ini numeric, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; c con_cajas; v_id uuid; v_hoy date; v_ex record;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into c from con_cajas where id = p_caja and activa;
  if not found or not _con_ve_sucursal(u, c.sucursal_id) then raise exception 'Caja no encontrada.'; end if;
  if c.modo_efectivo = 'pagos' then raise exception 'La caja de pagos no admite cortes retroactivos.'; end if;
  v_hoy := _con_hoy(c.sucursal_id);
  if p_fecha is null or p_fecha < date '2026-01-01' or p_fecha >= v_hoy then
    raise exception 'La fecha debe ser entre el 01/01/2026 y ayer.';
  end if;
  if p_turno not in ('matutino','comida','vespertino') then raise exception 'Elige el turno.'; end if;
  if not exists (select 1 from con_usuarios where id = p_cajera) then raise exception 'Elige quién trabajó ese turno.'; end if;
  if coalesce(p_fondo_ini, 0) < 0 then raise exception 'El fondo no puede ser negativo.'; end if;
  select t.estado, t.retroactivo into v_ex from con_turnos t
   where t.caja_id = p_caja and t.fecha = p_fecha and t.turno = p_turno limit 1;
  if found then
    raise exception 'Ya existe el corte de % · % del %.%', c.nombre, initcap(p_turno), to_char(p_fecha, 'DD/MM/YYYY'),
      case when v_ex.estado = 'retro' then ' Es un borrador retroactivo: continúalo desde la lista.' else '' end;
  end if;
  insert into con_turnos(caja_id, fecha, turno, usuario_id, es_cobertura, fondo_inicial, fondo_inicial_total,
                         nota_apertura, estado, retroactivo, retro_por, retro_en, abierto_en)
  values (p_caja, p_fecha, p_turno, p_cajera, false, '{}'::jsonb,
          case when c.modo_efectivo = 'deposito_directo' then 0 else round(coalesce(p_fondo_ini, 0), 2) end,
          nullif(trim(p_nota), ''), 'retro', true, u.id, now(), now())
  returning id into v_id;
  perform _con_log(u.id, 'retro_crear', jsonb_build_object('turno', v_id, 'caja', p_caja, 'fecha', p_fecha, 'turno_nombre', p_turno));
  return jsonb_build_object('ok', true, 'turno_id', v_id);
end $$;

create or replace function con_retro_guardar(p_token uuid, p_turno uuid, p_fondo_ini numeric, p_fondo_fin numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into t from con_turnos where id = p_turno for update;
  if not found or t.estado <> 'retro' then raise exception 'Ese borrador ya no existe o ya se cerró.'; end if;
  if coalesce(p_fondo_ini,0) < 0 or coalesce(p_fondo_fin,0) < 0 then raise exception 'El fondo no puede ser negativo.'; end if;
  update con_turnos set fondo_inicial_total = round(coalesce(p_fondo_ini, 0), 2),
         fondo_final_total = round(coalesce(p_fondo_fin, 0), 2) where id = t.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_retro_borrar(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into t from con_turnos where id = p_turno for update;
  if not found or t.estado <> 'retro' then raise exception 'Solo se puede borrar un borrador retroactivo.'; end if;
  delete from con_evidencias where turno_id = t.id;
  delete from con_alertas where turno_id = t.id;
  delete from con_turnos where id = t.id;
  perform _con_log(u.id, 'retro_borrar', jsonb_build_object('turno', t.id, 'caja', t.caja_id, 'fecha', t.fecha, 'turno_nombre', t.turno));
  return jsonb_build_object('ok', true);
end $$;

-- Cierre del corte retroactivo (misma cuenta que un cierre normal; sin avisos por WhatsApp)
create or replace function con_retro_cerrar(p_token uuid, p_turno uuid, p_justificacion text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; v_err text; v_tol numeric; v_ff numeric; eo jsonb; v_modo text;
  pe numeric; pt numeric; ptr numeric; rd numeric; rv numeric; rb numeric;
  de numeric; dt numeric; dtr numeric; dtot numeric; v_estado text;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into t from con_turnos where id = p_turno for update;
  if not found or t.estado <> 'retro' then raise exception 'Ese borrador ya no existe o ya se cerró.'; end if;
  perform _con_procesar(id) from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente';
  if exists (select 1 from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente') then
    raise exception 'Todavía se están leyendo comprobantes. Espera unos segundos.';
  end if;
  if exists (select 1 from con_evidencias where turno_id = t.id and lectura_estado = 'error') then
    raise exception 'Hay comprobantes que no se pudieron leer: vuelve a leerlos, captúralos a mano o bórralos.';
  end if;
  select lectura into eo from con_evidencias
   where turno_id = t.id and tipo = 'eoptics' and lectura_estado = 'ok' order by creado desc limit 1;
  if eo is null then raise exception 'Falta el corte de eOptics de ese turno.'; end if;

  pe  := coalesce((eo->>'efectivo')::numeric, 0);
  pt  := coalesce((eo->>'tarjeta')::numeric, 0);
  ptr := coalesce((eo->>'transferencia')::numeric, 0);
  select coalesce(sum((lectura->>'total')::numeric), 0) into rd from con_evidencias
   where turno_id = t.id and tipo = 'depositador' and lectura_estado = 'ok';
  select coalesce(sum((lectura->>'total')::numeric), 0) into rv from con_evidencias
   where turno_id = t.id and tipo = 'voucher' and lectura_estado = 'ok';
  select coalesce(sum((lectura->>'monto')::numeric), 0) into rb from con_evidencias
   where turno_id = t.id and tipo = 'transferencia' and lectura_estado = 'ok';

  select s.tolerancia, c.modo_efectivo into v_tol, v_modo
    from con_cajas c join con_sucursales s on s.id = c.sucursal_id where c.id = t.caja_id;
  v_ff := coalesce(t.fondo_final_total, 0);
  if v_modo = 'deposito_directo' then v_ff := 0; rd := pe; end if;
  de   := (rd + v_ff) - (coalesce(t.fondo_inicial_total, 0) + pe);
  dt   := rv - pt;
  dtr  := rb - ptr;
  dtot := de + dt + dtr;
  v_estado := case
    when dtot < -v_tol then 'faltante'
    when dtot >  v_tol then 'sobrante'
    when greatest(abs(de), abs(dt), abs(dtr)) > v_tol then 'revisar'
    else 'cuadrado' end;
  if v_estado <> 'cuadrado' and coalesce(trim(p_justificacion),'') = '' then
    return jsonb_build_object('ok', false, 'code', 'JUSTIFICAR', 'estado', v_estado,
      'dif_total', dtot, 'dif_efectivo', de, 'dif_tarjeta', dt, 'dif_transferencia', dtr);
  end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  update con_turnos set
    cerrado_en = now(), cerrado_por = u.id, fondo_final_total = v_ff,
    pos_efectivo = pe, pos_tarjeta = pt, pos_transferencia = ptr,
    real_depositado = rd, real_voucher = rv, real_banco = rb, gastos_total = 0,
    dif_efectivo = de, dif_tarjeta = dt, dif_transferencia = dtr, dif_total = dtot,
    estado = v_estado, justificacion = nullif(trim(p_justificacion),'')
  where id = t.id;
  perform _con_log(u.id, 'retro_cerrar', jsonb_build_object('turno', t.id, 'estado', v_estado, 'dif_total', dtot));
  return jsonb_build_object('ok', true, 'estado', v_estado, 'dif_total', dtot,
    'dif_efectivo', de, 'dif_tarjeta', dt, 'dif_transferencia', dtr);
end $$;

-- Marcas en el detalle, el panel, el Excel; fuera de pendientes de cajeras y de la comparación de fondos
do $$
declare v text; a text;
begin
  v := pg_get_functiondef('con_turno(uuid,uuid)'::regprocedure);
  if position('retro_por_nombre' in v) = 0 then
    a := $a$'revisado_por_nombre', $a$;
    if position(a in v) = 0 then raise exception 'con_turno: patrón'; end if;
    v := replace(v, a, $n$'retro_por_nombre', (select nombre from con_usuarios where id = t.retro_por),
      $n$ || a);
    execute v;
  end if;

  v := pg_get_functiondef('con_admin_resumen(uuid,date,date)'::regprocedure);
  if position('''retroactivo''' in v) = 0 then
    a := $a$'aclarado', t.aclarado_en is not null)$a$;
    if position(a in v) = 0 then raise exception 'con_admin_resumen: patrón'; end if;
    v := replace(v, a, $n$'aclarado', t.aclarado_en is not null, 'retroactivo', t.retroactivo)$n$);
    execute v;
  end if;

  v := pg_get_functiondef('con_admin_exportar(uuid,date,date)'::regprocedure);
  if position('Retroactivo' in v) = 0 then
    a := $a$when 'sin_cierre' then 'Sin cierre' else 'Abierto' end,$a$;
    if position(a in v) = 0 or position($b$'Folio', 'COE-'$b$ in v) = 0 then raise exception 'con_admin_exportar: patrón'; end if;
    v := replace(v, a, $n$when 'sin_cierre' then 'Sin cierre' when 'retro' then 'Borrador retroactivo' else 'Abierto' end,$n$);
    v := replace(v, $b$'Folio', 'COE-'$b$, $n$'Retroactivo', case when t.retroactivo then 'Sí, subido el ' || to_char(t.retro_en at time zone s.zona,'DD/MM/YYYY') else 'No' end,
        'Folio', 'COE-'$n$);
    execute v;
  end if;

  v := pg_get_functiondef('con_mis_pendientes(uuid)'::regprocedure);
  if position('retroactivo' in v) = 0 then
    a := $a$where coalesce(t.responsable_id, t.usuario_id) = u.id and t.fecha >= current_date - 30$a$;
    if position(a in v) = 0 then raise exception 'con_mis_pendientes: patrón'; end if;
    v := replace(v, a, a || ' and not t.retroactivo');
    execute v;
  end if;

  v := pg_get_functiondef('con_abrir_turno(uuid,uuid,text,jsonb,text,text)'::regprocedure);
  if position('retroactivo' in v) = 0 then
    a := $a$where caja_id = p_caja and estado <> 'abierto'$a$;
    if position(a in v) = 0 then raise exception 'con_abrir_turno: patrón'; end if;
    v := replace(v, a, $n$where caja_id = p_caja and estado not in ('abierto','retro') and not retroactivo$n$);
    execute v;
  end if;
end $$;

do $$
declare f text;
begin
  foreach f in array array['con_retro_lista(uuid)','con_retro_crear(uuid,uuid,date,text,uuid,numeric,text)',
                           'con_retro_guardar(uuid,uuid,numeric,numeric)','con_retro_borrar(uuid,uuid)',
                           'con_retro_cerrar(uuid,uuid,text,text)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
