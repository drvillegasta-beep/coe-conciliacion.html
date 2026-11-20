-- COE Conciliación · v3.10 · Revisión de turnos por nivel de atención (Panel → Alertas → Revisión de turnos)
-- Cada turno de los últimos días queda en uno de tres niveles:
--   prioritario: no se cerró (sin cierre, sigue abierto de otro día, cerrado por el sistema o por supervisión),
--                no cuadró (faltante, sobrante, diferencias) o nadie abrió el turno (sin registro).
--   moderado:    cerró tarde o tuvo alguna anomalía (comprobantes a destiempo, captura a mano, comprobante sin firma
--                o no aprobado, fondo que no coincide, aclaración de la cajera, ingreso no reconocido).
--   sin eventualidades: cuadró a tiempo y sin anomalías.
-- No borra datos.

alter table con_alertas add column if not exists revisado_por uuid references con_usuarios(id);
alter table con_alertas add column if not exists revisado_en timestamptz;

create or replace function con_revision_turnos(p_token uuid, p_dias int default 7) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_hoy date; v_desde date; v_res jsonb; v_sinreg jsonb;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  v_hoy := (now() at time zone 'America/Mexico_City')::date;
  v_desde := v_hoy - greatest(1, least(coalesce(p_dias, 7), 62));

  with base as (
    select t.*, c.nombre caja, c.sucursal_id, c.modo_efectivo, s.nombre sucursal, s.zona, uu.nombre usuario,
           h.hora_cierre, h.gracia_min
    from con_turnos t
    join con_cajas c on c.id = t.caja_id
    join con_sucursales s on s.id = c.sucursal_id
    left join con_usuarios uu on uu.id = t.usuario_id
    left join con_horarios h on h.sucursal_id = c.sucursal_id and h.turno = t.turno
    where t.fecha between v_desde and v_hoy and t.estado <> 'retro'
      and _con_ve_sucursal(u, c.sucursal_id)
      and not (t.estado = 'abierto' and t.fecha = v_hoy)
  ), ev as (
    select e.turno_id,
           count(*) filter (where e.lectura->>'fecha_distinta' = 'true') destiempo,
           count(*) filter (where e.lectura->>'manual' = 'true') manual,
           count(*) filter (where e.validacion = 'pendiente') sin_firma,
           count(*) filter (where e.validacion = 'rechazada') no_aprobado
    from con_evidencias e where e.turno_id in (select id from base) and e.lectura_estado = 'ok'
    group by e.turno_id
  ), al as (
    select a.turno_id, array_agg(distinct a.tipo) tipos
    from con_alertas a where a.turno_id in (select id from base) group by a.turno_id
  ), cls as (
    select b.*, coalesce(ev.destiempo,0) destiempo, coalesce(ev.manual,0) manual, coalesce(ev.sin_firma,0) sin_firma,
           coalesce(ev.no_aprobado,0) no_aprobado, coalesce(al.tipos, '{}') tipos,
           (b.cierre_tardio_en is not null or (b.cerrado_en is not null and b.hora_cierre is not null and
              (b.cerrado_en at time zone b.zona) > (b.fecha + b.hora_cierre + make_interval(mins => coalesce(b.gracia_min,0)))
              and b.estado <> 'sin_cierre' and b.modo_efectivo <> 'pagos')) tarde
    from base b left join ev on ev.turno_id = b.id left join al on al.turno_id = b.id
  ), mot as (
    select c.*,
      array_remove(array[
        case when c.estado = 'abierto' then 'Sigue abierto desde el ' || to_char(c.fecha,'DD/MM') end,
        case when c.estado = 'sin_cierre' and c.cierre_tardio_en is null then 'No se hizo el corte (Sin cierre)' end,
        case when c.estado = 'faltante' then 'Faltante de ' || _con_m(abs(c.dif_total)) end,
        case when c.estado = 'sobrante' then 'Sobrante de ' || _con_m(c.dif_total) end,
        case when c.estado = 'revisar' then 'Cerró con diferencias' end,
        case when 'cierre_pendiente' = any(c.tipos) then 'Lo cerró la supervisión' end
      ], null) prio,
      array_remove(array[
        case when c.tarde then 'Cerró tarde' || coalesce(' (' || to_char(coalesce(c.cierre_tardio_en, c.cerrado_en) at time zone c.zona, 'DD/MM HH24:MI') || ')', '') end,
        case when c.destiempo > 0 then c.destiempo || ' comprobante(s) a destiempo' end,
        case when c.manual > 0 then c.manual || ' captura(s) a mano' end,
        case when c.sin_firma > 0 then c.sin_firma || ' comprobante(s) esperan su firma' end,
        case when c.no_aprobado > 0 then c.no_aprobado || ' comprobante(s) no aprobados' end,
        case when 'fondo_apertura' = any(c.tipos) then 'El fondo no coincidió al abrir' end,
        case when c.aclaracion is not null or 'aclaracion' = any(c.tipos) then 'La cajera dejó aclaración' end,
        case when 'ingreso_rechazado' = any(c.tipos) then 'Ingreso no reconocido' end
      ], null) mod
    from cls c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'fecha', m.fecha, 'turno', m.turno, 'caja', m.caja, 'sucursal', m.sucursal, 'usuario', m.usuario,
      'estado', m.estado, 'dif_total', m.dif_total, 'cerrado_en', m.cerrado_en,
      'nivel', case when cardinality(m.prio) > 0 then 'prioritario' when cardinality(m.mod) > 0 then 'moderado' else 'ok' end,
      'motivos', to_jsonb(m.prio || m.mod),
      'revisado_en', m.revisado_en, 'revisado_por', (select nombre from con_usuarios where id = m.revisado_por))
    order by case when cardinality(m.prio) > 0 then 0 when cardinality(m.mod) > 0 then 1 else 2 end,
             (m.revisado_en is not null), m.fecha desc, m.turno), '[]'::jsonb)
    into v_res from mot m;

  -- Turnos que nadie abrió (no existen en con_turnos)
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', null, 'alerta', a.id, 'fecha', a.fecha, 'turno', a.turno, 'caja', c.nombre, 'sucursal', s.nombre, 'usuario', null,
      'estado', 'sin_registro', 'nivel', 'prioritario', 'motivos', jsonb_build_array('Nadie abrió el turno'),
      'revisado_en', a.revisado_en, 'revisado_por', (select nombre from con_usuarios where id = a.revisado_por))
      order by (a.revisado_en is not null), a.fecha desc), '[]'::jsonb)
    into v_sinreg
  from con_alertas a join con_cajas c on c.id = a.caja_id join con_sucursales s on s.id = c.sucursal_id
  where a.tipo = 'turno_sin_registro' and a.fecha between v_desde and v_hoy and _con_ve_sucursal(u, c.sucursal_id)
    and not exists (select 1 from con_turnos t where t.caja_id = a.caja_id and t.fecha = a.fecha
                    and (t.turno = a.turno or c.modo_efectivo = 'pagos'));

  return jsonb_build_object('desde', v_desde, 'hasta', v_hoy, 'turnos', v_sinreg || v_res);
end $$;

revoke execute on function con_revision_turnos(uuid,int) from public, authenticated;
grant execute on function con_revision_turnos(uuid,int) to anon;

-- "Nadie abrió el turno" no tiene turno: se marca revisado sobre la alerta

create or replace function con_revisar_alerta(p_token uuid, p_alerta uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; a con_alertas;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  select * into a from con_alertas where id = p_alerta;
  if not found then raise exception 'Alerta no encontrada.'; end if;
  if not _con_ve_sucursal(u, a.sucursal_id) then raise exception 'No tienes acceso.'; end if;
  update con_alertas set revisado_por = u.id, revisado_en = now() where id = a.id;
  perform _con_log(u.id, 'alerta_revisada', jsonb_build_object('alerta', a.id));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function con_revisar_alerta(uuid,uuid) from public, authenticated;
grant execute on function con_revisar_alerta(uuid,uuid) to anon;

