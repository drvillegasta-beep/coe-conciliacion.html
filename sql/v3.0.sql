-- COE Conciliación · v3.0
-- Reconocimiento automático de comprobantes, bloqueo de duplicados y fechas,
-- pendientes de la cajera, cierre del día del depositador y folio/código de verificación.
-- No borra datos.

-- ---------- Estructura ----------
alter table con_evidencias alter column turno_id drop not null;
alter table con_evidencias add column if not exists cierre_dia_id uuid;
alter table con_evidencias add column if not exists hash text;
alter table con_evidencias add column if not exists huella text;
alter table con_evidencias drop constraint if exists con_evidencias_tipo_check;
alter table con_evidencias add constraint con_evidencias_tipo_check
  check (tipo in ('auto','eoptics','depositador','transferencia','voucher','corte_dia','gasto','otro'));
create index if not exists con_evidencias_hash on con_evidencias(hash);
create index if not exists con_evidencias_huella on con_evidencias(huella);

alter table con_turnos add column if not exists aclaracion text;
alter table con_turnos add column if not exists aclarado_en timestamptz;
alter table con_turnos add column if not exists enterado_en timestamptz;

alter table con_sucursales add column if not exists caja_cierre_dia uuid references con_cajas(id);
update con_sucursales s set caja_cierre_dia = c.id
  from con_cajas c
 where c.sucursal_id = s.id and s.caja_cierre_dia is null and c.nombre ilike 'cl%nica%';

create table if not exists con_cierres_dia (
  id uuid primary key default gen_random_uuid(),
  sucursal_id uuid not null references con_sucursales(id),
  fecha date not null,
  estado text not null default 'abierto' check (estado in ('abierto','cuadrado','diferencia')),
  usuario_id uuid references con_usuarios(id),
  corte_total numeric(12,2),
  suma_depositos numeric(12,2),
  diferencia numeric(12,2),
  justificacion text,
  cerrado_en timestamptz,
  creado timestamptz not null default now(),
  unique (sucursal_id, fecha)
);
alter table con_cierres_dia enable row level security;
revoke all on table con_cierres_dia from anon, authenticated;

insert into con_config(clave, valor)
values ('firma_secreta', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (clave) do nothing;

-- ---------- Lectura ----------
create or replace function _con_leer(p_evid uuid, p_url text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e con_evidencias; v_base text; v_key text; v_req bigint;
begin
  select * into e from con_evidencias where id = p_evid;
  if e.tipo not in ('auto','eoptics','depositador','voucher','transferencia','corte_dia') then return; end if;
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

-- Huella de contenido para detectar el mismo comprobante subido dos veces
create or replace function _con_huella(p_tipo text, l jsonb) returns text
language sql immutable as $$
  select case
    when l->>'fecha' is null then null
    when p_tipo = 'eoptics' then 'eo|' || (l->>'fecha') || '|' || coalesce(l->>'efectivo','') || '|' || coalesce(l->>'tarjeta','') || '|' || coalesce(l->>'transferencia','')
    when p_tipo = 'depositador' and l->>'hora' is not null then 'dep|' || (l->>'fecha') || '|' || (l->>'hora') || '|' || coalesce(l->>'total','')
    when p_tipo = 'transferencia' and coalesce(l->>'referencia','') <> '' then 'tr|' || (l->>'referencia') || '|' || coalesce(l->>'monto','')
    when p_tipo = 'voucher' and coalesce(l->>'lote','') <> '' then 'vo|' || (l->>'fecha') || '|' || (l->>'lote') || '|' || coalesce(l->>'total','')
    when p_tipo = 'corte_dia' then 'cd|' || (l->>'fecha') || '|' || coalesce(l->>'total','')
    else null end
$$;

-- Procesa la respuesta del lector para un comprobante: clasifica, valida fecha y duplicados
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
    update con_evidencias set lectura_estado = 'rechazado', lectura = l,
      lectura_error = 'No parece un comprobante de caja. Sube el corte de eOptics, un ticket de depósito, un voucher o una transferencia.'
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

create or replace function con_lectura(p_token uuid, p_turno uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_suc uuid; e record;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  select sucursal_id into v_suc from con_cajas where id = t.caja_id;
  if t.usuario_id <> u.id and not (u.rol in ('admin','supervisor') and _con_ve_sucursal(u, v_suc)) then
    raise exception 'No tienes acceso a este turno.';
  end if;
  for e in select id from con_evidencias where turno_id = p_turno and lectura_estado = 'pendiente' loop
    perform _con_procesar(e.id);
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', lectura_estado,
            'lectura', lectura, 'error', lectura_error, 'archivo', archivo, 'creado', creado) order by creado)
          from con_evidencias where turno_id = p_turno), '[]'::jsonb);
end $$;

-- Subir comprobante (tipo 'auto' = lo reconoce la IA). Rechaza la misma foto exacta.
create or replace function con_registrar_evidencia(p_token uuid, p_turno uuid, p_tipo text,
                                                   p_archivo text, p_url text, p_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_id uuid; d record;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id and u.rol <> 'admin' then
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

create or replace function con_cerrar_turno(p_token uuid, p_turno uuid, p_fondo_final jsonb,
                                            p_justificacion text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; v_err text; v_tol numeric; v_g numeric; v_ff numeric; eo jsonb;
  pe numeric; pt numeric; ptr numeric; rd numeric; rv numeric; rb numeric;
  de numeric; dt numeric; dtr numeric; dtot numeric; v_estado text; v_msg text; v_tipo text;
  nom jsonb := '{"auto":"un comprobante","eoptics":"el corte de eOptics","depositador":"un ticket de depósito","voucher":"el voucher de terminal","transferencia":"una transferencia"}';
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id then raise exception 'Solo quien abrió el turno puede cerrarlo.'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado.'; end if;
  perform _con_validar_conteo(p_fondo_final);

  perform _con_procesar(id) from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente';
  select tipo into v_tipo from con_evidencias where turno_id = t.id and lectura_estado = 'pendiente' limit 1;
  if v_tipo is not null then raise exception 'Todavía se está leyendo %. Espera unos segundos.', coalesce(nom->>v_tipo,'un comprobante'); end if;
  select tipo into v_tipo from con_evidencias where turno_id = t.id and lectura_estado = 'error' limit 1;
  if v_tipo is not null then
    raise exception 'No se pudo leer %. Vuelve a leerlo, captúralo a mano o bórralo.', coalesce(nom->>v_tipo,'un comprobante');
  end if;

  select lectura into eo from con_evidencias
  where turno_id = t.id and tipo = 'eoptics' and lectura_estado = 'ok' order by creado desc limit 1;
  if eo is null then raise exception 'Falta el corte de eOptics de tu turno.'; end if;

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

-- ---------- Pendientes de la cajera ----------
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
    where t.usuario_id = u.id and t.fecha >= current_date - 30
      and ((t.estado = 'sin_cierre' and t.aclarado_en is null)
        or (t.estado in ('faltante','sobrante','revisar') and t.enterado_en is null))), '[]'::jsonb);
end $$;

create or replace function con_aclarar(p_token uuid, p_turno uuid, p_texto text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_err text;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found or t.usuario_id <> u.id then raise exception 'Turno no encontrado.'; end if;
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
  if not found or t.usuario_id <> u.id then raise exception 'Turno no encontrado.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_turnos set enterado_en = now() where id = t.id;
  perform _con_log(u.id, 'enterado', jsonb_build_object('turno', t.id, 'estado', t.estado, 'dif_total', t.dif_total));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Cierre del día (corte final del depositador) ----------
create or replace function _con_puede_dia(p_u con_usuarios, p_suc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_u.rol in ('admin','supervisor') and _con_ve_sucursal(p_u, p_suc)
      or exists (select 1 from con_sucursales s where s.id = p_suc and s.caja_cierre_dia is not null
                 and _con_acceso_caja(p_u, s.caja_cierre_dia) is not null)
$$;

create or replace function con_dia(p_token uuid, p_sucursal uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_hoy date; cd con_cierres_dia; e record;
begin
  u := _con_sesion(p_token);
  if not _con_puede_dia(u, p_sucursal) then raise exception 'No tienes acceso al cierre del día.'; end if;
  v_hoy := _con_hoy(p_sucursal);
  select * into cd from con_cierres_dia where sucursal_id = p_sucursal and fecha = v_hoy;
  if found then
    for e in select id from con_evidencias where cierre_dia_id = cd.id and lectura_estado = 'pendiente' loop
      perform _con_procesar(e.id);
    end loop;
  end if;
  return jsonb_build_object(
    'fecha', v_hoy,
    'sucursal', (select nombre from con_sucursales where id = p_sucursal),
    'tolerancia', (select tolerancia from con_sucursales where id = p_sucursal),
    'turnos', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'caja', c.nombre, 'turno', t.turno,
        'usuario', uu.nombre, 'estado', t.estado,
        'depositos', coalesce((select sum((x.lectura->>'total')::numeric) from con_evidencias x
                               where x.turno_id = t.id and x.tipo = 'depositador' and x.lectura_estado = 'ok'), 0))
        order by t.abierto_en)
      from con_turnos t join con_cajas c on c.id = t.caja_id join con_usuarios uu on uu.id = t.usuario_id
      where c.sucursal_id = p_sucursal and t.fecha = v_hoy), '[]'::jsonb),
    'cierre', case when cd.id is null then null else jsonb_build_object('id', cd.id, 'estado', cd.estado,
        'corte_total', cd.corte_total, 'suma_depositos', cd.suma_depositos, 'diferencia', cd.diferencia) end,
    'evidencias', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'estado', x.lectura_estado,
        'lectura', x.lectura, 'error', x.lectura_error, 'archivo', x.archivo, 'creado', x.creado) order by x.creado)
      from con_evidencias x where cd.id is not null and x.cierre_dia_id = cd.id), '[]'::jsonb));
end $$;

create or replace function con_dia_subir(p_token uuid, p_sucursal uuid, p_archivo text, p_url text, p_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_hoy date; v_cd uuid; v_estado text; v_id uuid;
begin
  u := _con_sesion(p_token);
  if not _con_puede_dia(u, p_sucursal) then raise exception 'No tienes acceso al cierre del día.'; end if;
  v_hoy := _con_hoy(p_sucursal);
  insert into con_cierres_dia(sucursal_id, fecha) values (p_sucursal, v_hoy)
  on conflict (sucursal_id, fecha) do update set fecha = excluded.fecha
  returning id, estado into v_cd, v_estado;
  if v_estado <> 'abierto' then raise exception 'El cierre del día ya está firmado.'; end if;
  if coalesce(p_hash,'') <> '' and exists (select 1 from con_evidencias where hash = p_hash
      and lectura_estado not in ('descartado','rechazado')) then
    raise exception 'Esta misma foto ya se subió.';
  end if;
  insert into con_evidencias(cierre_dia_id, tipo, archivo, usuario_id, hash)
  values (v_cd, 'auto', p_archivo, u.id, nullif(p_hash,'')) returning id into v_id;
  perform _con_leer(v_id, p_url);
  perform _con_log(u.id, 'evidencia_dia', jsonb_build_object('cierre', v_cd, 'archivo', p_archivo));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function con_dia_cerrar(p_token uuid, p_sucursal uuid, p_justificacion text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_hoy date; cd con_cierres_dia; v_corte numeric; v_suma numeric; v_dif numeric;
        v_tol numeric; v_abiertos text; v_err text; v_estado text;
begin
  u := _con_sesion(p_token);
  if not _con_puede_dia(u, p_sucursal) then raise exception 'No tienes acceso al cierre del día.'; end if;
  v_hoy := _con_hoy(p_sucursal);
  select * into cd from con_cierres_dia where sucursal_id = p_sucursal and fecha = v_hoy for update;
  if not found then raise exception 'Primero sube el corte final del depositador.'; end if;
  if cd.estado <> 'abierto' then raise exception 'El cierre del día ya está firmado.'; end if;
  perform _con_procesar(id) from con_evidencias where cierre_dia_id = cd.id and lectura_estado = 'pendiente';
  if exists (select 1 from con_evidencias where cierre_dia_id = cd.id and lectura_estado = 'pendiente') then
    raise exception 'Todavía se está leyendo el corte del depositador. Espera unos segundos.';
  end if;
  select (lectura->>'total')::numeric into v_corte from con_evidencias
   where cierre_dia_id = cd.id and lectura_estado = 'ok' order by creado desc limit 1;
  if v_corte is null then raise exception 'Primero sube el corte final del depositador.'; end if;
  select string_agg(c.nombre || ' ' || t.turno, ', ') into v_abiertos
    from con_turnos t join con_cajas c on c.id = t.caja_id
   where c.sucursal_id = p_sucursal and t.estado = 'abierto';
  if v_abiertos is not null then raise exception 'Todavía hay turnos abiertos: %. Deben cerrarse primero.', v_abiertos; end if;

  select coalesce(sum((x.lectura->>'total')::numeric), 0) into v_suma
    from con_evidencias x join con_turnos t on t.id = x.turno_id join con_cajas c on c.id = t.caja_id
   where c.sucursal_id = p_sucursal and t.fecha = v_hoy and x.tipo = 'depositador' and x.lectura_estado = 'ok';
  select tolerancia into v_tol from con_sucursales where id = p_sucursal;
  v_dif := v_corte - v_suma;
  v_estado := case when abs(v_dif) > v_tol then 'diferencia' else 'cuadrado' end;
  if v_estado = 'diferencia' and coalesce(trim(p_justificacion),'') = '' then
    return jsonb_build_object('ok', false, 'code', 'JUSTIFICAR', 'corte', v_corte, 'suma', v_suma, 'diferencia', v_dif);
  end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_cierres_dia set estado = v_estado, usuario_id = u.id, corte_total = v_corte, suma_depositos = v_suma,
         diferencia = v_dif, justificacion = nullif(trim(p_justificacion),''), cerrado_en = now()
   where id = cd.id;
  if v_estado = 'diferencia' then
    insert into con_alertas(tipo, sucursal_id, fecha, mensaje)
    values ('cierre_dia', p_sucursal, v_hoy,
      (select nombre from con_sucursales where id = p_sucursal) || ' · Cierre del día ' || to_char(v_hoy,'DD/MM') ||
      ': el depositador marca ' || _con_m(v_corte) || ' y los depósitos de los turnos suman ' || _con_m(v_suma) ||
      ' (diferencia ' || _con_m(v_dif) || '). Explicación: ' || trim(p_justificacion));
    perform _con_enviar(id) from con_alertas where tipo = 'cierre_dia' and sucursal_id = p_sucursal and fecha = v_hoy
      order by creada desc limit 1;
  end if;
  perform _con_log(u.id, 'cierre_dia', jsonb_build_object('cierre', cd.id, 'corte', v_corte, 'suma', v_suma));
  return jsonb_build_object('ok', true, 'estado', v_estado, 'corte', v_corte, 'suma', v_suma, 'diferencia', v_dif);
end $$;

create or replace function con_dia_descartar(p_token uuid, p_evid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; cd con_cierres_dia;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  select * into cd from con_cierres_dia where id = e.cierre_dia_id;
  if cd.id is null or not _con_puede_dia(u, cd.sucursal_id) then raise exception 'No tienes acceso.'; end if;
  if cd.estado <> 'abierto' then raise exception 'El cierre del día ya está firmado.'; end if;
  update con_evidencias set lectura_estado = 'descartado' where id = p_evid;
  perform _con_log(u.id, 'descartar_evidencia_dia', jsonb_build_object('evidencia', p_evid));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Estado de inicio: agrega el cierre del día ----------
create or replace function con_estado(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_cajas jsonb; v_dia jsonb;
begin
  u := _con_sesion(p_token);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'nombre', c.nombre, 'sucursal', s.nombre, 'sucursal_id', s.id,
      'acceso', _con_acceso_caja(u, c.id),
      'hora_local', to_char(now() at time zone s.zona, 'HH24:MI'),
      'horarios', (select jsonb_object_agg(h.turno, jsonb_build_object(
                     'cierre', to_char(h.hora_cierre, 'HH24:MI'), 'gracia', h.gracia_min))
                   from con_horarios h where h.sucursal_id = s.id),
      'abierto', (select jsonb_build_object('id', t.id, 'turno', t.turno, 'usuario', uu.nombre,
                     'mio', t.usuario_id = u.id, 'abierto_en', t.abierto_en, 'fecha', t.fecha)
                  from con_turnos t join con_usuarios uu on uu.id = t.usuario_id
                  where t.caja_id = c.id and t.estado = 'abierto' limit 1)
    ) order by s.nombre, c.nombre), '[]'::jsonb)
  into v_cajas
  from con_cajas c join con_sucursales s on s.id = c.sucursal_id
  where c.activa and s.activa and _con_acceso_caja(u, c.id) is not null;

  select coalesce(jsonb_agg(jsonb_build_object('sucursal_id', s.id, 'sucursal', s.nombre,
      'estado', (select cd.estado from con_cierres_dia cd where cd.sucursal_id = s.id and cd.fecha = _con_hoy(s.id)))), '[]'::jsonb)
  into v_dia
  from con_sucursales s where s.activa and _con_puede_dia(u, s.id);

  return jsonb_build_object(
    'usuario', jsonb_build_object('id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'usuario', u.usuario),
    'cajas', v_cajas, 'cierre_dia', v_dia);
end $$;

-- ---------- Detalle del turno con folio y código de verificación ----------
create or replace function _con_codigo(t con_turnos) returns text
language sql stable security definer set search_path = public, extensions as $$
  select upper(left(encode(extensions.hmac(
    t.id::text || '|' || coalesce(t.dif_total,0)::text || '|' || coalesce(t.fondo_final_total,0)::text || '|' ||
    coalesce(t.real_depositado,0)::text || '|' || coalesce(t.pos_efectivo,0)::text || '|' || t.estado,
    (select valor from con_config where clave = 'firma_secreta'), 'sha256'), 'hex'), 8))
$$;

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

-- ---------- Resumen del panel con indicadores y cierres del día ----------
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

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array['_con_leer(uuid,text)','_con_procesar(uuid)','_con_huella(text,jsonb)',
                           '_con_puede_dia(con_usuarios,uuid)','_con_codigo(con_turnos)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['con_lectura(uuid,uuid)','con_registrar_evidencia(uuid,uuid,text,text,text,text)',
      'con_cerrar_turno(uuid,uuid,jsonb,text,text)','con_mis_pendientes(uuid)','con_aclarar(uuid,uuid,text,text)',
      'con_enterado(uuid,uuid,text)','con_dia(uuid,uuid)','con_dia_subir(uuid,uuid,text,text,text)',
      'con_dia_cerrar(uuid,uuid,text,text)','con_dia_descartar(uuid,uuid)','con_estado(uuid)',
      'con_turno(uuid,uuid)','con_admin_resumen(uuid,date,date)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;

-- ---------- Volver a leer, borrar y capturar a mano (también al aclarar un turno sin cierre) ----------
create or replace function _con_puede_editar(p_u con_usuarios, t con_turnos) returns boolean
language sql stable as $$
  select (t.usuario_id = p_u.id or p_u.rol = 'admin')
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

create or replace function con_descartar_evidencia(p_token uuid, p_evid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  select * into t from con_turnos where id = e.turno_id;
  if not _con_puede_editar(u, t) then raise exception 'Ya no se puede modificar este turno.'; end if;
  update con_evidencias set lectura_estado = 'descartado' where id = p_evid;
  perform _con_log(u.id, 'descartar_evidencia', jsonb_build_object('turno', t.id, 'evidencia', p_evid, 'tipo', e.tipo));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_capturar_manual(p_token uuid, p_evid uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; e con_evidencias; t con_turnos; v jsonb; k text; n numeric; v_tipo text;
begin
  u := _con_sesion(p_token);
  select * into e from con_evidencias where id = p_evid;
  if not found then raise exception 'Comprobante no encontrado.'; end if;
  select * into t from con_turnos where id = e.turno_id;
  if not _con_puede_editar(u, t) then raise exception 'Ya no se puede modificar este turno.'; end if;
  if e.lectura_estado <> 'error' then raise exception 'Solo se captura a mano cuando el lector no pudo leer el comprobante.'; end if;
  v_tipo := case when e.tipo = 'auto' then p_datos->>'tipo' else e.tipo end;
  if v_tipo is null or v_tipo not in ('eoptics','depositador','voucher','transferencia') then
    raise exception 'Elige qué tipo de comprobante es.';
  end if;
  v := jsonb_build_object('legible', true, 'manual', true, 'fecha', t.fecha);
  foreach k in array case v_tipo when 'eoptics' then array['efectivo','tarjeta','transferencia']
                                 when 'transferencia' then array['monto'] else array['total'] end loop
    n := coalesce(nullif(p_datos->>k,'')::numeric, 0);
    if n < 0 then raise exception 'Los montos no pueden ser negativos.'; end if;
    v := v || jsonb_build_object(k, round(n, 2));
  end loop;
  update con_evidencias set tipo = v_tipo, lectura_estado = 'ok', lectura = v,
         lectura_error = 'Capturado a mano: ' || coalesce(lectura_error,'') where id = p_evid;
  perform _con_log(u.id, 'captura_manual', jsonb_build_object('turno', t.id, 'evidencia', p_evid, 'tipo', v_tipo, 'datos', v));
  return jsonb_build_object('ok', true);
end $$;

do $$
declare f text;
begin
  execute 'revoke execute on function _con_puede_editar(con_usuarios,con_turnos) from public, anon, authenticated';
  foreach f in array array['con_releer(uuid,uuid,text)','con_descartar_evidencia(uuid,uuid)','con_capturar_manual(uuid,uuid,jsonb)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
