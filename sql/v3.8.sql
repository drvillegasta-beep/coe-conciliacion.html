-- COE Conciliación · v3.8 · Comprobantes con fecha anterior (doble PIN, no simultáneo)
-- Un comprobante rechazado solo por tener fecha de otro día (hasta 30 días antes) puede registrarse en el turno
-- de hoy: quien lo sube firma con su PIN y escribe el motivo; queda "pendiente de firma" y el Director o la
-- Subdirectora lo aprueban después con su PIN desde el panel (misma lista que las capturas a mano).
-- No borra datos.

create or replace function con_aceptar_fecha_distinta(p_token uuid, p_evid uuid, p_motivo text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos; cd con_cierres_dia; v_fecha date; v_doc date; v_suc uuid;
        v_huella text; v_dup record; v_err text; v_id uuid; v_monto numeric;
        nom jsonb := '{"eoptics":"corte de eOptics","depositador":"ticket de depósito","voucher":"voucher de terminal","transferencia":"transferencia","corte_dia":"corte del depositador"}';
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid for update;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  if e.lectura_estado <> 'rechazado' or e.lectura is null then raise exception 'Este comprobante no está rechazado por fecha.'; end if;
  begin v_doc := (e.lectura->>'fecha')::date; exception when others then v_doc := null; end;
  if e.turno_id is not null then
    select * into t from con_turnos where id = e.turno_id;
    if not coalesce(_con_puede_editar(u, t), false) then raise exception 'Ya no se puede modificar este turno.'; end if;
    v_fecha := t.fecha; select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  else
    select * into cd from con_cierres_dia where id = e.cierre_dia_id;
    if not found or not _con_puede_dia(u, cd.sucursal_id) then raise exception 'No tienes acceso al cierre del día.'; end if;
    if cd.estado <> 'abierto' then raise exception 'El cierre del día ya está firmado.'; end if;
    v_fecha := cd.fecha; v_suc := cd.sucursal_id;
  end if;
  if v_doc is null or v_doc = v_fecha then raise exception 'Este comprobante no está rechazado por fecha.'; end if;
  if v_doc > v_fecha then raise exception 'El comprobante tiene fecha posterior al corte; no se puede registrar aquí.'; end if;
  if v_doc < v_fecha - 30 then raise exception 'Solo se aceptan comprobantes de hasta 30 días antes.'; end if;
  if e.tipo not in ('eoptics','depositador','voucher','transferencia','corte_dia') then raise exception 'Tipo de comprobante no válido.'; end if;
  if e.turno_id is not null and e.tipo = 'corte_dia' then raise exception 'El corte del depositador se sube en "Cierre del día".'; end if;
  if e.cierre_dia_id is not null and e.tipo <> 'corte_dia' then raise exception 'Aquí solo va el corte del depositador.'; end if;
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Explica por qué se registra con fecha de otro día.'; end if;

  -- Que no esté ya registrado en otro turno
  v_huella := _con_huella(e.tipo, e.lectura);
  if v_huella is not null then
    select x.id, x.creado, x.turno_id into v_dup from con_evidencias x
     where x.huella = v_huella and x.id <> e.id and x.lectura_estado = 'ok' limit 1;
    if found then
      raise exception 'Este % ya está registrado% (subido el %).', coalesce(nom->>e.tipo, 'comprobante'),
        coalesce(' en ' || _con_etiqueta(v_dup.turno_id), ''), to_char(v_dup.creado at time zone 'America/Mexico_City','DD/MM HH24:MI');
    end if;
  end if;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  update con_evidencias set lectura_estado = 'ok', huella = v_huella, validacion = 'pendiente',
         validado_por = null, validado_en = null, validacion_nota = null,
         lectura = e.lectura || jsonb_build_object('fecha_distinta', true, 'fecha_doc', v_doc),
         lectura_error = 'Fecha ' || to_char(v_doc,'DD/MM') || ' registrada el ' || to_char(v_fecha,'DD/MM') || ' por ' || u.nombre || '. Motivo: ' || trim(p_motivo)
   where id = e.id;

  v_monto := coalesce((e.lectura->>'total')::numeric, (e.lectura->>'monto')::numeric, (e.lectura->>'efectivo')::numeric);
  insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
  values ('fecha_distinta', v_suc, t.caja_id, t.id, v_fecha, t.turno,
          _con_etiqueta_evid(e.id) || ': ' || u.nombre || ' registró un(a) ' || coalesce(nom->>e.tipo,'comprobante') ||
          coalesce(' de ' || _con_m(v_monto), '') || ' con fecha del ' || to_char(v_doc,'DD/MM') || '. Motivo: ' || trim(p_motivo) ||
          '. Falta la firma del Director o la Subdirectora en el panel.')
  returning id into v_id;
  perform _con_enviar(v_id);
  perform _con_log(u.id, 'fecha_distinta', jsonb_build_object('evidencia', e.id, 'fecha_doc', v_doc, 'fecha_corte', v_fecha, 'motivo', p_motivo));
  return jsonb_build_object('ok', true);
end $$;

-- La lista de lectura del turno incluye la validación
do $$
declare v text; a text;
begin
  v := pg_get_functiondef('con_lectura(uuid,uuid)'::regprocedure);
  a := $a$'archivo', archivo, 'creado', creado) order by creado)$a$;
  if position('validacion' in v) = 0 then
    if position(a in v) = 0 then raise exception 'con_lectura: patrón'; end if;
    v := replace(v, a, $n$'archivo', archivo, 'creado', creado, 'validacion', validacion) order by creado)$n$);
    execute v;
  end if;
end $$;

revoke execute on function con_aceptar_fecha_distinta(uuid,uuid,text,text) from public, authenticated;
grant execute on function con_aceptar_fecha_distinta(uuid,uuid,text,text) to anon;
