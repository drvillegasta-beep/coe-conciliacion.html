-- COE Conciliación · v3.9 · Comprobantes a destiempo y avisos al iPhone
-- 1) Transferencias, vouchers y tickets del depositador con fecha de otro día (hasta 31 días antes o después
--    del corte) ya no se rechazan: entran al corte marcados "a destiempo", quedan por firmar del Director o la
--    Subdirectora y generan alerta. El turno se puede cerrar normalmente. El corte de eOptics sigue exigiendo su fecha.
-- 2) Duplicados de transferencias: la huella ahora incluye la fecha y la clave de rastreo (antes, bancos que
--    imprimen siempre el mismo número de referencia hacían que transferencias distintas de $5,000 parecieran repetidas).
-- 3) Alertas de turnos no cuadrados, no cerrados y comprobantes a destiempo llegan como aviso push a los equipos
--    activados en COE Finanzas (iPhone del Director y de la Subdirectora).
-- No borra datos.

create or replace function _con_huella(p_tipo text, l jsonb) returns text
language sql immutable as $$
  select case
    when p_tipo = 'eoptics' and coalesce(l->>'consecutivo','') <> '' then 'eo|' || lower(coalesce(l->>'sucursal','')) || '|' || (l->>'consecutivo')
    when p_tipo = 'transferencia' and length(regexp_replace(coalesce(l->>'rastreo',''), '\s', '', 'g')) >= 10
      then 'trr|' || upper(regexp_replace(l->>'rastreo', '\s', '', 'g'))
    when l->>'fecha' is null then null
    when p_tipo = 'depositador' and l->>'hora' is not null then 'dep|' || (l->>'fecha') || '|' || (l->>'hora') || '|' || coalesce(l->>'total','')
    when p_tipo = 'transferencia' and coalesce(l->>'referencia','') <> '' then 'tr|' || (l->>'fecha') || '|' || (l->>'referencia') || '|' || coalesce(l->>'monto','')
    when p_tipo = 'voucher' and coalesce(l->>'lote','') <> '' then 'vo|' || (l->>'fecha') || '|' || (l->>'lote') || '|' || coalesce(l->>'total','')
    when p_tipo = 'corte_dia' then 'cd|' || (l->>'fecha') || '|' || coalesce(l->>'total','')
    else null end
$$;

-- Huellas guardadas de transferencias con el formato nuevo (incluye la fecha)
update con_evidencias set huella = _con_huella('transferencia', lectura)
 where tipo = 'transferencia' and lectura_estado = 'ok' and lectura is not null;

create or replace function _con_procesar(p_evid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  e con_evidencias; r record; j jsonb; l jsonb; v_hay boolean := false; v_tipo text; v_fecha date;
  v_doc date; v_huella text; v_huella2 text; v_dup record; v_suc_cfg text; v_destiempo boolean := false;
  t con_turnos; v_suc uuid; v_id uuid; v_monto numeric; v_quien text;
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
  -- sin_total_dia
  if e.cierre_dia_id is not null and v_tipo = 'corte_dia' and nullif(l->>'total','') is null then
    update con_evidencias set lectura_estado = 'error', lectura = l,
      lectura_error = 'No se encontró el total del corte' || coalesce(' (' || nullif(l->>'descripcion','') || ')', '') ||
                      '. Toma la foto de nuevo o captúralo a mano.' where id = e.id;
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

  if e.turno_id is not null then
    select * into t from con_turnos where id = e.turno_id;
    v_fecha := t.fecha; select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  else select fecha, sucursal_id into v_fecha, v_suc from con_cierres_dia where id = e.cierre_dia_id; end if;
  begin v_doc := (l->>'fecha')::date; exception when others then v_doc := null; end;
  if v_doc is not null and v_fecha is not null and v_doc <> v_fecha then
    -- destiempo: pagos de otro día (hasta 31 días) entran al corte y van a firma del Director / Subdirectora
    if e.turno_id is not null and v_tipo in ('transferencia','voucher','depositador') and abs(v_doc - v_fecha) <= 31 then
      v_destiempo := true;
    elsif v_tipo in ('transferencia','voucher','depositador') then
      update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
        lectura_error = 'Este ' || (nom->>v_tipo) || ' tiene fecha del ' || to_char(v_doc,'DD/MM/YYYY') ||
                        ', más de un mes de diferencia con este corte (' || to_char(v_fecha,'DD/MM') || '). Avisa a la Dirección.'
      where id = e.id;
      return;
    else
      update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
        lectura_error = 'El ' || (nom->>v_tipo) || ' es del ' || to_char(v_doc,'DD/MM') || ' y este corte es del ' || to_char(v_fecha,'DD/MM') || '.'
      where id = e.id;
      return;
    end if;
  end if;

  if v_tipo = 'eoptics' and e.turno_id is not null then
    select cj.eoptics_sucursal into v_suc_cfg from con_turnos tt join con_cajas cj on cj.id = tt.caja_id where tt.id = e.turno_id;
    if coalesce(v_suc_cfg,'') <> '' and coalesce(l->>'sucursal','') <> ''
       and position(lower(v_suc_cfg) in lower(l->>'sucursal')) = 0 then
      update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l,
        lectura_error = 'Este corte es de la sucursal "' || (l->>'sucursal') || '" de eOptics, no de esta caja.' where id = e.id;
      return;
    end if;
  end if;

  v_huella := _con_huella(v_tipo, l);
  -- transferencia con clave de rastreo: también se compara contra el formato sin clave
  if v_tipo = 'transferencia' and v_huella like 'trr|%' then v_huella2 := _con_huella(v_tipo, l - 'rastreo'); end if;
  if v_huella is not null then
    select x.id, x.creado, x.turno_id into v_dup from con_evidencias x
    where x.huella in (v_huella, coalesce(v_huella2, v_huella)) and x.id <> e.id and x.lectura_estado = 'ok'
      -- misma referencia y monto pero distinta hora: son dos pagos diferentes
      and not (coalesce(l->>'hora','') <> '' and coalesce(x.lectura->>'hora','') <> '' and l->>'hora' <> x.lectura->>'hora')
    limit 1;
    if found then
      update con_evidencias set tipo = v_tipo, lectura_estado = 'rechazado', lectura = l, huella = v_huella,
        lectura_error = 'Este ' || (nom->>v_tipo) || ' ya se subió' ||
          coalesce(' en ' || _con_etiqueta(v_dup.turno_id), '') || ' el ' ||
          to_char(v_dup.creado at time zone 'America/Mexico_City','DD/MM "a las" HH24:MI') || '.'
      where id = e.id;
      return;
    end if;
  end if;

  if not v_destiempo then
    update con_evidencias set tipo = v_tipo, lectura_estado = 'ok', lectura = l, lectura_error = null, huella = v_huella
     where id = e.id;
    return;
  end if;

  select nombre into v_quien from con_usuarios where id = e.usuario_id;
  update con_evidencias set tipo = v_tipo, lectura_estado = 'ok', huella = v_huella,
         lectura = l || jsonb_build_object('fecha_distinta', true, 'fecha_doc', v_doc, 'destiempo', true),
         validacion = 'pendiente', validado_por = null, validado_en = null, validacion_nota = null,
         lectura_error = 'A destiempo: comprobante del ' || to_char(v_doc,'DD/MM') || ' registrado en el corte del ' ||
                         to_char(v_fecha,'DD/MM') || coalesce(' por ' || v_quien, '') || '.'
   where id = e.id;
  v_monto := coalesce(nullif(l->>'monto','')::numeric, nullif(l->>'total','')::numeric);
  insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
  values ('fecha_distinta', v_suc, t.caja_id, t.id, v_fecha, t.turno,
          _con_etiqueta_evid(e.id) || ': ' || coalesce(v_quien, 'La cajera') || ' subió un(a) ' || (nom->>v_tipo) ||
          coalesce(' de ' || _con_m(v_monto), '') || ' con fecha del ' || to_char(v_doc,'DD/MM') ||
          ' (a destiempo). Ya cuenta en el corte; falta la firma del Director o la Subdirectora en el panel.')
  returning id into v_id;
  perform _con_enviar(v_id);
  perform _con_log(e.usuario_id, 'destiempo', jsonb_build_object('evidencia', e.id, 'fecha_doc', v_doc, 'fecha_corte', v_fecha, 'tipo', v_tipo));
end $$;

-- Aviso push a COE Finanzas (equipos activados del Director y la Subdirectora)
create or replace function _con_push(p_alerta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a con_alertas; v_tipos text; v_tit text; v_lista jsonb;
begin
  select * into a from con_alertas where id = p_alerta;
  if not found then return; end if;
  select valor into v_tipos from con_config where clave = 'push_tipos';
  v_tipos := coalesce(nullif(trim(v_tipos),''),
    'diferencia,aclaracion,turno_sin_cerrar,cierre_automatico,cierre_pendiente,fecha_distinta,captura_manual,captura_rechazada,cierre_dia_tardio');
  if not (a.tipo = any(string_to_array(replace(v_tipos,' ',''), ','))) then return; end if;
  v_tit := 'Caja COE · ' || case a.tipo
    when 'diferencia' then 'Turno no cuadrado' when 'aclaracion' then 'Turno no cuadrado'
    when 'turno_sin_cerrar' then 'Turno sin cerrar' when 'cierre_automatico' then 'Turno cerrado sin corte'
    when 'cierre_pendiente' then 'Turno cerrado por supervisión' when 'fecha_distinta' then 'Comprobante a destiempo'
    when 'captura_manual' then 'Captura a mano por firmar' when 'captura_rechazada' then 'Comprobante no aprobado'
    when 'cierre_dia_tardio' then 'Cierre del día tardío' else replace(a.tipo,'_',' ') end;
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'title', v_tit, 'body', left(a.mensaje, 400),
           'tag', 'coe-caja-' || a.id, 'url', 'https://drvillegasta-beep.github.io/coe-conciliacion.html/coe-conciliacion.html'))
    into v_lista from fin_usuarios u where u.rol = 'admin' and u.activo;
  if v_lista is null then return; end if;
  perform fin__avisos_disparar(jsonb_build_object('momento', 'caja', 'directo', v_lista));
exception when others then null;
end $$;

do $$
declare v text; a text;
begin
  v := pg_get_functiondef('_con_enviar(uuid)'::regprocedure);
  a := $a$  update con_alertas set enviada = (v_req is not null or v_mail)$a$;
  if position('_con_push' in v) = 0 then
    if position(a in v) = 0 then raise exception '_con_enviar: patrón'; end if;
    v := replace(v, a, $n$  perform _con_push(p_alerta);

$n$ || a);
    execute v;
  end if;
end $$;

insert into con_config(clave, valor) values
  ('push_tipos', 'diferencia,aclaracion,turno_sin_cerrar,cierre_automatico,cierre_pendiente,fecha_distinta,captura_manual,captura_rechazada,cierre_dia_tardio')
on conflict (clave) do nothing;

revoke execute on function _con_push(uuid) from public, anon, authenticated;
revoke execute on function _con_procesar(uuid) from public, anon, authenticated;
