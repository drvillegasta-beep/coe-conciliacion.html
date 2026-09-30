-- COE Conciliación · v2.2 · Inicio de sesión con menú de usuarios
-- Correr una vez en Supabase > SQL Editor. No borra datos.

alter table con_usuarios add column if not exists intentos_login int not null default 0;
alter table con_usuarios add column if not exists bloqueo_login_hasta timestamptz;

-- Lista para el menú de inicio de sesión (solo usuarios activos)
create or replace function con_lista_login() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('usuario', usuario, 'nombre', nombre) order by nombre), '[]'::jsonb)
  from con_usuarios where activo
$$;

-- Login: 5 intentos fallidos bloquean 10 minutos. Devuelve {ok:false, error} en vez de fallar,
-- para que el contador de intentos sí se guarde.
create or replace function con_login(p_usuario text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios; v_tok uuid; v_min int;
begin
  select * into u from con_usuarios where lower(usuario) = lower(trim(p_usuario)) and activo;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Usuario o contraseña incorrectos.');
  end if;
  if u.bloqueo_login_hasta is not null and u.bloqueo_login_hasta > now() then
    v_min := ceil(extract(epoch from (u.bloqueo_login_hasta - now())) / 60);
    return jsonb_build_object('ok', false, 'error',
      'Demasiados intentos. Espera ' || v_min || ' min o pide al administrador que te restablezca.');
  end if;
  if u.pass_hash <> extensions.crypt(coalesce(p_password,''), u.pass_hash) then
    update con_usuarios
       set intentos_login = case when intentos_login + 1 >= 5 then 0 else intentos_login + 1 end,
           bloqueo_login_hasta = case when intentos_login + 1 >= 5 then now() + interval '10 minutes' else null end
     where id = u.id;
    if u.intentos_login + 1 >= 5 then
      perform _con_log(u.id, 'login_bloqueado', null);
      return jsonb_build_object('ok', false, 'error', 'Contraseña incorrecta. Se bloqueó 10 minutos tras 5 intentos.');
    end if;
    return jsonb_build_object('ok', false, 'error',
      case when 4 - u.intentos_login = 1 then 'Contraseña incorrecta. Te queda 1 intento.'
           else 'Contraseña incorrecta. Te quedan ' || (4 - u.intentos_login) || ' intentos.' end);
  end if;
  update con_usuarios set intentos_login = 0, bloqueo_login_hasta = null where id = u.id;
  delete from con_sesiones where expira < now();
  insert into con_sesiones(usuario_id, expira)
  values (u.id, now() + interval '15 minutes') returning token into v_tok;
  perform _con_log(u.id, 'login', null);
  return jsonb_build_object('ok', true, 'token', v_tok,
                            'debe_cambiar', u.debe_cambiar or u.acepto_reglamento is null);
end $$;

-- Al restablecer desde el panel también se quita el bloqueo de inicio de sesión
create or replace function con_admin_desbloquear(p_token uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  update con_usuarios set bloqueado = false, intentos_pin = 0,
                          intentos_login = 0, bloqueo_login_hasta = null
   where id = p_id;
  perform _con_log(u.id, 'desbloquear', jsonb_build_object('usuario', p_id));
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function con_lista_login() from public, authenticated;
revoke execute on function con_login(text, text) from public, authenticated;
revoke execute on function con_admin_desbloquear(uuid, uuid) from public, authenticated;
grant execute on function con_lista_login() to anon;
grant execute on function con_login(text, text) to anon;
grant execute on function con_admin_desbloquear(uuid, uuid) to anon;
