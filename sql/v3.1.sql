-- COE Conciliación · v3.1
-- Rol de Contabilidad (consulta, revisión, observaciones, Excel y cierre de emergencia),
-- responsabilidad para quien cierra un turno abandonado y entrega de caja con dos PIN.
-- No borra datos.

alter table con_usuarios drop constraint if exists con_usuarios_rol_check;
alter table con_usuarios add constraint con_usuarios_rol_check
  check (rol in ('admin','supervisor','contabilidad','cajero'));

alter table con_turnos add column if not exists responsable_id uuid references con_usuarios(id);
alter table con_turnos add column if not exists revisado_por uuid references con_usuarios(id);
alter table con_turnos add column if not exists revisado_en timestamptz;
alter table con_turnos add column if not exists entregado_a_turno uuid references con_turnos(id);
alter table con_turnos add column if not exists recibido_de_turno uuid references con_turnos(id);

create table if not exists con_observaciones (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references con_turnos(id) on delete cascade,
  usuario_id uuid not null references con_usuarios(id),
  texto text not null,
  creado timestamptz not null default now()
);
alter table con_observaciones enable row level security;
revoke all on table con_observaciones from anon, authenticated;
create or replace function con_admin_resumen(p_token uuid, p_desde date, p_hasta date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor', 'contabilidad');
  return jsonb_build_object(
    'turnos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja_id', c.id, 'caja', c.nombre,
        'sucursal', s.nombre, 'usuario', uu.nombre, 'estado', t.estado, 'dif_total', t.dif_total,
        'es_cobertura', t.es_cobertura, 'abierto_en', t.abierto_en, 'cerrado_en', t.cerrado_en,
        'fondo_inicial_total', t.fondo_inicial_total, 'fondo_previo', t.fondo_previo,
        'cobrado', coalesce(t.pos_efectivo,0) + coalesce(t.pos_tarjeta,0) + coalesce(t.pos_transferencia,0),
        'depositado', coalesce(t.real_depositado,0), 'aclarado', t.aclarado_en is not null)
        order by t.fecha desc, s.nombre, c.nombre, t.abierto_en)
      from con_turnos t join con_cajas c on c.id = t.caja_id
      join con_sucursales s on s.id = c.sucursal_id join con_usuarios uu on uu.id = t.usuario_id
      where t.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja', c.nombre, 'sucursal', s.nombre,
        'usuario', uu.nombre, 'abierto_en', t.abierto_en) order by t.abierto_en)
      from con_turnos t join con_cajas c on c.id = t.caja_id
      join con_sucursales s on s.id = c.sucursal_id join con_usuarios uu on uu.id = t.usuario_id
      where t.estado = 'abierto' and t.fecha < p_desde and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'cierres_dia', coalesce((select jsonb_agg(jsonb_build_object('fecha', cd.fecha, 'sucursal', s.nombre,
        'estado', cd.estado, 'corte_total', cd.corte_total, 'suma_depositos', cd.suma_depositos,
        'diferencia', cd.diferencia, 'justificacion', cd.justificacion,
        'usuario', (select nombre from con_usuarios where id = cd.usuario_id)) order by cd.fecha desc)
      from con_cierres_dia cd join con_sucursales s on s.id = cd.sucursal_id
      where cd.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'cajas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'nombre', c.nombre, 'sucursal', s.nombre, 'sucursal_id', s.id,
        'hora_local', to_char(now() at time zone s.zona, 'HH24:MI'),
        'horarios', (select jsonb_object_agg(h.turno, jsonb_build_object(
            'cierre', to_char(h.hora_cierre,'HH24:MI'), 'gracia', h.gracia_min))
          from con_horarios h where h.sucursal_id = s.id))
        order by s.nombre, c.nombre)
      from con_cajas c join con_sucursales s on s.id = c.sucursal_id
      where c.activa and s.activa and _con_ve_sucursal(u, s.id)), '[]'::jsonb));
end $$;

create or replace function con_admin_alertas(p_token uuid, p_limite int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor', 'contabilidad');
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'mensaje', a.mensaje,
                              'creada', a.creada, 'enviada', a.enviada, 'turno_id', a.turno_id) x
    from con_alertas a
    where a.sucursal_id is null or _con_ve_sucursal(u, a.sucursal_id)
    order by a.creada desc limit greatest(coalesce(p_limite, 50), 1)) q), '[]'::jsonb);
end $$;

create or replace function con_lectura(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; e record;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if t.usuario_id <> u.id and not (u.rol in ('admin','supervisor','contabilidad') and _con_ve_sucursal(u, v_suc)) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  for e in select id from con_evidencias where turno_id = p_turno and lectura_estado = 'pendiente' loop
    perform _con_procesar(e.id);
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', lectura_estado,
            'lectura', lectura, 'error', lectura_error, 'archivo', archivo, 'creado', creado) order by creado)
          from con_evidencias where turno_id = p_turno), '[]'::jsonb);
end $$;

create or replace function con_turno(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; r jsonb;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if t.usuario_id <> u.id and not (u.rol in ('admin','supervisor','contabilidad') and _con_ve_sucursal(u, v_suc)) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  select to_jsonb(t) || jsonb_build_object(
      'caja', c.nombre, 'sucursal', s.nombre, 'usuario', uu.nombre, 'tolerancia', s.tolerancia,
      'responsable', (select nombre from con_usuarios where id = coalesce(t.responsable_id, t.usuario_id)),
      'cerrado_por_nombre', (select nombre from con_usuarios where id = t.cerrado_por),
      'revisado_por_nombre', (select nombre from con_usuarios where id = t.revisado_por),
      'entregado_a', (select uu2.nombre from con_turnos t2 join con_usuarios uu2 on uu2.id = t2.usuario_id where t2.id = t.entregado_a_turno),
      'recibido_de', (select uu3.nombre from con_turnos t3 join con_usuarios uu3 on uu3.id = t3.usuario_id where t3.id = t.recibido_de_turno),
      'observaciones', coalesce((select jsonb_agg(jsonb_build_object('texto', o.texto, 'usuario', ou.nombre, 'creado', o.creado) order by o.creado)
                from con_observaciones o join con_usuarios ou on ou.id = o.usuario_id where o.turno_id = t.id), '[]'::jsonb),
      'folio', 'COE-' || to_char(t.fecha,'YYMMDD') || '-' || upper(left(t.turno,1)) || '-' || upper(left(replace(t.id::text,'-',''),5)),
      'codigo', case when t.estado <> 'abierto' then _con_codigo(t) end,
      'gastos', coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'monto',g.monto,
                  'concepto',g.concepto,'archivo',g.archivo,'creado',g.creado) order by g.creado)
                from con_gastos g where g.turno_id = t.id), '[]'::jsonb),
      'evidencias', coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'tipo',e.tipo,
                  'archivo',e.archivo,'creado',e.creado,'lectura',e.lectura,'estado',e.lectura_estado,
                  'error',e.lectura_error) order by e.creado)
                from con_evidencias e where e.turno_id = t.id), '[]'::jsonb))
  into r
  from con_cajas c join con_sucursales s on s.id = c.sucursal_id
  join con_usuarios uu on uu.id = t.usuario_id
  where c.id = t.caja_id;
  return r;
end $$;

drop function if exists con_admin_cerrar_pendiente(uuid, uuid, text, text);
create or replace function con_admin_cerrar_pendiente(p_token uuid, p_turno uuid, p_nota text, p_pin text, p_conteo jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; v_err text; v_cajera text;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor', 'contabilidad');
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya está cerrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if not _con_ve_sucursal(u, v_suc) then raise exception 'No tienes acceso a esa caja.'; end if;
  if coalesce(trim(p_nota),'') = '' then raise exception 'Escribe por qué se cierra sin la cajera.'; end if;
  perform _con_validar_conteo(p_conteo);
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  select nombre into v_cajera from con_usuarios where id = t.usuario_id;

  update con_turnos set estado = 'sin_cierre', cerrado_en = now(), cerrado_por = u.id, responsable_id = u.id,
    fondo_final = p_conteo, fondo_final_total = _con_total(p_conteo),
    gastos_total = coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0),
    justificacion = 'Cerrado por ' || u.nombre || ' porque ' || v_cajera || ' no hizo el corte. Contó en caja '
                    || _con_m(_con_total(p_conteo)) || ' y queda como responsable. Nota: ' || trim(p_nota)
  where id = t.id;

  perform _con_alerta('cierre_pendiente', t.id,
    _con_etiqueta(t.id) || ': el turno no se cerró. Lo cerró ' || u.nombre || ', contó ' || _con_m(_con_total(p_conteo)) || ' en caja y queda como responsable. Nota: ' || trim(p_nota));
  perform _con_log(u.id, 'cerrar_pendiente', jsonb_build_object('turno', t.id, 'cajera', t.usuario_id, 'nota', p_nota));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_mis_pendientes(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja', c.nombre, 'estado', t.estado,
      'dif_total', t.dif_total, 'justificacion', t.justificacion,
      'accion', case when t.estado = 'sin_cierre' then 'aclarar' else 'enterado' end) order by t.fecha, t.abierto_en)
    from con_turnos t join con_cajas c on c.id = t.caja_id
    where coalesce(t.responsable_id, t.usuario_id) = u.id and t.fecha >= current_date - 30
      and ((t.estado = 'sin_cierre' and t.aclarado_en is null)
        or (t.estado in ('faltante','sobrante','revisar') and t.enterado_en is null))), '[]'::jsonb);
end $$;

create or replace function con_aclarar(p_token uuid, p_turno uuid, p_texto text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_err text;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found or coalesce(t.responsable_id, t.usuario_id) <> u.id then raise exception 'Turno no encontrado.'; end if;
  if t.estado <> 'sin_cierre' or t.aclarado_en is not null then raise exception 'Este turno ya está aclarado.'; end if;
  if coalesce(trim(p_texto),'') = '' then raise exception 'Escribe qué pasó con este corte.'; end if;
  perform _con_procesar(id) from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente';
  if exists (select 1 from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente') then
    raise exception 'Todavía se está leyendo un comprobante. Espera unos segundos.';
  end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_turnos set aclaracion = trim(p_texto), aclarado_en = now(), enterado_en = now() where id = t.id;
  perform _con_alerta('aclaracion', t.id, _con_etiqueta(t.id) || ': la cajera aclaró el turno sin cierre. ' || trim(p_texto));
  perform _con_log(u.id, 'aclarar', jsonb_build_object('turno', t.id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_enterado(p_token uuid, p_turno uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_err text;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found or coalesce(t.responsable_id, t.usuario_id) <> u.id then raise exception 'Turno no encontrado.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_turnos set enterado_en = now() where id = t.id;
  perform _con_log(u.id, 'enterado', jsonb_build_object('turno', t.id, 'estado', t.estado, 'dif_total', t.dif_total));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_registrar_evidencia(p_token uuid, p_turno uuid, p_tipo text,
                                                   p_archivo text, p_url text, p_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_id uuid; d record;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if coalesce(t.responsable_id, t.usuario_id) <> u.id and t.usuario_id <> u.id and u.rol <> 'admin' then
    raise exception 'Solo quien abrió el turno puede subir comprobantes.';
  end if;
  if not (t.estado = 'abierto' or u.rol = 'admin' or (t.estado = 'sin_cierre' and t.aclarado_en is null)) then
    raise exception 'El turno ya está cerrado.';
  end if;
  if p_tipo not in ('auto','eoptics','depositador','transferencia','voucher','gasto','otro') then
    raise exception 'Tipo de comprobante inválido.';
  end if;
  if coalesce(p_hash,'') <> '' then
    select x.creado, x.turno_id into d from con_evidencias x
    where x.hash = p_hash and x.lectura_estado not in ('descartado','rechazado') limit 1;
    if found then
      raise exception 'Esta misma foto ya se subió% a las %.',
        coalesce(' en ' || _con_etiqueta(d.turno_id), ''), to_char(d.creado at time zone 'America/Mexico_City','HH24:MI');
    end if;
  end if;
  insert into con_evidencias(turno_id, tipo, archivo, usuario_id, hash)
  values (t.id, p_tipo, p_archivo, u.id, nullif(p_hash,'')) returning id into v_id;
  perform _con_leer(v_id, p_url);
  perform _con_log(u.id, 'evidencia', jsonb_build_object('turno', t.id, 'tipo', p_tipo, 'archivo', p_archivo));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function _con_puede_editar(p_u con_usuarios, t con_turnos) returns boolean
language sql stable as $$
  select (t.usuario_id = p_u.id or coalesce(t.responsable_id, t.usuario_id) = p_u.id or p_u.rol = 'admin')
     and (t.estado = 'abierto' or (t.estado = 'sin_cierre' and t.aclarado_en is null))
$$;

create or replace function con_releer(p_token uuid, p_evid uuid, p_url text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  select * into t from con_turnos where id = e.turno_id;
  if not _con_puede_editar(u, t) then raise exception 'Ya no se puede modificar este turno.'; end if;
  if e.lectura_intentos >= 5 then raise exception 'Ya se intentó leer 5 veces. Captúralo a mano o bórralo.'; end if;
  perform _con_leer(p_evid, p_url);
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_admin_guardar_usuario(p_token uuid, p_d jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  u con_usuarios; v_id uuid; v_usr text; v_rol text; v_pass text; v_pin text; v_act boolean;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  v_id  := nullif(p_d->>'id','')::uuid;
  v_usr := lower(trim(coalesce(p_d->>'usuario','')));
  v_rol := coalesce(p_d->>'rol','cajero');
  v_pass := nullif(p_d->>'password','');
  v_pin := nullif(p_d->>'pin','');
  v_act := coalesce((p_d->>'activo')::boolean, true);

  if coalesce(trim(p_d->>'nombre'),'') = '' then raise exception 'Escribe el nombre completo.'; end if;
  if v_usr !~ '^[a-z0-9._-]{3,30}$' then
    raise exception 'El usuario debe tener de 3 a 30 letras o números, sin espacios.';
  end if;
  if v_rol not in ('admin','supervisor','contabilidad','cajero') then raise exception 'Rol inválido.'; end if;
  if v_pass is not null and length(v_pass) < 8 then
    raise exception 'La contraseña temporal debe tener al menos 8 caracteres.';
  end if;
  if v_pin is not null and v_pin !~ '^[0-9]{4,6}$' then
    raise exception 'El PIN temporal debe tener de 4 a 6 números.';
  end if;
  if v_id = u.id and (v_rol <> 'admin' or not v_act) then
    raise exception 'No puedes quitarte tu propio acceso de administrador.';
  end if;

  begin
    if v_id is null then
      if v_pass is null or v_pin is null then
        raise exception 'Para un usuario nuevo escribe contraseña y PIN temporales.';
      end if;
      insert into con_usuarios(nombre, usuario, telefono, rol, activo, pass_hash, pin_hash, debe_cambiar)
      values (trim(p_d->>'nombre'), v_usr, nullif(trim(coalesce(p_d->>'telefono','')),''), v_rol, v_act,
              extensions.crypt(v_pass, extensions.gen_salt('bf')),
              extensions.crypt(v_pin, extensions.gen_salt('bf')), true)
      returning id into v_id;
    else
      update con_usuarios set
        nombre = trim(p_d->>'nombre'), usuario = v_usr,
        telefono = nullif(trim(coalesce(p_d->>'telefono','')),''),
        rol = v_rol, activo = v_act
      where id = v_id;
      if not found then raise exception 'Usuario no encontrado.'; end if;
      if v_pass is not null then
        update con_usuarios set pass_hash = extensions.crypt(v_pass, extensions.gen_salt('bf')),
                                debe_cambiar = true where id = v_id;
        delete from con_sesiones where usuario_id = v_id;
      end if;
      if v_pin is not null then
        update con_usuarios set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf')),
                                intentos_pin = 0, bloqueado = false, debe_cambiar = true where id = v_id;
      end if;
      if not v_act then delete from con_sesiones where usuario_id = v_id; end if;
    end if;
  exception when unique_violation then
    raise exception 'Ya existe el usuario "%".', v_usr;
  end;

  delete from con_usuario_sucursal where usuario_id = v_id;
  insert into con_usuario_sucursal(usuario_id, sucursal_id)
  select v_id, x::uuid from jsonb_array_elements_text(coalesce(p_d->'sucursales','[]'::jsonb)) x
  on conflict do nothing;

  perform _con_log(u.id, 'guardar_usuario', jsonb_build_object('usuario', v_id, 'rol', v_rol,
    'activo', v_act, 'cambio_password', v_pass is not null, 'cambio_pin', v_pin is not null));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
-- ---------- Revisión y observaciones de Contabilidad ----------
create or replace function con_revisar_turno(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if not _con_ve_sucursal(u, v_suc) then raise exception 'No tienes acceso a este turno.'; end if;
  if t.estado = 'abierto' then raise exception 'El turno sigue abierto.'; end if;
  update con_turnos set revisado_por = u.id, revisado_en = now() where id = t.id;
  perform _con_log(u.id, 'revisado', jsonb_build_object('turno', t.id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_observar(p_token uuid, p_turno uuid, p_texto text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor', 'contabilidad');
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if not _con_ve_sucursal(u, v_suc) then raise exception 'No tienes acceso a este turno.'; end if;
  if coalesce(trim(p_texto),'') = '' then raise exception 'Escribe la observación.'; end if;
  insert into con_observaciones(turno_id, usuario_id, texto) values (t.id, u.id, trim(p_texto));
  perform _con_alerta('observacion', t.id, _con_etiqueta(t.id) || ': observación de ' || u.nombre || ': ' || trim(p_texto));
  perform _con_log(u.id, 'observacion', jsonb_build_object('turno', t.id));
  return jsonb_build_object('ok', true);
end $$;

-- Datos para descargar a Excel
create or replace function con_admin_exportar(p_token uuid, p_desde date, p_hasta date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor', 'contabilidad');
  if p_hasta - p_desde > 370 then raise exception 'El periodo máximo es de un año.'; end if;
  return jsonb_build_object(
    'turnos', coalesce((select jsonb_agg(jsonb_build_object(
        'Fecha', to_char(t.fecha,'DD/MM/YYYY'), 'Sucursal', s.nombre, 'Caja', c.nombre, 'Turno', initcap(t.turno),
        'Cajera', uu.nombre, 'Responsable', coalesce(ur.nombre, uu.nombre),
        'Abrió', to_char(t.abierto_en at time zone s.zona,'HH24:MI'), 'Cerró', to_char(t.cerrado_en at time zone s.zona,'HH24:MI'),
        'Estado', case t.estado when 'cuadrado' then 'Cuadró' when 'faltante' then 'Faltante' when 'sobrante' then 'Sobrante'
                   when 'revisar' then 'Revisar' when 'sin_cierre' then 'Sin cierre' else 'Abierto' end,
        'Fondo inicial', t.fondo_inicial_total, 'Efectivo eOptics', t.pos_efectivo, 'Tarjeta eOptics', t.pos_tarjeta,
        'Transferencia eOptics', t.pos_transferencia, 'Depositado', t.real_depositado, 'Voucher', t.real_voucher,
        'Transferencias banco', t.real_banco, 'Gastos caja chica', t.gastos_total, 'Fondo final', t.fondo_final_total,
        'Dif. efectivo', t.dif_efectivo, 'Dif. tarjeta', t.dif_tarjeta, 'Dif. transferencia', t.dif_transferencia,
        'Diferencia total', t.dif_total, 'Justificación', t.justificacion, 'Aclaración', t.aclaracion,
        'Revisado por', ure.nombre, 'Revisado', to_char(t.revisado_en at time zone s.zona,'DD/MM/YYYY HH24:MI'),
        'Folio', 'COE-' || to_char(t.fecha,'YYMMDD') || '-' || upper(left(t.turno,1)) || '-' || upper(left(replace(t.id::text,'-',''),5)))
        order by t.fecha, s.nombre, c.nombre, t.abierto_en)
      from con_turnos t join con_cajas c on c.id = t.caja_id join con_sucursales s on s.id = c.sucursal_id
      join con_usuarios uu on uu.id = t.usuario_id
      left join con_usuarios ur on ur.id = t.responsable_id left join con_usuarios ure on ure.id = t.revisado_por
      where t.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'gastos', coalesce((select jsonb_agg(jsonb_build_object(
        'Fecha', to_char(t.fecha,'DD/MM/YYYY'), 'Caja', c.nombre, 'Turno', initcap(t.turno), 'Cajera', uu.nombre,
        'Concepto', g.concepto, 'Monto', g.monto, 'Con comprobante', case when g.archivo is null then 'No' else 'Sí' end)
        order by t.fecha, g.creado)
      from con_gastos g join con_turnos t on t.id = g.turno_id join con_cajas c on c.id = t.caja_id
      join con_sucursales s on s.id = c.sucursal_id join con_usuarios uu on uu.id = g.usuario_id
      where t.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'cierres_dia', coalesce((select jsonb_agg(jsonb_build_object(
        'Fecha', to_char(cd.fecha,'DD/MM/YYYY'), 'Sucursal', s.nombre,
        'Estado', case cd.estado when 'cuadrado' then 'Coincide' when 'diferencia' then 'Diferencia' else 'Pendiente' end,
        'Corte depositador', cd.corte_total, 'Suma depósitos', cd.suma_depositos, 'Diferencia', cd.diferencia,
        'Firmó', (select nombre from con_usuarios where id = cd.usuario_id), 'Justificación', cd.justificacion) order by cd.fecha)
      from con_cierres_dia cd join con_sucursales s on s.id = cd.sucursal_id
      where cd.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb));
end $$;

-- ---------- Entrega de caja con dos PIN ----------
-- Personas que pueden recibir una caja (tienen acceso a ella)
create or replace function con_receptores(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found or t.usuario_id <> u.id then raise exception 'Turno no encontrado.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre) order by x.nombre)
    from con_usuarios x where x.activo and x.id <> u.id and x.rol in ('cajero','supervisor','admin')
      and _con_acceso_caja(x, t.caja_id) is not null), '[]'::jsonb);
end $$;

-- La cajera ya cerró su turno; quien recibe pone su PIN y se le abre su turno con el fondo contado
create or replace function con_entregar_caja(p_token uuid, p_turno uuid, p_receptor uuid, p_turno_nuevo text, p_pin_receptor text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u con_usuarios; r con_usuarios; t con_turnos; v_err text; v_id uuid; v_suc uuid;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found or t.usuario_id <> u.id then raise exception 'Turno no encontrado.'; end if;
  if t.estado = 'abierto' then raise exception 'Primero cierra tu turno.'; end if;
  if t.entregado_a_turno is not null then raise exception 'Esta caja ya se entregó.'; end if;
  if t.cerrado_en < now() - interval '30 minutes' then raise exception 'La entrega debe hacerse al momento de cerrar.'; end if;
  if p_turno_nuevo not in ('matutino','comida','vespertino') then raise exception 'Turno inválido.'; end if;
  select * into r from con_usuarios where id = p_receptor and activo;
  if not found then raise exception 'Elige quién recibe la caja.'; end if;
  if _con_acceso_caja(r, t.caja_id) is null then raise exception '% no tiene acceso a esta caja.', r.nombre; end if;
  if exists (select 1 from con_turnos where caja_id = t.caja_id and estado = 'abierto') then
    raise exception 'Esta caja ya tiene un turno abierto.';
  end if;
  v_err := _con_pin(r.id, p_pin_receptor);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', 'PIN de ' || r.nombre || ': ' || v_err); end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  insert into con_turnos(caja_id, fecha, turno, usuario_id, es_cobertura, fondo_inicial, fondo_inicial_total,
                         fondo_previo, nota_apertura, recibido_de_turno)
  values (t.caja_id, _con_hoy(v_suc), p_turno_nuevo, r.id, _con_acceso_caja(r, t.caja_id) = 'cobertura',
          t.fondo_final, t.fondo_final_total, t.fondo_final_total,
          'Recibió la caja de ' || u.nombre || ' con ' || _con_m(t.fondo_final_total) || ', contado y firmado por ambas.', t.id)
  returning id into v_id;
  update con_turnos set entregado_a_turno = v_id where id = t.id;
  perform _con_log(u.id, 'entrega_caja', jsonb_build_object('de', t.id, 'a', v_id, 'receptor', r.id, 'fondo', t.fondo_final_total));
  return jsonb_build_object('ok', true, 'turno_id', v_id, 'receptor', r.nombre, 'fondo', t.fondo_final_total);
end $$;

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array['con_admin_resumen(uuid,date,date)','con_admin_alertas(uuid,integer)','con_lectura(uuid,uuid)',
      'con_turno(uuid,uuid)','con_admin_cerrar_pendiente(uuid,uuid,text,text,jsonb)','con_mis_pendientes(uuid)',
      'con_aclarar(uuid,uuid,text,text)','con_enterado(uuid,uuid,text)',
      'con_registrar_evidencia(uuid,uuid,text,text,text,text)','con_admin_guardar_usuario(uuid,jsonb)',
      'con_revisar_turno(uuid,uuid)','con_observar(uuid,uuid,text)','con_admin_exportar(uuid,date,date)',
      'con_receptores(uuid,uuid)','con_entregar_caja(uuid,uuid,uuid,text,text)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
  execute 'revoke execute on function _con_puede_editar(con_usuarios,con_turnos) from public, anon, authenticated';
end $$;
