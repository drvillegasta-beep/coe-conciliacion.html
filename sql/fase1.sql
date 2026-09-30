-- =====================================================================
-- COE Conciliación v2 · Fase 1
-- Usuarios con contraseña + PIN, fondos de caja, cierre obligatorio,
-- evidencias, diferencias y candado de hora.
--
-- Cómo usarlo: Supabase > proyecto coe-quirofano > SQL Editor >
-- pegar TODO este archivo > Run. Se puede volver a correr sin perder datos.
--
-- Usuario inicial:  director  /  contraseña temporal: CambiarYa2026  /  PIN: 0000
-- (la app obliga a cambiar ambos en el primer ingreso)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------
create table if not exists con_empresas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  creado timestamptz not null default now()
);

create table if not exists con_sucursales (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references con_empresas(id),
  nombre text not null,
  zona text not null default 'America/Mexico_City',
  tolerancia numeric(12,2) not null default 20,
  activa boolean not null default true
);

create table if not exists con_horarios (
  sucursal_id uuid not null references con_sucursales(id) on delete cascade,
  turno text not null check (turno in ('matutino','vespertino')),
  hora_cierre time not null,
  gracia_min int not null default 60 check (gracia_min between 0 and 600),
  primary key (sucursal_id, turno)
);

create table if not exists con_cajas (
  id uuid primary key default gen_random_uuid(),
  sucursal_id uuid not null references con_sucursales(id),
  nombre text not null,
  activa boolean not null default true
);

create table if not exists con_usuarios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  usuario text not null unique,
  telefono text,
  pass_hash text not null,
  pin_hash text not null,
  rol text not null default 'cajero' check (rol in ('admin','supervisor','cajero')),
  activo boolean not null default true,
  bloqueado boolean not null default false,
  intentos_pin int not null default 0,
  debe_cambiar boolean not null default true,
  acepto_reglamento timestamptz,
  creado timestamptz not null default now()
);

create table if not exists con_usuario_sucursal (
  usuario_id uuid not null references con_usuarios(id) on delete cascade,
  sucursal_id uuid not null references con_sucursales(id) on delete cascade,
  primary key (usuario_id, sucursal_id)
);

create table if not exists con_sesiones (
  token uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references con_usuarios(id) on delete cascade,
  expira timestamptz not null
);

create table if not exists con_coberturas (
  id uuid primary key default gen_random_uuid(),
  caja_id uuid not null references con_cajas(id),
  fecha date not null,
  usuario_id uuid not null references con_usuarios(id),
  nota text,
  asignado_por uuid references con_usuarios(id),
  creado timestamptz not null default now(),
  unique (caja_id, fecha, usuario_id)
);

create table if not exists con_turnos (
  id uuid primary key default gen_random_uuid(),
  caja_id uuid not null references con_cajas(id),
  fecha date not null,
  turno text not null check (turno in ('matutino','vespertino')),
  usuario_id uuid not null references con_usuarios(id),
  es_cobertura boolean not null default false,
  abierto_en timestamptz not null default now(),
  fondo_inicial jsonb,
  fondo_inicial_total numeric(12,2) not null default 0,
  fondo_previo numeric(12,2),
  nota_apertura text,
  cerrado_en timestamptz,
  fondo_final jsonb,
  fondo_final_total numeric(12,2),
  pos_efectivo numeric(12,2),
  pos_tarjeta numeric(12,2),
  pos_transferencia numeric(12,2),
  real_depositado numeric(12,2),
  real_voucher numeric(12,2),
  real_banco numeric(12,2),
  gastos_total numeric(12,2) not null default 0,
  dif_efectivo numeric(12,2),
  dif_tarjeta numeric(12,2),
  dif_transferencia numeric(12,2),
  dif_total numeric(12,2),
  estado text not null default 'abierto'
    check (estado in ('abierto','cuadrado','revisar','sobrante','faltante')),
  justificacion text
);
create unique index if not exists con_turnos_un_abierto_por_caja
  on con_turnos(caja_id) where estado = 'abierto';
create index if not exists con_turnos_fecha on con_turnos(fecha);

create table if not exists con_gastos (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references con_turnos(id) on delete cascade,
  monto numeric(12,2) not null check (monto > 0),
  concepto text not null,
  archivo text,
  usuario_id uuid references con_usuarios(id),
  creado timestamptz not null default now()
);

create table if not exists con_evidencias (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references con_turnos(id) on delete cascade,
  tipo text not null check (tipo in ('eoptics','depositador','transferencia','voucher','gasto','otro')),
  archivo text not null,
  usuario_id uuid references con_usuarios(id),
  creado timestamptz not null default now()
);

create table if not exists con_alertas (
  id uuid primary key default gen_random_uuid(),
  tipo text not null,
  sucursal_id uuid,
  caja_id uuid,
  turno_id uuid,
  fecha date,
  turno text,
  mensaje text not null,
  enviada boolean not null default false,
  creada timestamptz not null default now()
);
create unique index if not exists con_alertas_candado_unica
  on con_alertas(tipo, caja_id, fecha, turno)
  where tipo in ('turno_sin_cerrar','turno_sin_registro');

create table if not exists con_config (
  clave text primary key,
  valor text
);

-- Bitácora: solo se inserta, nunca se edita ni se borra desde la app
create table if not exists con_log (
  id bigserial primary key,
  usuario_id uuid,
  accion text not null,
  detalle jsonb,
  creado timestamptz not null default now()
);

-- Nadie entra a las tablas directo: todo pasa por las funciones de abajo
do $$
declare t text;
begin
  foreach t in array array['con_empresas','con_sucursales','con_horarios','con_cajas',
    'con_usuarios','con_usuario_sucursal','con_sesiones','con_coberturas','con_turnos',
    'con_gastos','con_evidencias','con_alertas','con_config','con_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Funciones internas
-- ---------------------------------------------------------------------
create or replace function _con_m(p numeric) returns text
language sql immutable as $$
  select '$' || to_char(coalesce(p,0), 'FM999,999,990.00')
$$;

create or replace function _con_total(p jsonb) returns numeric
language sql immutable as $$
  select coalesce(sum(key::numeric * (value #>> '{}')::numeric), 0)
  from jsonb_each(coalesce(p, '{}'::jsonb))
$$;

create or replace function _con_validar_conteo(p jsonb) returns void
language plpgsql as $$
declare r record; v numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Falta el conteo por denominación.';
  end if;
  for r in select key, value from jsonb_each(p) loop
    if r.key not in ('1000','500','200','100','50','20','10','5','2','1','0.5') then
      raise exception 'Denominación inválida: %', r.key;
    end if;
    if jsonb_typeof(r.value) <> 'number' then
      raise exception 'Cantidad inválida en $%', r.key;
    end if;
    v := (r.value #>> '{}')::numeric;
    if v < 0 or v <> trunc(v) then
      raise exception 'Cantidad inválida en $%', r.key;
    end if;
  end loop;
end $$;

create or replace function _con_sesion(p_token uuid) returns con_usuarios
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios;
begin
  select us.* into u
  from con_sesiones s join con_usuarios us on us.id = s.usuario_id
  where s.token = p_token and s.expira > now() and us.activo;
  if not found then
    raise exception 'SESION: Tu sesión terminó. Vuelve a entrar.';
  end if;
  update con_sesiones set expira = now() + interval '15 minutes' where token = p_token;
  return u;
end $$;

-- Devuelve null si el PIN es correcto, o el mensaje de error.
-- No lanza excepción para que el contador de intentos sí se guarde.
create or replace function _con_pin(p_uid uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios;
begin
  select * into u from con_usuarios where id = p_uid;
  if u.bloqueado then
    return 'Tu PIN está bloqueado. Pide al administrador que lo desbloquee.';
  end if;
  if p_pin is not null and u.pin_hash = extensions.crypt(p_pin, u.pin_hash) then
    update con_usuarios set intentos_pin = 0 where id = p_uid;
    return null;
  end if;
  update con_usuarios
     set intentos_pin = intentos_pin + 1,
         bloqueado = (intentos_pin + 1 >= 5)
   where id = p_uid;
  if u.intentos_pin + 1 >= 5 then
    return 'PIN incorrecto. Se bloqueó tras 5 intentos; pide al administrador que lo desbloquee.';
  end if;
  return 'PIN incorrecto. Te quedan ' || (4 - u.intentos_pin) || ' intentos.';
end $$;

create or replace function _con_log(p_uid uuid, p_accion text, p_detalle jsonb) returns void
language sql security definer set search_path = public as $$
  insert into con_log(usuario_id, accion, detalle) values (p_uid, p_accion, p_detalle)
$$;

create or replace function _con_hoy(p_suc uuid) returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone zona)::date from con_sucursales where id = p_suc
$$;

create or replace function _con_ve_sucursal(p_u con_usuarios, p_suc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_u.rol = 'admin'
      or exists (select 1 from con_usuario_sucursal
                 where usuario_id = p_u.id and sucursal_id = p_suc)
$$;

-- 'admin' | 'titular' | 'cobertura' | null (sin acceso)
create or replace function _con_acceso_caja(p_u con_usuarios, p_caja uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_suc uuid;
begin
  select sucursal_id into v_suc from con_cajas where id = p_caja and activa;
  if v_suc is null then return null; end if;
  if p_u.rol = 'admin' then return 'admin'; end if;
  if exists (select 1 from con_usuario_sucursal
             where usuario_id = p_u.id and sucursal_id = v_suc) then
    return 'titular';
  end if;
  if exists (select 1 from con_coberturas
             where caja_id = p_caja and usuario_id = p_u.id and fecha = _con_hoy(v_suc)) then
    return 'cobertura';
  end if;
  return null;
end $$;

create or replace function _con_rol(p_u con_usuarios, variadic p_roles text[]) returns void
language plpgsql as $$
begin
  if not (p_u.rol = any(p_roles)) then
    raise exception 'No tienes permiso para esta acción.';
  end if;
end $$;

create or replace function _con_etiqueta(p_turno uuid) returns text
language sql stable security definer set search_path = public as $$
  select s.nombre || ' · ' || c.nombre || ' · ' || initcap(t.turno) || ' '
         || to_char(t.fecha, 'DD/MM') || ' · ' || u.nombre
  from con_turnos t
  join con_cajas c on c.id = t.caja_id
  join con_sucursales s on s.id = c.sucursal_id
  join con_usuarios u on u.id = t.usuario_id
  where t.id = p_turno
$$;

create or replace function _con_tel(p text) returns text
language sql immutable as $$
  select case
    when p is null then null
    when length(regexp_replace(p, '\D', '', 'g')) = 10 then '52' || regexp_replace(p, '\D', '', 'g')
    else nullif(regexp_replace(p, '\D', '', 'g'), '')
  end
$$;

-- Envía la alerta por el webhook (COE Bot / WhatsApp) y por correo (EmailJS)
create or replace function _con_enviar(p_alerta uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  a con_alertas;
  cfg jsonb;
  tels text[];
  v_tel text;
  v_url text;
  v_mail boolean;
begin
  select * into a from con_alertas where id = p_alerta;
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb) into cfg from con_config;

  select coalesce(array_agg(x), '{}') into tels
  from (select _con_tel(trim(e)) x
        from unnest(string_to_array(coalesce(cfg->>'wa_alertas',''), ',')) e) q
  where x is not null;

  if a.turno_id is not null then
    select _con_tel(u.telefono) into v_tel
    from con_turnos t join con_usuarios u on u.id = t.usuario_id where t.id = a.turno_id;
    if v_tel is not null and not (v_tel = any(tels)) then
      tels := array_append(tels, v_tel);
    end if;
  end if;

  v_url := nullif(trim(coalesce(cfg->>'webhook_url','')), '');
  if v_url is not null then
    begin
      perform net.http_post(
        url := v_url,
        body := jsonb_build_object('origen','coe-conciliacion','tipo',a.tipo,
                                   'mensaje',a.mensaje,'telefonos',to_jsonb(tels)));
    exception when others then null;
    end;
  end if;

  v_mail := coalesce(cfg->>'emailjs_service','') <> ''
        and coalesce(cfg->>'emailjs_template','') <> ''
        and coalesce(cfg->>'email_alertas','') <> '';
  if v_mail then
    begin
      perform net.http_post(
        url := 'https://api.emailjs.com/api/v1.0/email/send',
        body := jsonb_build_object(
          'service_id', cfg->>'emailjs_service',
          'template_id', cfg->>'emailjs_template',
          'user_id', cfg->>'emailjs_public',
          'accessToken', cfg->>'emailjs_private',
          'template_params', jsonb_build_object(
            'to_email', cfg->>'email_alertas',
            'subject', 'Caja COE: ' || replace(a.tipo, '_', ' '),
            'message', a.mensaje)));
    exception when others then null;
    end;
  end if;

  update con_alertas set enviada = (v_url is not null or v_mail) where id = p_alerta;
end $$;

create or replace function _con_alerta(p_tipo text, p_turno uuid, p_msg text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
  select p_tipo, c.sucursal_id, t.caja_id, t.id, t.fecha, t.turno, p_msg
  from con_turnos t join con_cajas c on c.id = t.caja_id
  where t.id = p_turno
  returning id into v_id;
  perform _con_enviar(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Sesión
-- ---------------------------------------------------------------------
create or replace function con_login(p_usuario text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios; v_tok uuid;
begin
  select * into u from con_usuarios
  where lower(usuario) = lower(trim(p_usuario)) and activo;
  if not found or u.pass_hash <> extensions.crypt(coalesce(p_password,''), u.pass_hash) then
    raise exception 'Usuario o contraseña incorrectos.';
  end if;
  delete from con_sesiones where expira < now();
  insert into con_sesiones(usuario_id, expira)
  values (u.id, now() + interval '15 minutes') returning token into v_tok;
  perform _con_log(u.id, 'login', null);
  return jsonb_build_object('token', v_tok,
                            'debe_cambiar', u.debe_cambiar or u.acepto_reglamento is null);
end $$;

create or replace function con_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from con_sesiones where token = p_token
$$;

create or replace function con_credenciales(p_token uuid, p_pass_actual text, p_pass_nueva text,
                                            p_pin_nuevo text, p_acepto boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  if u.pass_hash <> extensions.crypt(coalesce(p_pass_actual,''), u.pass_hash) then
    raise exception 'La contraseña actual no es correcta.';
  end if;
  if length(coalesce(p_pass_nueva,'')) < 8 then
    raise exception 'La contraseña nueva debe tener al menos 8 caracteres.';
  end if;
  if p_pass_nueva = p_pass_actual then
    raise exception 'Usa una contraseña distinta a la temporal.';
  end if;
  if coalesce(p_pin_nuevo,'') !~ '^[0-9]{4,6}$' then
    raise exception 'El PIN debe tener de 4 a 6 números.';
  end if;
  if p_pin_nuevo ~ '^(\d)\1+$' or p_pin_nuevo in ('1234','12345','123456','4321','654321') then
    raise exception 'Elige un PIN menos obvio.';
  end if;
  if u.acepto_reglamento is null and not coalesce(p_acepto,false) then
    raise exception 'Para continuar debes aceptar el reglamento de caja.';
  end if;
  update con_usuarios
     set pass_hash = extensions.crypt(p_pass_nueva, extensions.gen_salt('bf')),
         pin_hash = extensions.crypt(p_pin_nuevo, extensions.gen_salt('bf')),
         debe_cambiar = false,
         intentos_pin = 0,
         bloqueado = false,
         acepto_reglamento = coalesce(acepto_reglamento, now())
   where id = u.id;
  perform _con_log(u.id, 'credenciales', jsonb_build_object('acepto_reglamento', true));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_estado(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_cajas jsonb;
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

  return jsonb_build_object(
    'usuario', jsonb_build_object('id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'usuario', u.usuario),
    'cajas', v_cajas);
end $$;

-- ---------------------------------------------------------------------
-- Turnos
-- ---------------------------------------------------------------------
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
  if p_turno not in ('matutino','vespertino') then raise exception 'Turno inválido.'; end if;
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
                  'archivo',e.archivo,'creado',e.creado) order by e.creado)
                from con_evidencias e where e.turno_id = t.id), '[]'::jsonb))
  into r
  from con_cajas c join con_sucursales s on s.id = c.sucursal_id
  join con_usuarios uu on uu.id = t.usuario_id
  where c.id = t.caja_id;
  return r;
end $$;

create or replace function con_registrar_evidencia(p_token uuid, p_turno uuid, p_tipo text,
                                                   p_archivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_id uuid;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id and u.rol <> 'admin' then
    raise exception 'Solo quien abrió el turno puede subir evidencias.';
  end if;
  if t.estado <> 'abierto' and u.rol <> 'admin' then
    raise exception 'El turno ya está cerrado.';
  end if;
  if p_tipo not in ('eoptics','depositador','transferencia','voucher','gasto','otro') then
    raise exception 'Tipo de evidencia inválido.';
  end if;
  insert into con_evidencias(turno_id, tipo, archivo, usuario_id)
  values (t.id, p_tipo, p_archivo, u.id) returning id into v_id;
  perform _con_log(u.id, 'evidencia', jsonb_build_object('turno', t.id, 'tipo', p_tipo, 'archivo', p_archivo));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function con_registrar_gasto(p_token uuid, p_turno uuid, p_monto numeric,
                                               p_concepto text, p_archivo text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; v_err text;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno;
  if not found or t.usuario_id <> u.id then raise exception 'Turno no encontrado.'; end if;
  if t.estado <> 'abierto' then raise exception 'El turno ya está cerrado.'; end if;
  if coalesce(p_monto,0) <= 0 then raise exception 'Escribe el monto del gasto.'; end if;
  if coalesce(trim(p_concepto),'') = '' then raise exception 'Escribe en qué se gastó.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  insert into con_gastos(turno_id, monto, concepto, archivo, usuario_id)
  values (t.id, round(p_monto, 2), trim(p_concepto), nullif(p_archivo,''), u.id);
  update con_turnos set gastos_total = (select coalesce(sum(monto),0) from con_gastos where turno_id = t.id)
  where id = t.id;
  perform _con_log(u.id, 'gasto', jsonb_build_object('turno', t.id, 'monto', p_monto, 'concepto', p_concepto));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_cerrar_turno(p_token uuid, p_turno uuid, p_fondo_final jsonb,
                                            p_montos jsonb, p_justificacion text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; v_err text; v_tol numeric; v_g numeric; v_ff numeric;
  pe numeric; pt numeric; ptr numeric; rd numeric; rv numeric; rb numeric;
  de numeric; dt numeric; dtr numeric; dtot numeric; v_estado text; v_msg text;
begin
  u := _con_sesion(p_token);
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if t.usuario_id <> u.id then raise exception 'Solo quien abrió el turno puede cerrarlo.'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado.'; end if;
  perform _con_validar_conteo(p_fondo_final);

  pe  := coalesce(nullif(p_montos->>'pos_efectivo','')::numeric, 0);
  pt  := coalesce(nullif(p_montos->>'pos_tarjeta','')::numeric, 0);
  ptr := coalesce(nullif(p_montos->>'pos_transferencia','')::numeric, 0);
  rd  := coalesce(nullif(p_montos->>'real_depositado','')::numeric, 0);
  rv  := coalesce(nullif(p_montos->>'real_voucher','')::numeric, 0);
  rb  := coalesce(nullif(p_montos->>'real_banco','')::numeric, 0);
  if least(pe, pt, ptr, rd, rv, rb) < 0 then
    raise exception 'Los montos no pueden ser negativos.';
  end if;

  if not exists (select 1 from con_evidencias where turno_id = t.id and tipo = 'eoptics') then
    raise exception 'Sube el PDF del corte de eOptics antes de cerrar.';
  end if;
  if rd > 0 and not exists (select 1 from con_evidencias where turno_id = t.id and tipo = 'depositador') then
    raise exception 'Sube la foto del ticket del depositador.';
  end if;
  if (pt > 0 or rv > 0) and not exists (select 1 from con_evidencias where turno_id = t.id and tipo = 'voucher') then
    raise exception 'Hay cobros con tarjeta: sube la foto del voucher de cierre de lote.';
  end if;
  if (ptr > 0 or rb > 0) and not exists (select 1 from con_evidencias where turno_id = t.id and tipo = 'transferencia') then
    raise exception 'Hay cobros por transferencia: sube las capturas del banco.';
  end if;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  select s.tolerancia into v_tol
  from con_cajas c join con_sucursales s on s.id = c.sucursal_id where c.id = t.caja_id;
  v_g  := coalesce((select sum(monto) from con_gastos where turno_id = t.id), 0);
  v_ff := _con_total(p_fondo_final);

  -- Efectivo: lo que salió de caja (depositado + fondo final + gastos)
  --           contra lo que debía haber (fondo inicial + efectivo cobrado)
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
    perform _con_log(u.id, 'cierre_con_diferencia_visto', jsonb_build_object(
      'turno', t.id, 'dif_total', dtot, 'fondo_final', v_ff, 'montos', p_montos));
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
    'dif_efectivo', de, 'dif_tarjeta', dt, 'dif_transferencia', dtr, 'fondo_final', v_ff);
end $$;

-- ---------------------------------------------------------------------
-- Panel (administrador y supervisor)
-- ---------------------------------------------------------------------
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

create or replace function con_admin_alertas(p_token uuid, p_limite int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'mensaje', a.mensaje,
                              'creada', a.creada, 'enviada', a.enviada, 'turno_id', a.turno_id) x
    from con_alertas a
    where a.sucursal_id is null or _con_ve_sucursal(u, a.sucursal_id)
    order by a.creada desc limit greatest(coalesce(p_limite, 50), 1)) q), '[]'::jsonb);
end $$;

create or replace function con_admin_usuarios(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'nombre', x.nombre, 'usuario', x.usuario, 'telefono', x.telefono,
      'rol', x.rol, 'activo', x.activo, 'bloqueado', x.bloqueado,
      'debe_cambiar', x.debe_cambiar, 'acepto_reglamento', x.acepto_reglamento,
      'sucursales', coalesce((select jsonb_agg(us.sucursal_id) from con_usuario_sucursal us
                              where us.usuario_id = x.id), '[]'::jsonb))
      order by x.activo desc, x.nombre)
    from con_usuarios x
    where u.rol = 'admin'
       or exists (select 1 from con_usuario_sucursal a join con_usuario_sucursal b
                  on a.sucursal_id = b.sucursal_id
                  where a.usuario_id = u.id and b.usuario_id = x.id)), '[]'::jsonb);
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
  if v_rol not in ('admin','supervisor','cajero') then raise exception 'Rol inválido.'; end if;
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

create or replace function con_admin_desbloquear(p_token uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  update con_usuarios set bloqueado = false, intentos_pin = 0 where id = p_id;
  perform _con_log(u.id, 'desbloquear', jsonb_build_object('usuario', p_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_admin_catalogo(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_cfg jsonb := '{}'::jsonb;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  if u.rol = 'admin' then
    select coalesce(jsonb_object_agg(clave,
             case when clave = 'emailjs_private' and coalesce(valor,'') <> '' then '••••' else valor end),
           '{}'::jsonb)
    into v_cfg from con_config;
  end if;
  return jsonb_build_object(
    'sucursales', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'nombre', s.nombre, 'tolerancia', s.tolerancia, 'activa', s.activa,
        'horarios', (select jsonb_object_agg(h.turno, jsonb_build_object(
            'cierre', to_char(h.hora_cierre,'HH24:MI'), 'gracia', h.gracia_min))
          from con_horarios h where h.sucursal_id = s.id),
        'cajas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre,
            'activa', c.activa) order by c.nombre) from con_cajas c where c.sucursal_id = s.id), '[]'::jsonb))
        order by s.nombre)
      from con_sucursales s where _con_ve_sucursal(u, s.id)), '[]'::jsonb),
    'config', v_cfg);
end $$;

create or replace function con_admin_guardar_sucursal(p_token uuid, p_d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_id uuid; v_emp uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  if coalesce(trim(p_d->>'nombre'),'') = '' then raise exception 'Escribe el nombre de la sucursal.'; end if;
  v_id := nullif(p_d->>'id','')::uuid;
  if v_id is null then
    select id into v_emp from con_empresas order by creado limit 1;
    insert into con_sucursales(empresa_id, nombre, tolerancia)
    values (v_emp, trim(p_d->>'nombre'), coalesce((p_d->>'tolerancia')::numeric, 20))
    returning id into v_id;
  else
    update con_sucursales set nombre = trim(p_d->>'nombre'),
      tolerancia = coalesce((p_d->>'tolerancia')::numeric, tolerancia),
      activa = coalesce((p_d->>'activa')::boolean, activa)
    where id = v_id;
  end if;
  insert into con_horarios(sucursal_id, turno, hora_cierre, gracia_min) values
    (v_id, 'matutino', coalesce(nullif(p_d->>'matutino_cierre','')::time, '14:30'),
                       coalesce((p_d->>'matutino_gracia')::int, 120)),
    (v_id, 'vespertino', coalesce(nullif(p_d->>'vespertino_cierre','')::time, '18:00'),
                         coalesce((p_d->>'vespertino_gracia')::int, 60))
  on conflict (sucursal_id, turno) do update
    set hora_cierre = excluded.hora_cierre, gracia_min = excluded.gracia_min;
  perform _con_log(u.id, 'guardar_sucursal', p_d);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function con_admin_guardar_caja(p_token uuid, p_d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_id uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  if coalesce(trim(p_d->>'nombre'),'') = '' then raise exception 'Escribe el nombre de la caja.'; end if;
  v_id := nullif(p_d->>'id','')::uuid;
  if v_id is null then
    insert into con_cajas(sucursal_id, nombre) values ((p_d->>'sucursal_id')::uuid, trim(p_d->>'nombre'))
    returning id into v_id;
  else
    update con_cajas set nombre = trim(p_d->>'nombre'),
      activa = coalesce((p_d->>'activa')::boolean, activa) where id = v_id;
  end if;
  perform _con_log(u.id, 'guardar_caja', p_d);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function con_admin_guardar_config(p_token uuid, p_d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; r record;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  for r in select key, value #>> '{}' as val from jsonb_each(p_d) loop
    if r.key not in ('wa_alertas','wa_resumen','email_alertas','webhook_url','emailjs_service',
                     'emailjs_template','emailjs_public','emailjs_private','dias_laborables') then
      continue;
    end if;
    if r.key = 'emailjs_private' and r.val = '••••' then continue; end if;
    insert into con_config(clave, valor) values (r.key, r.val)
    on conflict (clave) do update set valor = excluded.valor;
  end loop;
  perform _con_log(u.id, 'guardar_config', p_d - 'emailjs_private');
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_admin_cobertura(p_token uuid, p_caja uuid, p_fecha date,
                                               p_usuario uuid, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_suc uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  select sucursal_id into v_suc from con_cajas where id = p_caja;
  if v_suc is null or not _con_ve_sucursal(u, v_suc) then
    raise exception 'No tienes acceso a esa caja.';
  end if;
  if p_fecha < _con_hoy(v_suc) then raise exception 'La fecha ya pasó.'; end if;
  insert into con_coberturas(caja_id, fecha, usuario_id, nota, asignado_por)
  values (p_caja, p_fecha, p_usuario, nullif(trim(p_nota),''), u.id)
  on conflict (caja_id, fecha, usuario_id) do update set nota = excluded.nota;
  perform _con_log(u.id, 'cobertura', jsonb_build_object('caja', p_caja, 'fecha', p_fecha, 'usuario', p_usuario));
  return jsonb_build_object('ok', true);
end $$;

create or replace function con_admin_coberturas(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'supervisor');
  return coalesce((select jsonb_agg(jsonb_build_object('id', cb.id, 'fecha', cb.fecha,
      'caja', c.nombre, 'sucursal', s.nombre, 'usuario', uu.nombre, 'nota', cb.nota)
      order by cb.fecha, s.nombre, c.nombre)
    from con_coberturas cb
    join con_cajas c on c.id = cb.caja_id
    join con_sucursales s on s.id = c.sucursal_id
    join con_usuarios uu on uu.id = cb.usuario_id
    where cb.fecha >= (now() at time zone s.zona)::date - 7 and _con_ve_sucursal(u, s.id)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- Candado de hora (lo corre pg_cron cada 10 minutos)
-- ---------------------------------------------------------------------
create or replace function con_revisar_candado() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record; t record; c record;
  v_local timestamp; v_hoy date; v_limite time; v_id uuid; n int := 0; v_dias text;
begin
  select coalesce(valor, '1,2,3,4,5,6') into v_dias from con_config where clave = 'dias_laborables';
  v_dias := coalesce(v_dias, '1,2,3,4,5,6');

  for r in
    select s.id sucursal_id, s.nombre, s.zona, h.turno, h.hora_cierre, h.gracia_min
    from con_sucursales s join con_horarios h on h.sucursal_id = s.id
    where s.activa
  loop
    v_local := now() at time zone r.zona;
    v_hoy := v_local::date;
    v_limite := r.hora_cierre + make_interval(mins => r.gracia_min);

    -- Turnos abiertos de hoy (o de días anteriores) que pasaron su hora límite
    for t in
      select tt.id, tt.caja_id, tt.fecha, tt.turno
      from con_turnos tt join con_cajas cc on cc.id = tt.caja_id
      where cc.sucursal_id = r.sucursal_id and tt.estado = 'abierto' and tt.turno = r.turno
        and (tt.fecha < v_hoy or v_local::time >= v_limite)
    loop
      v_id := null;
      insert into con_alertas(tipo, sucursal_id, caja_id, turno_id, fecha, turno, mensaje)
      values ('turno_sin_cerrar', r.sucursal_id, t.caja_id, t.id, t.fecha, t.turno,
              _con_etiqueta(t.id) || ': el turno sigue abierto; debía cerrarse a las '
              || to_char(r.hora_cierre, 'HH24:MI') || '.')
      on conflict (tipo, caja_id, fecha, turno)
        where tipo in ('turno_sin_cerrar','turno_sin_registro') do nothing
      returning id into v_id;
      if v_id is not null then perform _con_enviar(v_id); n := n + 1; end if;
    end loop;

    -- Cajas que no abrieron turno en un día laborable
    if position(extract(isodow from v_local)::int::text in v_dias) > 0
       and v_local::time >= v_limite then
      for c in
        select cc.id from con_cajas cc
        where cc.sucursal_id = r.sucursal_id and cc.activa
          and not exists (select 1 from con_turnos tt
                          where tt.caja_id = cc.id and tt.fecha = v_hoy and tt.turno = r.turno)
          and not exists (select 1 from con_turnos tt
                          where tt.caja_id = cc.id and tt.estado = 'abierto')
      loop
        v_id := null;
        insert into con_alertas(tipo, sucursal_id, caja_id, fecha, turno, mensaje)
        select 'turno_sin_registro', r.sucursal_id, cc.id, v_hoy, r.turno,
               r.nombre || ' · ' || cc.nombre || ' · ' || initcap(r.turno) || ' '
               || to_char(v_hoy, 'DD/MM') || ': no se registró turno y ya pasó la hora límite ('
               || to_char(v_limite, 'HH24:MI') || ').'
        from con_cajas cc where cc.id = c.id
        on conflict (tipo, caja_id, fecha, turno)
          where tipo in ('turno_sin_cerrar','turno_sin_registro') do nothing
        returning id into v_id;
        if v_id is not null then perform _con_enviar(v_id); n := n + 1; end if;
      end loop;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Permisos: la app (anon) solo puede llamar las funciones públicas con_*
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like '\_con\_%' or p.proname like 'con\_%')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'con\_%' and f.proname <> 'con_revisar_candado' then
      execute format('grant execute on function %s to anon', f.sig);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Almacenamiento de evidencias (fotos y PDF)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('con-evidencias', 'con-evidencias', false)
on conflict (id) do nothing;

drop policy if exists con_evid_subir on storage.objects;
create policy con_evid_subir on storage.objects
  for insert to anon with check (bucket_id = 'con-evidencias');

drop policy if exists con_evid_ver on storage.objects;
create policy con_evid_ver on storage.objects
  for select to anon using (bucket_id = 'con-evidencias');

-- ---------------------------------------------------------------------
-- Datos iniciales (solo la primera vez)
-- ---------------------------------------------------------------------
do $$
declare v_emp uuid; v_suc uuid; v_adm uuid;
begin
  if not exists (select 1 from con_empresas) then
    insert into con_empresas(nombre) values ('Centro Ocular Especializado') returning id into v_emp;
    insert into con_sucursales(empresa_id, nombre, tolerancia) values (v_emp, 'COE Tacámbaro', 20)
      returning id into v_suc;
    insert into con_horarios(sucursal_id, turno, hora_cierre, gracia_min) values
      (v_suc, 'matutino', '14:30', 120),
      (v_suc, 'vespertino', '18:00', 60);
    insert into con_cajas(sucursal_id, nombre) values
      (v_suc, 'Clínica y óptica'), (v_suc, 'Farmacia');
    insert into con_usuarios(nombre, usuario, telefono, rol, pass_hash, pin_hash, debe_cambiar)
    values ('Dr. José Antonio Villegas Ávila', 'director', '4432068194', 'admin',
            extensions.crypt('CambiarYa2026', extensions.gen_salt('bf')),
            extensions.crypt('0000', extensions.gen_salt('bf')), true)
    returning id into v_adm;
    insert into con_usuario_sucursal values (v_adm, v_suc);
    insert into con_config(clave, valor) values
      ('wa_alertas', '4432068194'),
      ('wa_resumen', '4432068194,6643036225,4434183174'),
      ('dias_laborables', '1,2,3,4,5,6')
    on conflict (clave) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Programar el candado cada 10 minutos
-- ---------------------------------------------------------------------
select cron.schedule('coe-con-candado', '*/10 * * * *', 'select public.con_revisar_candado();');
