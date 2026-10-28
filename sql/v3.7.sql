-- COE Conciliación · v3.7 · Turnos "Sin cierre" completados tarde y cierre del día atrasado
-- 1) Un turno "Sin cierre" (de los últimos 30 días) puede completarse después: se suben sus comprobantes
--    y la cajera, Contabilidad, Supervisión o el Director lo cierran con PIN. Queda marcado "cerrado tarde".
-- 2) El cierre del día puede hacerse para un día anterior (últimos 30 días) que no se firmó.
--    Queda marcado como tardío y se avisa. Se usan funciones nuevas con fecha (con_dia_f, con_dia_subir_f,
--    con_dia_cerrar_f); las anteriores siguen funcionando para el día de hoy.
-- No borra datos.

alter table con_turnos add column if not exists cierre_tardio_en timestamptz;
alter table con_turnos add column if not exists cierre_tardio_por uuid references con_usuarios(id);
alter table con_cierres_dia add column if not exists tardio boolean not null default false;

-- Quién puede tocar comprobantes de un turno "Sin cierre": su cajera/responsable, Contabilidad, Supervisión y el Director
create or replace function _con_puede_editar(p_u con_usuarios, t con_turnos) returns boolean
language sql stable as $$
  select ((t.usuario_id = p_u.id or coalesce(t.responsable_id, t.usuario_id) = p_u.id or p_u.rol = 'admin')
          and t.estado in ('abierto','sin_cierre'))
      or (t.estado = 'sin_cierre' and p_u.rol in ('contabilidad','supervisor'))
      or (t.estado = 'retro' and p_u.rol in ('admin','contabilidad'))
$$;

do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('con_registrar_evidencia(uuid,uuid,text,text,text,text)'::regprocedure);
  if position('tardio' in v) = 0 then
    a := $a$     and not (t.estado = 'retro' and u.rol = 'contabilidad') then$a$;
    b := $b$(t.estado = 'sin_cierre' and t.aclarado_en is null)$b$;
    if position(a in v) = 0 or position(b in v) = 0 then raise exception 'con_registrar_evidencia: patrón'; end if;
    v := replace(v, a, $n$     and not (t.estado = 'retro' and u.rol = 'contabilidad')
     and not (t.estado = 'sin_cierre' and u.rol in ('contabilidad','supervisor')) then -- tardio$n$);
    v := replace(v, b, $n$t.estado = 'sin_cierre'$n$);
    execute v;
  end if;
end $$;

-- Completar un turno "Sin cierre"
create or replace function con_completar_corte(p_token uuid, p_turno uuid, p_fondo_final numeric, p_justificacion text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; v_suc uuid; v_modo text; v_err text; v_tol numeric; v_g numeric; v_ff numeric; eo jsonb;
  pe numeric; pt numeric; ptr numeric; rd numeric; rv numeric; rb numeric;
  de numeric; dt numeric; dtr numeric; dtot numeric; v_estado text; v_origen text; v_txt text;
  nom jsonb := '{"auto":"un comprobante","eoptics":"el corte de eOptics","depositador":"un ticket de depósito","voucher":"el voucher de terminal","transferencia":"una transferencia"}';
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.estado <> 'sin_cierre' then raise exception 'Solo se completan turnos que quedaron "Sin cierre".'; end if;
  select c.sucursal_id, c.modo_efectivo into v_suc, v_modo from con_cajas c where c.id = t.caja_id;
  if v_modo = 'pagos' then raise exception 'La caja de pagos no se completa así; ciérrala desde el panel.'; end if;
  if not (coalesce(t.responsable_id, t.usuario_id) = u.id or t.usuario_id = u.id
          or (u.rol in ('admin','contabilidad','supervisor') and _con_ve_sucursal(u, v_suc))) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  if t.fecha < _con_hoy(v_suc) - 30 then raise exception 'Solo se completan turnos de los últimos 30 días.'; end if;
  if coalesce(trim(p_justificacion),'') = '' then raise exception 'Explica por qué el corte se completa tarde.'; end if;
  if coalesce(p_fondo_final, 0) < 0 then raise exception 'El efectivo no puede ser negativo.'; end if;

  perform _con_procesar(id) from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente';
  select tipo into v_origen from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente' limit 1;
  if v_origen is not null then raise exception 'Todavía se está leyendo %. Espera unos segundos.', coalesce(nom->>v_origen,'un comprobante'); end if;
  select tipo into v_origen from con_evidencias where turno_id = t.id and lectura_estado = 'error' limit 1;
  if v_origen is not null then
    raise exception 'No se pudo leer %. Vuelve a leerlo, captúralo a mano o bórralo.', coalesce(nom->>v_origen,'un comprobante');
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
  v_g := coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0);
  select tolerancia into v_tol from con_sucursales where id = v_suc;

  if v_modo = 'deposito_directo' then
    v_ff := 0; rd := greatest(pe - v_g, 0); v_origen := null;
  elsif p_fondo_final is not null then
    v_ff := round(p_fondo_final, 2); v_origen := 'contado';
  else
    select fondo_inicial_total into v_ff from con_turnos
     where caja_id = t.caja_id and abierto_en > t.abierto_en and not retroactivo order by abierto_en limit 1;
    v_origen := case when v_ff is null then 'sin dato' else 'fondo con que abrió el turno siguiente' end;
    v_ff := coalesce(v_ff, 0);
  end if;

  de   := (rd + v_ff + v_g) - (coalesce(t.fondo_inicial_total, 0) + pe);
  dt   := rv - pt;
  dtr  := rb - ptr;
  dtot := de + dt + dtr;
  v_estado := case
    when dtot < -v_tol then 'faltante'
    when dtot >  v_tol then 'sobrante'
    when greatest(abs(de), abs(dt), abs(dtr)) > v_tol then 'revisar'
    else 'cuadrado' end;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  update con_turnos set
    fondo_final_total = v_ff, pos_efectivo = pe, pos_tarjeta = pt, pos_transferencia = ptr,
    real_depositado = rd, real_voucher = rv, real_banco = rb, gastos_total = v_g,
    dif_efectivo = de, dif_tarjeta = dt, dif_transferencia = dtr, dif_total = dtot, estado = v_estado,
    cierre_tardio_en = now(), cierre_tardio_por = u.id,
    aclaracion = coalesce(aclaracion, trim(p_justificacion)), aclarado_en = coalesce(aclarado_en, now()),
    justificacion = 'Corte completado tarde por ' || u.nombre || ' el ' || to_char(now() at time zone 'America/Mexico_City','DD/MM HH24:MI')
                    || '. ' || trim(p_justificacion)
                    || case when v_origen is not null and v_modo <> 'deposito_directo' then ' (fondo final: ' || v_origen || ')' else '' end
                    || coalesce(' · Antes: ' || t.justificacion, '')
  where id = t.id;

  v_txt := _con_etiqueta(t.id) || ': ' || u.nombre || ' completó tarde el corte. Resultado: ' ||
           case v_estado when 'cuadrado' then 'cuadró' when 'faltante' then 'FALTANTE de ' || _con_m(abs(dtot))
                         when 'sobrante' then 'sobrante de ' || _con_m(dtot) else 'diferencias que se compensan' end ||
           '. Motivo: ' || trim(p_justificacion);
  perform _con_alerta('cierre_tardio', t.id, v_txt);
  perform _con_log(u.id, 'completar_corte', jsonb_build_object('turno', t.id, 'estado', v_estado, 'dif_total', dtot, 'fondo_final', v_ff));
  return jsonb_build_object('ok', true, 'estado', v_estado, 'dif_total', dtot, 'dif_efectivo', de, 'dif_tarjeta', dt,
    'dif_transferencia', dtr, 'fondo_final', v_ff, 'fondo_origen', v_origen);
end $$;

-- Fecha del cierre del día: hoy o un día anterior de los últimos 30 días
create or replace function _con_fecha_dia(p_suc uuid, p_fecha date) returns date
language plpgsql stable security definer set search_path = public as $$
declare v_hoy date := _con_hoy(p_suc);
begin
  if p_fecha is null or p_fecha = v_hoy then return v_hoy; end if;
  if p_fecha > v_hoy then raise exception 'No se puede cerrar un día que no ha pasado.'; end if;
  if p_fecha < v_hoy - 30 then raise exception 'Solo se cierran días de los últimos 30 días.'; end if;
  return p_fecha;
end $$;

create or replace function _con_alerta_suc(p_tipo text, p_suc uuid, p_fecha date, p_msg text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into con_alertas(tipo, sucursal_id, fecha, mensaje) values (p_tipo, p_suc, p_fecha, p_msg) returning id into v_id;
  return v_id;
end $$;

-- Funciones del cierre del día con fecha (copias de las actuales, con la fecha como parámetro)
do $$
declare v text;
begin
  v := pg_get_functiondef('con_dia(uuid,uuid)'::regprocedure);
  v := replace(v, 'public.con_dia(p_token uuid, p_sucursal uuid)', 'public.con_dia_f(p_token uuid, p_sucursal uuid, p_fecha date)');
  v := replace(v, 'v_hoy := _con_hoy(p_sucursal);', 'v_hoy := _con_fecha_dia(p_sucursal, p_fecha);');
  v := replace(v, $o$'fecha', v_hoy,$o$, $o$'fecha', v_hoy, 'tardio', v_hoy < _con_hoy(p_sucursal),$o$);
  v := replace(v, $o$'turno', t.turno,$o$, $o$'turno', t.turno, 'tarde', t.cierre_tardio_en is not null,$o$);
  v := replace(v, $o$'corte_total', cd.corte_total,$o$, $o$'tardio', cd.tardio, 'corte_total', cd.corte_total,$o$);
  if position('con_dia_f' in v) = 0 or position('_con_fecha_dia' in v) = 0 then raise exception 'con_dia_f: patrón'; end if;
  execute v;

  v := pg_get_functiondef('con_dia_subir(uuid,uuid,text,text,text)'::regprocedure);
  v := replace(v, 'public.con_dia_subir(p_token uuid, p_sucursal uuid, p_archivo text, p_url text, p_hash text)',
                  'public.con_dia_subir_f(p_token uuid, p_sucursal uuid, p_archivo text, p_url text, p_hash text, p_fecha date)');
  v := replace(v, 'v_hoy := _con_hoy(p_sucursal);', 'v_hoy := _con_fecha_dia(p_sucursal, p_fecha);');
  if position('con_dia_subir_f' in v) = 0 or position('_con_fecha_dia' in v) = 0 then raise exception 'con_dia_subir_f: patrón'; end if;
  execute v;

  v := pg_get_functiondef('con_dia_cerrar(uuid,uuid,text,text)'::regprocedure);
  v := replace(v, 'public.con_dia_cerrar(p_token uuid, p_sucursal uuid, p_justificacion text, p_pin text)',
                  'public.con_dia_cerrar_f(p_token uuid, p_sucursal uuid, p_justificacion text, p_pin text, p_fecha date)');
  v := replace(v, 'v_hoy := _con_hoy(p_sucursal);', 'v_hoy := _con_fecha_dia(p_sucursal, p_fecha);');
  v := replace(v, $o$   where c.sucursal_id = p_sucursal and t.estado = 'abierto' and c.modo_efectivo <> 'pagos';
  if v_abiertos is not null then raise exception 'Todavía hay turnos abiertos: %. Deben cerrarse primero.', v_abiertos; end if;$o$,
    $o$   where c.sucursal_id = p_sucursal and t.estado = 'abierto' and c.modo_efectivo <> 'pagos' and t.fecha = v_hoy;
  if v_abiertos is not null then raise exception 'Todavía hay turnos abiertos: %. Deben cerrarse primero.', v_abiertos; end if;
  select string_agg(c.nombre || ' ' || t.turno, ', ') into v_abiertos
    from con_turnos t join con_cajas c on c.id = t.caja_id
   where c.sucursal_id = p_sucursal and t.estado = 'sin_cierre' and c.modo_efectivo <> 'pagos' and t.fecha = v_hoy;
  if v_abiertos is not null then raise exception 'Hay turnos "Sin cierre": %. Complétalos primero con sus comprobantes.', v_abiertos; end if;$o$);
  v := replace(v, $o$  perform _con_log(u.id, 'cierre_dia',$o$,
    $o$  if v_hoy < _con_hoy(p_sucursal) then
    update con_cierres_dia set tardio = true where id = cd.id;
    perform _con_enviar(_con_alerta_suc('cierre_dia_tardio', p_sucursal, v_hoy,
      (select nombre from con_sucursales where id = p_sucursal) || ' · Cierre del día ' || to_char(v_hoy,'DD/MM') ||
      ' firmado TARDE por ' || u.nombre || ' el ' || to_char(now() at time zone 'America/Mexico_City','DD/MM HH24:MI') ||
      '. Depositador ' || _con_m(v_corte) || ' · esperado ' || _con_m(v_suma) || ' · ' ||
      case when v_estado = 'cuadrado' then 'coincide' else 'diferencia ' || _con_m(v_dif) end || '.'));
  end if;
  perform _con_log(u.id, 'cierre_dia',$o$);
  if position('con_dia_cerrar_f' in v) = 0 or position('_con_fecha_dia' in v) = 0 or position('Sin cierre' in v) = 0
     or position('cierre_dia_tardio' in v) = 0 then raise exception 'con_dia_cerrar_f: patrón'; end if;
  execute v;
end $$;

-- Días anteriores sin cierre del día firmado (últimos 30 días)
create or replace function con_dia_pendientes(p_token uuid, p_sucursal uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_hoy date;
begin
  u := _con_sesion(p_token);
  if not _con_puede_dia(u, p_sucursal) then raise exception 'No tienes acceso al cierre del día.'; end if;
  v_hoy := _con_hoy(p_sucursal);
  return coalesce((select jsonb_agg(jsonb_build_object('fecha', q.fecha, 'turnos', q.n, 'sin_cierre', q.sc) order by q.fecha desc)
    from (select t.fecha, count(*) n, count(*) filter (where t.estado = 'sin_cierre') sc
            from con_turnos t join con_cajas c on c.id = t.caja_id
           where c.sucursal_id = p_sucursal and c.modo_efectivo <> 'pagos' and not t.retroactivo
             and t.fecha >= greatest(v_hoy - 30, date '2026-10-01') and t.fecha < v_hoy
             and not exists (select 1 from con_cierres_dia cd where cd.sucursal_id = p_sucursal and cd.fecha = t.fecha and cd.estado <> 'abierto')
           group by t.fecha) q), '[]'::jsonb);
end $$;

do $$
declare f text;
begin
  revoke execute on function _con_fecha_dia(uuid,date) from public, anon, authenticated;
  revoke execute on function _con_alerta_suc(text,uuid,date,text) from public, anon, authenticated;
  foreach f in array array['con_completar_corte(uuid,uuid,numeric,text,text)','con_dia_f(uuid,uuid,date)',
                           'con_dia_subir_f(uuid,uuid,text,text,text,date)','con_dia_cerrar_f(uuid,uuid,text,text,date)',
                           'con_dia_pendientes(uuid,uuid)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
