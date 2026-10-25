-- COE Conciliación · v3.6 · Captura a mano con segunda firma y mejor lectura del corte del depositador
-- 1) Toda captura a mano queda "por validar" con su foto; el Director o la Subdirectora (rol admin)
--    la aprueban o rechazan con PIN. Se avisa al capturar y al rechazar.
-- 2) En el cierre del día, la foto se manda al lector como "corte_dia" (no "auto") para que reconozca
--    el "Resumen del corte" / "Detalle del corte" de la recicladora.
-- No borra datos.

alter table con_evidencias add column if not exists validacion text
  check (validacion in ('pendiente','aprobada','rechazada'));
alter table con_evidencias add column if not exists validado_por uuid references con_usuarios(id);
alter table con_evidencias add column if not exists validado_en timestamptz;
alter table con_evidencias add column if not exists validacion_nota text;
-- Capturas a mano que ya existían: quedan por validar
update con_evidencias set validacion = 'pendiente'
 where lectura->>'manual' = 'true' and lectura_estado = 'ok' and validacion is null;

-- Etiqueta legible de un comprobante (turno o cierre del día)
create or replace function _con_etiqueta_evid(p_evid uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(_con_etiqueta(e.turno_id),
           (select s.nombre || ' · Cierre del día ' || to_char(cd.fecha, 'DD/MM')
              from con_cierres_dia cd join con_sucursales s on s.id = cd.sucursal_id where cd.id = e.cierre_dia_id))
  from con_evidencias e where e.id = p_evid
$$;

create or replace function con_capturar_manual(p_token uuid, p_evid uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos; cd con_cierres_dia; v jsonb; k text; n numeric;
        v_tipo text; v_fecha date; v_suc uuid; v_id uuid; v_txt text;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  if e.lectura_estado <> 'error' then raise exception 'Solo se captura a mano cuando el lector no pudo leer el comprobante.'; end if;
  if e.turno_id is not null then
    select * into t from con_turnos where id = e.turno_id;
    if not coalesce(_con_puede_editar(u, t), false) then raise exception 'Ya no se puede modificar este turno.'; end if;
    v_fecha := t.fecha;
    select sucursal_id into v_suc from con_cajas where id = t.caja_id;
    v_tipo := case when e.tipo = 'auto' then p_datos->>'tipo' else e.tipo end;
    if v_tipo is null or v_tipo not in ('eoptics','depositador','voucher','transferencia') then
      raise exception 'Elige qué tipo de comprobante es.';
    end if;
  else
    select * into cd from con_cierres_dia where id = e.cierre_dia_id;
    if not found or not _con_puede_dia(u, cd.sucursal_id) then raise exception 'No tienes acceso al cierre del día.'; end if;
    if cd.estado <> 'abierto' then raise exception 'El cierre del día ya está firmado.'; end if;
    v_fecha := cd.fecha; v_suc := cd.sucursal_id; v_tipo := 'corte_dia';
  end if;
  v := jsonb_build_object('legible', true, 'manual', true, 'fecha', v_fecha);
  foreach k in array case v_tipo when 'eoptics' then array['efectivo','tarjeta','transferencia']
                                 when 'transferencia' then array['monto'] else array['total'] end loop
    n := coalesce(nullif(p_datos->>k,'')::numeric, 0);
    if n < 0 then raise exception 'Los montos no pueden ser negativos.'; end if;
    v := v || jsonb_build_object(k, round(n, 2));
  end loop;
  update con_evidencias set tipo = v_tipo, lectura_estado = 'ok', lectura = v, validacion = 'pendiente',
         validado_por = null, validado_en = null, validacion_nota = null,
         lectura_error = 'Capturado a mano: ' || coalesce(lectura_error,'') where id = p_evid;
  v_txt := _con_etiqueta_evid(p_evid) || ': ' || u.nombre || ' capturó A MANO ' ||
           case v_tipo when 'eoptics' then 'el corte de eOptics (efectivo ' || _con_m((v->>'efectivo')::numeric) || ')'
                       when 'transferencia' then 'una transferencia de ' || _con_m((v->>'monto')::numeric)
                       when 'corte_dia' then 'el corte del depositador por ' || _con_m((v->>'total')::numeric)
                       else 'un ' || replace(v_tipo,'_',' ') || ' de ' || _con_m((v->>'total')::numeric) end ||
           ' porque el lector no lo reconoció. Falta la firma del Director o la Subdirectora en el panel.';
  insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
  values ('captura_manual', v_suc, t.caja_id, t.id, v_fecha, t.turno, v_txt) returning id into v_id;
  perform _con_enviar(v_id);
  perform _con_log(u.id, 'captura_manual', jsonb_build_object('turno', t.id, 'cierre_dia', e.cierre_dia_id,
                   'evidencia', p_evid, 'tipo', v_tipo, 'datos', v));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_validaciones_pendientes(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'tipo', e.tipo, 'lectura', e.lectura,
      'archivo', e.archivo, 'creado', e.creado, 'capturo', uu.nombre, 'donde', _con_etiqueta_evid(e.id),
      'motivo', e.lectura_error, 'turno_id', e.turno_id, 'propia', e.usuario_id = u.id) order by e.creado)
    from con_evidencias e join con_usuarios uu on uu.id = e.usuario_id
    where e.validacion = 'pendiente' and e.lectura_estado = 'ok'), '[]'::jsonb);
end $$;

create or replace function con_validar_captura(p_token uuid, p_evid uuid, p_aprobar boolean, p_nota text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; v_err text; v_id uuid; v_suc uuid; t con_turnos;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  select * into e from con_evidencias where id = p_evid for update;
  if not found or e.validacion is distinct from 'pendiente' then raise exception 'Esa captura ya se revisó.'; end if;
  if not p_aprobar and coalesce(trim(p_nota),'') = '' then raise exception 'Escribe por qué no la apruebas.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_evidencias set validacion = case when p_aprobar then 'aprobada' else 'rechazada' end,
         validado_por = u.id, validado_en = now(), validacion_nota = nullif(trim(p_nota),'') where id = e.id;
  if e.turno_id is not null and coalesce(trim(p_nota),'') <> '' then
    insert into con_observaciones(turno_id, usuario_id, texto)
    values (e.turno_id, u.id, case when p_aprobar then 'Captura a mano aprobada: ' else 'Captura a mano RECHAZADA: ' end || trim(p_nota));
  end if;
  if not p_aprobar then
    select * into t from con_turnos where id = e.turno_id;
    select coalesce((select sucursal_id from con_cajas where id = t.caja_id),
                    (select sucursal_id from con_cierres_dia where id = e.cierre_dia_id)) into v_suc;
    insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
    values ('captura_rechazada', v_suc, t.caja_id, t.id, coalesce(t.fecha, (e.lectura->>'fecha')::date), t.turno,
            _con_etiqueta_evid(e.id) || ': ' || u.nombre || ' NO aprobó la captura a mano. Motivo: ' || trim(p_nota))
    returning id into v_id;
    perform _con_enviar(v_id);
  end if;
  perform _con_log(u.id, 'validar_captura', jsonb_build_object('evidencia', e.id, 'aprobada', p_aprobar, 'nota', p_nota));
  return jsonb_build_object('ok', true);
end $$;

-- El cierre del día manda la foto al lector como "corte_dia"
do $$
declare v text; a text;
begin
  v := pg_get_functiondef('con_dia_subir(uuid,uuid,text,text,text)'::regprocedure);
  a := $a$values (v_cd, 'auto', p_archivo, u.id, nullif(p_hash,''))$a$;
  if position(a in v) > 0 then
    v := replace(v, a, $n$values (v_cd, 'corte_dia', p_archivo, u.id, nullif(p_hash,''))$n$);
    execute v;
  end if;
end $$;

-- Si el lector no encuentra el total del corte del día, queda "No se pudo leer" (se puede capturar a mano)
do $$
declare v text; a text;
begin
  v := pg_get_functiondef('_con_procesar(uuid)'::regprocedure);
  a := $a$  if e.turno_id is not null and v_tipo = 'corte_dia' then$a$;
  if position('sin_total_dia' in v) = 0 then
    if position(a in v) = 0 then raise exception '_con_procesar: patrón'; end if;
    v := replace(v, a, $n$  -- sin_total_dia
  if e.cierre_dia_id is not null and v_tipo = 'corte_dia' and nullif(l->>'total','') is null then
    update con_evidencias set lectura_estado = 'error', lectura = l,
      lectura_error = 'No se encontró el total del corte' || coalesce(' (' || nullif(l->>'descripcion','') || ')', '') ||
                      '. Toma la foto de nuevo o captúralo a mano.' where id = e.id;
    return;
  end if;
$n$ || a);
    execute v;
  end if;
end $$;

-- La validación se ve en el detalle del turno y en el cierre del día
do $$
declare v text; a text;
begin
  v := pg_get_functiondef('con_turno(uuid,uuid)'::regprocedure);
  a := $a$'error',e.lectura_error) order by e.creado$a$;
  if position('validacion' in v) = 0 then
    if position(a in v) = 0 then raise exception 'con_turno: patrón'; end if;
    v := replace(v, a, $n$'error',e.lectura_error,'validacion',e.validacion,
                  'validado_por',(select nombre from con_usuarios where id = e.validado_por),'validacion_nota',e.validacion_nota) order by e.creado$n$);
    execute v;
  end if;
  v := pg_get_functiondef('con_dia(uuid,uuid)'::regprocedure);
  a := $a$'archivo', x.archivo, 'creado', x.creado)$a$;
  if position('validacion' in v) = 0 then
    if position(a in v) = 0 then raise exception 'con_dia: patrón'; end if;
    v := replace(v, a, $n$'archivo', x.archivo, 'creado', x.creado, 'validacion', x.validacion)$n$);
    execute v;
  end if;
end $$;

do $$
declare f text;
begin
  revoke execute on function _con_etiqueta_evid(uuid) from public, anon, authenticated;
  foreach f in array array['con_capturar_manual(uuid,uuid,jsonb)','con_validaciones_pendientes(uuid)',
                           'con_validar_captura(uuid,uuid,boolean,text,text)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
