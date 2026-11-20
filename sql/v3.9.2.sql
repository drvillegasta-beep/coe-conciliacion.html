-- COE Conciliación · v3.9.2 · La sesión de Dirección (rol admin) no vence por inactividad; dura hasta las 18:30 (hora de México)
-- En la app: Dirección no se sale por inactividad (solo se pausa), la sesión sigue aunque se cierre la app y se cierra a las 18:30.
-- Cajeras y Contabilidad siguen con el cierre por 10 minutos sin uso.
create or replace function _con_sesion(p_token uuid) returns con_usuarios
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios; v_cierre timestamptz;
begin
  select us.* into u
  from con_sesiones s join con_usuarios us on us.id = s.usuario_id
  where s.token = p_token and s.expira > now() and us.activo;
  if not found then
    raise exception 'SESION: Tu sesión terminó. Vuelve a entrar.';
  end if;
  v_cierre := ((now() at time zone 'America/Mexico_City')::date + time '18:30') at time zone 'America/Mexico_City';
  update con_sesiones set expira = case when u.rol = 'admin' and v_cierre > now() + interval '15 minutes'
                                        then v_cierre else now() + interval '15 minutes' end
   where token = p_token;
  return u;
end $$;
