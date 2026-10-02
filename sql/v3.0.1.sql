-- COE Conciliación · v3.0.1 (aplicado)
-- Lo que la IA no reconoce queda como "No se pudo leer" (se puede releer o capturar a mano), no como rechazado.

create or replace function _con_procesar(p_evid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  e con_evidencias; r record; j jsonb; l jsonb; v_hay boolean := false; v_tipo text; v_fecha date;
  v_doc date; v_huella text; v_dup record;
  nom jsonb := '{"eoptics":"corte de eOptics","depositador":"ticket de depósito","voucher":"voucher de terminal","transferencia":"transferencia","corte_dia":"corte final del depositador"}';
begin
  select * into e from con_evidencias where id = p_evid;
  if e.lectura_estado <> 'pendiente' then return; end if;
  select null::int as status_code, null::text as content, null::text as error_msg, null::boolean as timed_out into r;
  begin
    select status_code, content, error_msg, timed_out into r from net._http_response where id = e.lectura_envio;
    v_hay := found;
  exception when others then v_hay := false;
  end;

  if not v_hay or r.status_code is null then
    if v_hay and (coalesce(r.timed_out,false) or r.error_msg is not null) then
      update con_evidencias set lectura_estado = 'error', lectura_error = 'El lector tardó demasiado. Intenta leer de nuevo.' where id = e.id;
    elsif e.lectura_pedida < now() - interval '2 minutes' then
      update con_evidencias set lectura_estado = 'error', lectura_error = 'El lector no respondió. Intenta leer de nuevo.' where id = e.id;
    end if;
    return;
  end if;

  begin j := r.content::jsonb; exception when others then j := null; end;
  if r.status_code <> 200 or not coalesce((j->>'ok')::boolean, false) then
    update con_evidencias set lectura_estado = 'error',
      lectura_error = coalesce(j->>'error', 'El lector respondió con error (código ' || r.status_code || ').') where id = e.id;
    return;
  end if;

  l := j->'lectura';
  v_tipo := case when e.tipo = 'auto' then l->>'tipo' else e.tipo end;

  if v_tipo is null or v_tipo not in ('eoptics','depositador','voucher','transferencia','corte_dia') then
    update con_evidencias set lectura_estado = 'error', lectura = l,
      lectura_error = 'No se reconoció el documento' || coalesce(' (' || nullif(l->>'descripcion','') || ')', '') ||
                      '. Toma la foto de nuevo, más de cerca, o captúralo a mano.'
    where id = e.id;
    return;
  end if;
  if e.turno_id is not null and v_tipo = 'corte_dia' then
    update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
      lectura_error = 'Este es el corte final del depositador. Se sube en "Cierre del día", no en el turno.' where id = e.id;
    return;
  end if;
  if e.cierre_dia_id is not null and v_tipo <> 'corte_dia' then
    update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
      lectura_error = 'Esto es un ' || (nom->>v_tipo) || ', no el corte final del depositador.' where id = e.id;
    return;
  end if;

  -- Fecha del documento contra la fecha del turno o del cierre del día
  if e.turno_id is not null then select fecha into v_fecha from con_turnos where id = e.turno_id;
  else select fecha into v_fecha from con_cierres_dia where id = e.cierre_dia_id; end if;
  begin v_doc := (l->>'fecha')::date; exception when others then v_doc := null; end;
  if v_doc is not null and v_fecha is not null and v_doc <> v_fecha then
    update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
      lectura_error = 'El ' || (nom->>v_tipo) || ' es del ' || to_char(v_doc,'DD/MM') || ' y este corte es del ' || to_char(v_fecha,'DD/MM') || '.'
    where id = e.id;
    return;
  end if;

  -- Mismo comprobante ya registrado
  v_huella := _con_huella(v_tipo, l);
  if v_huella is not null then
    select x.id, x.creado, x.turno_id into v_dup from con_evidencias x
    where x.huella = v_huella and x.id <> e.id and x.lectura_estado = 'ok' limit 1;
    if found then
      update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l, huella = v_huella,
        lectura_error = 'Este ' || (nom->>v_tipo) || ' ya se subió' ||
          coalesce(' en ' || _con_etiqueta(v_dup.turno_id), '') || ' a las ' ||
          to_char(v_dup.creado at time zone 'America/Mexico_City','HH24:MI') || '.'
      where id = e.id;
      return;
    end if;
  end if;

  update con_evidencias set tipo = v_tipo, lectura_estado = 'ok', lectura = l, lectura_error = null, huella = v_huella
   where id = e.id;
end $$;
revoke execute on function _con_procesar(uuid) from public, anon, authenticated;
