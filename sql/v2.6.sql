-- COE Conciliación · v2.6 · Lectura de comprobantes con IA, turno de comida, cierre automático
-- No borra datos.

alter table con_turnos drop constraint if exists con_turnos_turno_check;
alter table con_turnos add constraint con_turnos_turno_check check (turno in ('matutino','comida','vespertino'));

alter table con_evidencias add column if not exists lectura jsonb;
alter table con_evidencias add column if not exists lectura_estado text not null default 'no_aplica';
alter table con_evidencias add column if not exists lectura_error text;
alter table con_evidencias add column if not exists lectura_envio bigint;
alter table con_evidencias add column if not exists lectura_pedida timestamptz;
alter table con_evidencias add column if not exists lectura_intentos int not null default 0;

insert into con_config(clave, valor) values ('cierre_auto_min', '60') on conflict (clave) do nothing;

-- Pide al COE Bot que lea un comprobante (respuesta llega a net._http_response)
create or replace function _con_leer(p_evid uuid, p_url text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e con_evidencias; v_base text; v_key text; v_req bigint;
begin
  select * into e from con_evidencias where id = p_evid;
  if e.tipo not in ('eoptics','depositador','voucher','transferencia') then return; end if;
  select valor into v_base from con_config where clave = 'webhook_url';
  select valor into v_key from con_config where clave = 'webhook_key';
  if coalesce(trim(v_base),'') = '' or coalesce(p_url,'') = '' then
    update con_evidencias set lectura_estado = 'error', lectura_error = 'El lector no está configurado.' where id = p_evid;
    return;
  end if;
  v_base := regexp_replace(regexp_replace(trim(v_base), '/+$', ''), '/alerta-caja$', '');
  begin
    select net.http_post(
      url := v_base || '/leer-comprobante',
      body := jsonb_build_object('tipo', e.tipo, 'url', p_url),
      headers := jsonb_build_object('Content-Type','application/json','x-coe-key', coalesce(v_key,'')),
      timeout_milliseconds := 60000) into v_req;
  exception when others then v_req := null;
  end;
  update con_evidencias set lectura_estado = case when v_req is null then 'error' else 'pendiente' end,
         lectura_error = case when v_req is null then 'No se pudo enviar al lector.' end,
         lectura_envio = v_req, lectura_pedida = now(), lectura_intentos = lectura_intentos + 1, lectura = null
   where id = p_evid;
end $$;

create or replace function con_registrar_evidencia(p_token uuid, p_turno uuid, p_tipo text,
                                                   p_archivo text, p_url text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_id uuid;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id and u.rol <> 'admin' then
    raise exception 'Solo quien abrió el turno puede subir comprobantes.';
  end if;
  if t.estado <> 'abierto' and u.rol <> 'admin' then raise exception 'El turno ya está cerrado.'; end if;
  if p_tipo not in ('eoptics','depositador','transferencia','voucher','gasto','otro') then
    raise exception 'Tipo de comprobante inválido.';
  end if;
  insert into con_evidencias(turno_id, tipo, archivo, usuario_id)
  values (t.id, p_tipo, p_archivo, u.id) returning id into v_id;
  perform _con_leer(v_id, p_url);
  perform _con_log(u.id, 'evidencia', jsonb_build_object('turno', t.id, 'tipo', p_tipo, 'archivo', p_archivo));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Revisa si ya llegaron las lecturas y las guarda
create or replace function con_lectura(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios; t con_turnos; v_suc uuid; e record; r record; j jsonb; v_hay boolean;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if t.usuario_id <> u.id and not (u.rol in ('admin','supervisor') and _con_ve_sucursal(u, v_suc)) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  for e in select * from con_evidencias where turno_id = p_turno and lectura_estado = 'pendiente' loop
    v_hay := false;
    begin
      select status_code, content, error_msg, timed_out into r from net._http_response where id = e.lectura_envio;
      v_hay := found;
    exception when others then v_hay := false;
    end;
    if v_hay and r.status_code is not null then
      begin j := r.content::jsonb; exception when others then j := null; end;
      if r.status_code = 200 and coalesce((j->>'ok')::boolean, false) then
        update con_evidencias set lectura_estado = 'ok', lectura = j->'lectura', lectura_error = null where id = e.id;
      else
        update con_evidencias set lectura_estado = 'error',
          lectura_error = coalesce(j->>'error', 'El lector respondió con error (código ' || r.status_code || ').') where id = e.id;
      end if;
    elsif v_hay and (coalesce(r.timed_out,false) or r.error_msg is not null) then
      update con_evidencias set lectura_estado = 'error', lectura_error = 'El lector tardó demasiado. Intenta leer de nuevo.' where id = e.id;
    elsif e.lectura_pedida < now() - interval '2 minutes' then
      update con_evidencias set lectura_estado = 'error', lectura_error = 'El lector no respondió. Intenta leer de nuevo.' where id = e.id;
    end if;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', lectura_estado,
            'lectura', lectura, 'error', lectura_error, 'archivo', archivo, 'creado', creado) order by creado)
          from con_evidencias where turno_id = p_turno), '[]'::jsonb);
end $$;

create or replace function con_releer(p_token uuid, p_evid uuid, p_url text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  select * into t from con_turnos where id = e.turno_id;
  if t.usuario_id <> u.id and u.rol <> 'admin' then raise exception 'No tienes acceso a este comprobante.'; end if;
  if t.estado <> 'abierto' then raise exception 'El turno ya está cerrado.'; end if;
  if e.lectura_intentos >= 5 then raise exception 'Ya se intentó leer 5 veces. Toma una foto nueva o descártalo.'; end if;
  perform _con_leer(p_evid, p_url);
  return jsonb_build_object('ok', true);
end $$;

-- Un comprobante equivocado no se borra: se marca como descartado y queda en la bitácora
create or replace function con_descartar_evidencia(p_token uuid, p_evid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  select * into t from con_turnos where id = e.turno_id;
  if t.usuario_id <> u.id and u.rol <> 'admin' then raise exception 'No tienes acceso a este comprobante.'; end if;
  if t.estado <> 'abierto' then raise exception 'El turno ya está cerrado.'; end if;
  update con_evidencias set lectura_estado = 'descartado' where id = p_evid;
  perform _con_log(u.id, 'descartar_evidencia', jsonb_build_object('turno', t.id, 'evidencia', p_evid, 'tipo', e.tipo));
  return jsonb_build_object('ok', true);
end $$;

drop function if exists con_cerrar_turno(uuid, uuid, jsonb, jsonb, text, text);
create or replace function con_cerrar_turno(p_token uuid, p_turno uuid, p_fondo_final jsonb,
                                            p_justificacion text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; v_err text; v_tol numeric; v_g numeric; v_ff numeric; eo jsonb;
  pe numeric; pt numeric; ptr numeric; rd numeric; rv numeric; rb numeric;
  de numeric; dt numeric; dtr numeric; dtot numeric; v_estado text; v_msg text; v_tipo text;
  nom jsonb := '{"eoptics":"el corte de eOptics","depositador":"el ticket del depositador","voucher":"el voucher de terminal","transferencia":"una transferencia"}';
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id then raise exception 'Solo quien abrió el turno puede cerrarlo.'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado.'; end if;
  perform _con_validar_conteo(p_fondo_final);

  select tipo into v_tipo from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente' limit 1;
  if v_tipo is not null then raise exception 'Todavía se está leyendo %. Espera unos segundos.', nom->>v_tipo; end if;
  select tipo into v_tipo from con_evidencias where turno_id = t.id and lectura_estado = 'error' limit 1;
  if v_tipo is not null then
    raise exception 'No se pudo leer %. Vuelve a leerlo, toma una foto nueva o descártalo.', nom->>v_tipo;
  end if;

  select lectura into eo from con_evidencias
  where turno_id = t.id and tipo = 'eoptics' and lectura_estado = 'ok' order by creado desc limit 1;
  if eo is null then raise exception 'Sube el PDF del corte de eOptics antes de cerrar.'; end if;

  pe  := coalesce((eo->>'efectivo')::numeric, 0);
  pt  := coalesce((eo->>'tarjeta')::numeric, 0);
  ptr := coalesce((eo->>'transferencia')::numeric, 0);
  select coalesce(sum((lectura->>'total')::numeric), 0) into rd from con_evidencias
    where turno_id = t.id and tipo = 'depositador' and lectura_estado = 'ok';
  select coalesce(sum((lectura->>'total')::numeric), 0) into rv from con_evidencias
    where turno_id = t.id and tipo = 'voucher' and lectura_estado = 'ok';
  select coalesce(sum((lectura->>'monto')::numeric), 0) into rb from con_evidencias
    where turno_id = t.id and tipo = 'transferencia' and lectura_estado = 'ok';

  if pt > 0 and rv = 0 then raise exception 'eOptics registra cobros con tarjeta: sube la foto del voucher de cierre de lote.'; end if;
  if ptr > 0 and rb = 0 then raise exception 'eOptics registra transferencias: sube las capturas del banco.'; end if;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  select s.tolerancia into v_tol from con_cajas c join con_sucursales s on s.id = c.sucursal_id where c.id = t.caja_id;
  v_g  := coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0);
  v_ff := _con_total(p_fondo_final);
  de   := (rd + v_ff + v_g) - (t.fondo_inicial_total + pe);
  dt   := rv - pt;
  dtr  := rb - ptr;
  dtot := de + dt + dtr;
  v_estado := case
    when dtot < -v_tol then 'faltante'
    when dtot >  v_tol then 'sobrante'
    when greatest(abs(de), abs(dt), abs(dtr)) > v_tol then 'revisar'
    else 'cuadrado' end;

  if v_estado <> 'cuadrado' and coalesce(trim(p_justificacion),'') = '' then
    perform _con_log(u.id, 'cierre_con_diferencia_visto', jsonb_build_object('turno', t.id, 'dif_total', dtot, 'fondo_final', v_ff));
    return jsonb_build_object('ok', false, 'code', 'JUSTIFICAR', 'estado', v_estado,
      'dif_total', dtot, 'dif_efectivo', de, 'dif_tarjeta', dt, 'dif_transferencia', dtr);
  end if;

  update con_turnos set
    cerrado_en = now(), fondo_final = p_fondo_final, fondo_final_total = v_ff,
    pos_efectivo = pe, pos_tarjeta = pt, pos_transferencia = ptr,
    real_depositado = rd, real_voucher = rv, real_banco = rb, gastos_total = v_g,
    dif_efectivo = de, dif_tarjeta = dt, dif_transferencia = dtr, dif_total = dtot,
    estado = v_estado, justificacion = nullif(trim(p_justificacion),'')
  where id = t.id;

  if v_estado <> 'cuadrado' then
    v_msg := _con_etiqueta(t.id) || ': ' || case v_estado
      when 'faltante' then 'FALTANTE de ' || _con_m(abs(dtot))
      when 'sobrante' then 'sobrante de ' || _con_m(dtot)
      else 'diferencias que se compensan (efectivo ' || _con_m(de) || ', tarjeta '
           || _con_m(dt) || ', transferencia ' || _con_m(dtr) || ')' end
      || '. Justificación: ' || trim(p_justificacion);
    perform _con_alerta('diferencia', t.id, v_msg);
  end if;

  perform _con_log(u.id, 'cerrar_turno', jsonb_build_object('turno', t.id, 'estado', v_estado, 'dif_total', dtot));
  return jsonb_build_object('ok', true, 'estado', v_estado, 'dif_total', dtot,
    'dif_efectivo', de, 'dif_tarjeta', dt, 'dif_transferencia', dtr, 'fondo_final', v_ff,
    'pos_efectivo', pe, 'pos_tarjeta', pt, 'pos_transferencia', ptr,
    'real_depositado', rd, 'real_voucher', rv, 'real_banco', rb, 'gastos', v_g);
end $$;

-- Candado de hora: alerta al pasar el límite y cierre automático después
create or replace function con_revisar_candado() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record; t record; c record;
  v_local timestamp; v_hoy date; v_limite time; v_auto time; v_id uuid; n int := 0;
  v_dias text; v_auto_min int;
begin
  select coalesce(max(valor) filter (where clave = 'dias_laborables'), '1,2,3,4,5,6'),
         coalesce(nullif(max(valor) filter (where clave = 'cierre_auto_min'), '')::int, 60)
    into v_dias, v_auto_min from con_config;

  for r in
    select s.id sucursal_id, s.nombre, s.zona, h.turno, h.hora_cierre, h.gracia_min
    from con_sucursales s join con_horarios h on h.sucursal_id = s.id
    where s.activa
  loop
    v_local := now() at time zone r.zona;
    v_hoy := v_local::date;
    v_limite := r.hora_cierre + make_interval(mins => r.gracia_min);
    v_auto := v_limite + make_interval(mins => v_auto_min);

    -- 1) Alerta: turnos abiertos que pasaron su límite
    for t in
      select tt.id, tt.caja_id, tt.fecha, tt.turno from con_turnos tt join con_cajas cc on cc.id = tt.caja_id
      where cc.sucursal_id = r.sucursal_id and tt.estado = 'abierto' and tt.turno = r.turno
        and (tt.fecha < v_hoy or v_local::time >= v_limite)
    loop
      v_id := null;
      insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
      values ('turno_sin_cerrar', r.sucursal_id, t.caja_id, t.id, t.fecha, t.turno,
              _con_etiqueta(t.id) || ': el turno sigue abierto; debía cerrarse a las '
              || to_char(r.hora_cierre, 'HH24:MI') || '. Se cerrará solo a las ' || to_char(v_auto, 'HH24:MI') || '.')
      on conflict (tipo, caja_id, fecha, turno) where tipo in ('turno_sin_cerrar','turno_sin_registro') do nothing
      returning id into v_id;
      if v_id is not null then perform _con_enviar(v_id); n := n + 1; end if;
    end loop;

    -- 2) Cierre automático (el de comida se cierra junto con el vespertino)
    for t in
      select tt.id from con_turnos tt join con_cajas cc on cc.id = tt.caja_id
      where cc.sucursal_id = r.sucursal_id and tt.estado = 'abierto'
        and (tt.turno = r.turno or (r.turno = 'vespertino' and tt.turno = 'comida'))
        and (tt.fecha < v_hoy or v_local::time >= v_auto)
    loop
      update con_turnos set estado = 'sin_cierre', cerrado_en = now(),
        gastos_total = coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0),
        justificacion = 'Cerrado automáticamente por el sistema a las ' || to_char(v_local, 'HH24:MI')
                        || ': no se hizo el corte.'
      where id = t.id;
      perform _con_alerta('cierre_automatico', t.id,
        _con_etiqueta(t.id) || ': no se hizo el corte y el sistema cerró el turno como "Sin cierre".');
      perform _con_log(null, 'cierre_automatico', jsonb_build_object('turno', t.id));
      n := n + 1;
    end loop;

    -- 3) Cajas que no abrieron turno (solo matutino y vespertino)
    if position(extract(isodow from v_local)::int::text in v_dias) > 0 and v_local::time >= v_limite then
      for c in
        select cc.id from con_cajas cc
        where cc.sucursal_id = r.sucursal_id and cc.activa
          and not exists (select 1 from con_turnos tt where tt.caja_id = cc.id and tt.fecha = v_hoy and tt.turno = r.turno)
          and not exists (select 1 from con_turnos tt where tt.caja_id = cc.id and tt.estado = 'abierto')
      loop
        v_id := null;
        insert into con_alertas(tipo, sucursal_id, caja_id, fecha, turno, mensaje)
        select 'turno_sin_registro', r.sucursal_id, cc.id, v_hoy, r.turno,
               r.nombre || ' · ' || cc.nombre || ' · ' || initcap(r.turno) || ' '
               || to_char(v_hoy, 'DD/MM') || ': no se registró turno y ya pasó la hora límite ('
               || to_char(v_limite, 'HH24:MI') || ').'
        from con_cajas cc where cc.id = c.id
        on conflict (tipo, caja_id, fecha, turno) where tipo in ('turno_sin_cerrar','turno_sin_registro') do nothing
        returning id into v_id;
        if v_id is not null then perform _con_enviar(v_id); n := n + 1; end if;
      end loop;
    end if;
  end loop;
  return n;
end $$;

create or replace function con_admin_guardar_config(p_token uuid, p_d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; r record;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  for r in select key, value #>> '{}' as val from jsonb_each(p_d) loop
    if r.key not in ('wa_alertas','wa_resumen','email_alertas','webhook_url','webhook_key',
                     'emailjs_service','emailjs_template','emailjs_public','emailjs_private',
                     'dias_laborables','cierre_auto_min') then
      continue;
    end if;
    if r.key in ('emailjs_private','webhook_key') and r.val = '••••' then continue; end if;
    if r.key = 'cierre_auto_min' and r.val !~ '^[0-9]{1,3}$' then raise exception 'El cierre automático debe ser en minutos.'; end if;
    insert into con_config(clave, valor) values (r.key, r.val)
    on conflict (clave) do update set valor = excluded.valor;
  end loop;
  perform _con_log(u.id, 'guardar_config', p_d - 'emailjs_private' - 'webhook_key');
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_abrir_turno(p_token uuid, p_caja uuid, p_turno text,
                                           p_fondo jsonb, p_nota text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; v_acc text; v_suc uuid; v_prev numeric; v_total numeric;
  v_err text; v_id uuid; v_quien text;
begin
  u := _con_sesion(p_token);
  v_acc := _con_acceso_caja(u, p_caja);
  if v_acc is null then raise exception 'No tienes acceso a esta caja.'; end if;
  if p_turno not in ('matutino','comida','vespertino') then raise exception 'Turno inválido.'; end if;
  perform _con_validar_conteo(p_fondo);

  select uu.nombre into v_quien
  from con_turnos t join con_usuarios uu on uu.id = t.usuario_id
  where t.caja_id = p_caja and t.estado = 'abierto';
  if found then
    raise exception 'Esta caja ya tiene un turno abierto de %.', v_quien;
  end if;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  select sucursal_id into v_suc from con_cajas where id = p_caja;
  v_total := _con_total(p_fondo);
  select fondo_final_total into v_prev from con_turnos
  where caja_id = p_caja and estado <> 'abierto'
  order by cerrado_en desc nulls last limit 1;

  if v_prev is not null and v_prev <> v_total and coalesce(trim(p_nota),'') = '' then
    return jsonb_build_object('ok', false, 'code', 'FONDO', 'previo', v_prev, 'total', v_total);
  end if;

  insert into con_turnos(caja_id, fecha, turno, usuario_id, es_cobertura, fondo_inicial,
                         fondo_inicial_total, fondo_previo, nota_apertura)
  values (p_caja, _con_hoy(v_suc), p_turno, u.id, v_acc = 'cobertura', p_fondo,
          v_total, v_prev, nullif(trim(p_nota),''))
  returning id into v_id;

  if v_prev is not null and v_prev <> v_total then
    perform _con_alerta('fondo_apertura', v_id,
      _con_etiqueta(v_id) || ': abrió con fondo de ' || _con_m(v_total)
      || ' y el cierre anterior dejó ' || _con_m(v_prev) || '. Explicación: ' || trim(p_nota));
  end if;

  perform _con_log(u.id, 'abrir_turno', jsonb_build_object('turno', v_id, 'fondo', v_total));
  return jsonb_build_object('ok', true, 'turno_id', v_id);
end $$;

create or replace function con_turno(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; r jsonb;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if t.usuario_id <> u.id and not (u.rol in ('admin','supervisor') and _con_ve_sucursal(u, v_suc)) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  select to_jsonb(t) || jsonb_build_object(
      'caja', c.nombre, 'sucursal', s.nombre, 'usuario', uu.nombre, 'tolerancia', s.tolerancia,
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

do $$
declare f text;
begin
  foreach f in array array['_con_leer(uuid,text)','con_revisar_candado()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['con_registrar_evidencia(uuid,uuid,text,text,text)','con_lectura(uuid,uuid)',
      'con_releer(uuid,uuid,text)','con_descartar_evidencia(uuid,uuid)',
      'con_cerrar_turno(uuid,uuid,jsonb,text,text)','con_admin_guardar_config(uuid,jsonb)',
      'con_abrir_turno(uuid,uuid,text,jsonb,text,text)','con_turno(uuid,uuid)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
