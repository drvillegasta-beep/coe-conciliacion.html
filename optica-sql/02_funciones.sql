-- ===== Utilidades internas =====
create or replace function public.opt__sesion(p_token uuid)
returns public.opt_usuarios language plpgsql security definer set search_path=public, extensions as $$
declare u public.opt_usuarios; s public.opt_sesiones;
begin
  select * into s from opt_sesiones where token=p_token;
  if not found or s.ultimo < now() - interval '14 days' then
    raise exception 'SESION: Su sesión terminó. Entre de nuevo.';
  end if;
  select * into u from opt_usuarios where id=s.usuario_id and activo;
  if not found then raise exception 'SESION: Usuario inactivo.'; end if;
  update opt_sesiones set ultimo=now() where token=p_token and ultimo < now() - interval '1 minute';
  return u;
end $$;

create or replace function public.opt__pin(u public.opt_usuarios, p_pin text)
returns void language plpgsql security definer set search_path=public, extensions as $$
begin
  if u.pin_hash is null then raise exception 'PIN: El usuario no tiene PIN configurado.'; end if;
  if u.intentos_pin >= 5 then raise exception 'PIN: PIN bloqueado por intentos fallidos. Pida a Dirección que lo restablezca.'; end if;
  if p_pin is null or crypt(p_pin, u.pin_hash) <> u.pin_hash then
    update opt_usuarios set intentos_pin=intentos_pin+1 where id=u.id;
    raise exception 'PIN: PIN incorrecto.';
  end if;
  update opt_usuarios set intentos_pin=0 where id=u.id;
end $$;

create or replace function public.opt__log(p_uid uuid, p_accion text, p_ent text, p_datos jsonb)
returns void language sql security definer set search_path=public as $$
  insert into opt_log(usuario_id, accion, entidad_id, datos) values (p_uid, p_accion, p_ent, p_datos);
$$;

create or replace function public.opt__pagado(p_trabajo uuid)
returns numeric language sql stable security definer set search_path=public as $$
  select coalesce(sum(monto),0) from opt_pagos where trabajo_id=p_trabajo;
$$;

-- ===== Acceso =====
create or replace function public.opt_login(p_usuario text, p_pass text)
returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare u public.opt_usuarios; t uuid;
begin
  select * into u from opt_usuarios where lower(usuario)=lower(trim(p_usuario));
  if not found or not u.activo then raise exception 'LOGIN: Usuario o contraseña incorrectos.'; end if;
  if u.bloqueo_hasta is not null and u.bloqueo_hasta > now() then
    raise exception 'LOGIN: Demasiados intentos. Intente de nuevo en 15 minutos.'; end if;
  if crypt(p_pass, u.pass_hash) <> u.pass_hash then
    update opt_usuarios set intentos_login=intentos_login+1,
      bloqueo_hasta=case when intentos_login+1>=5 then now()+interval '15 minutes' else null end where id=u.id;
    raise exception 'LOGIN: Usuario o contraseña incorrectos.';
  end if;
  update opt_usuarios set intentos_login=0, bloqueo_hasta=null where id=u.id;
  insert into opt_sesiones(usuario_id) values (u.id) returning token into t;
  perform opt__log(u.id,'login',null,null);
  return jsonb_build_object('token',t,'usuario',jsonb_build_object('id',u.id,'nombre',u.nombre,'usuario',u.usuario,'rol',u.rol,'sede',u.sede,'debe_cambiar',u.debe_cambiar));
end $$;

create or replace function public.opt_logout(p_token uuid)
returns void language sql security definer set search_path=public as $$
  delete from opt_sesiones where token=p_token;
$$;

create or replace function public.opt_cambiar_acceso(p_token uuid, p_actual text, p_nueva text, p_pin text)
returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare u public.opt_usuarios;
begin
  u := opt__sesion(p_token);
  if crypt(p_actual, u.pass_hash) <> u.pass_hash then raise exception 'ACCESO: La contraseña actual no es correcta.'; end if;
  if length(coalesce(p_nueva,'')) < 8 then raise exception 'ACCESO: La contraseña nueva debe tener al menos 8 caracteres.'; end if;
  if coalesce(p_pin,'') !~ '^\d{4,6}$' then raise exception 'ACCESO: El PIN debe tener de 4 a 6 dígitos.'; end if;
  update opt_usuarios set pass_hash=crypt(p_nueva, gen_salt('bf')), pin_hash=crypt(p_pin, gen_salt('bf')), debe_cambiar=false, intentos_pin=0 where id=u.id;
  perform opt__log(u.id,'cambio_acceso',u.id::text,null);
  return jsonb_build_object('ok',true);
end $$;

-- opt_datos: ver 04_datos.sql (versión corregida)
