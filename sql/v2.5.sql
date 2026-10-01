-- COE Conciliación · v2.5 · Cierre de turnos pendientes por administración
-- No borra datos.

alter table con_turnos drop constraint if exists con_turnos_estado_check;
alter table con_turnos add constraint con_turnos_estado_check
  check (estado in ('abierto','cuadrado','revisar','sobrante','faltante','sin_cierre'));
alter table con_turnos add column if not exists cerrado_por uuid references con_usuarios(id);

-- El administrador o supervisor cierra un turno que la cajera dejó abierto.
-- Queda como "sin cierre" a nombre de la cajera, con la nota de quién lo cerró.
create or replace function con_admin_cerrar_pendiente(p_token uuid, p_turno uuid, p_nota text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; v_err text; v_cajera text;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya está cerrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if not _con_ve_sucursal(u, v_suc) then raise exception 'No tienes acceso a esa caja.'; end if;
  if coalesce(trim(p_nota),'') = '' then raise exception 'Escribe por qué se cierra sin la cajera.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  select nombre into v_cajera from con_usuarios where id = t.usuario_id;

  update con_turnos set estado = 'sin_cierre', cerrado_en = now(), cerrado_por = u.id,
    gastos_total = coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0),
    justificacion = 'Cerrado por ' || u.nombre || ' porque ' || v_cajera || ' no hizo el corte. Nota: ' || trim(p_nota)
  where id = t.id;

  perform _con_alerta('cierre_pendiente', t.id,
    _con_etiqueta(t.id) || ': el turno no se cerró y lo cerró ' || u.nombre || '. Nota: ' || trim(p_nota));
  perform _con_log(u.id, 'cerrar_pendiente', jsonb_build_object('turno', t.id, 'cajera', t.usuario_id, 'nota', p_nota));
  return jsonb_build_object('ok', true);
end $$;

-- Resumen del panel: agrega los turnos que siguen abiertos de días anteriores
create or replace function con_admin_resumen(p_token uuid, p_desde date, p_hasta date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  return jsonb_build_object(
    'turnos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja_id', c.id, 'caja', c.nombre,
        'sucursal', s.nombre, 'usuario', uu.nombre, 'estado', t.estado, 'dif_total', t.dif_total,
        'es_cobertura', t.es_cobertura, 'abierto_en', t.abierto_en, 'cerrado_en', t.cerrado_en,
        'fondo_inicial_total', t.fondo_inicial_total, 'fondo_previo', t.fondo_previo)
        order by t.fecha desc, s.nombre, c.nombre, t.turno)
      from con_turnos t
      join con_cajas c on c.id = t.caja_id
      join con_sucursales s on s.id = c.sucursal_id
      join con_usuarios uu on uu.id = t.usuario_id
      where t.fecha between p_desde and p_hasta and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'fecha', t.fecha, 'turno', t.turno, 'caja', c.nombre, 'sucursal', s.nombre,
        'usuario', uu.nombre, 'abierto_en', t.abierto_en) order by t.abierto_en)
      from con_turnos t
      join con_cajas c on c.id = t.caja_id
      join con_sucursales s on s.id = c.sucursal_id
      join con_usuarios uu on uu.id = t.usuario_id
      where t.estado = 'abierto' and t.fecha < p_desde and _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'cajas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'nombre', c.nombre, 'sucursal', s.nombre,
        'hora_local', to_char(now() at time zone s.zona, 'HH24:MI'),
        'horarios', (select jsonb_object_agg(h.turno, jsonb_build_object(
            'cierre', to_char(h.hora_cierre,'HH24:MI'), 'gracia', h.gracia_min))
          from con_horarios h where h.sucursal_id = s.id))
        order by s.nombre, c.nombre)
      from con_cajas c join con_sucursales s on s.id = c.sucursal_id
      where c.activa and s.activa and _con_ve_sucursal(u, s.id)), '[]'::jsonb));
end $$;

revoke execute on function con_admin_cerrar_pendiente(uuid,uuid,text,text) from public, authenticated;
revoke execute on function con_admin_resumen(uuid,date,date) from public, authenticated;
grant execute on function con_admin_cerrar_pendiente(uuid,uuid,text,text) to anon;
grant execute on function con_admin_resumen(uuid,date,date) to anon;
