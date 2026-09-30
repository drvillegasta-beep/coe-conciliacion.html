-- COE Conciliación · v2.3 · Alertas por WhatsApp a través del COE Bot
-- Correr una vez en Supabase > SQL Editor. No borra datos.

alter table con_alertas add column if not exists envio_id bigint;

-- Envía la alerta al COE Bot (con clave) y por correo si está configurado
create or replace function _con_enviar(p_alerta uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  a con_alertas; cfg jsonb; tels text[]; v_tel text; v_url text; v_mail boolean; v_req bigint;
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
    if v_tel is not null and not (v_tel = any(tels)) then tels := array_append(tels, v_tel); end if;
  end if;

  v_url := nullif(trim(coalesce(cfg->>'webhook_url','')), '');
  if v_url is not null and array_length(tels, 1) > 0 then
    v_url := regexp_replace(v_url, '/+$', '');
    if v_url !~ '/alerta-caja$' then v_url := v_url || '/alerta-caja'; end if;
    begin
      select net.http_post(
        url := v_url,
        body := jsonb_build_object('origen','coe-conciliacion','tipo',a.tipo,
                                   'mensaje',a.mensaje,'telefonos',to_jsonb(tels)),
        headers := jsonb_build_object('Content-Type','application/json',
                                      'x-coe-key', coalesce(cfg->>'webhook_key',''))
      ) into v_req;
    exception when others then v_req := null;
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
          'service_id', cfg->>'emailjs_service', 'template_id', cfg->>'emailjs_template',
          'user_id', cfg->>'emailjs_public', 'accessToken', cfg->>'emailjs_private',
          'template_params', jsonb_build_object('to_email', cfg->>'email_alertas',
            'subject', 'Caja COE: ' || replace(a.tipo, '_', ' '), 'message', a.mensaje)));
    exception when others then null;
    end;
  end if;

  update con_alertas set enviada = (v_req is not null or v_mail), envio_id = v_req where id = p_alerta;
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
                     'dias_laborables') then
      continue;
    end if;
    if r.key in ('emailjs_private','webhook_key') and r.val = '••••' then continue; end if;
    insert into con_config(clave, valor) values (r.key, r.val)
    on conflict (clave) do update set valor = excluded.valor;
  end loop;
  perform _con_log(u.id, 'guardar_config', p_d - 'emailjs_private' - 'webhook_key');
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
             case when clave in ('emailjs_private','webhook_key') and coalesce(valor,'') <> ''
                  then '••••' else valor end), '{}'::jsonb)
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

-- Botón "Enviar mensaje de prueba" del panel
create or replace function con_admin_probar_aviso(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; v_id uuid; a con_alertas;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  insert into con_alertas(tipo, mensaje)
  values ('prueba', 'Mensaje de prueba de Caja COE enviado por ' || u.nombre || ' a las '
          || to_char(now() at time zone 'America/Mexico_City', 'HH24:MI') || '.')
  returning id into v_id;
  perform _con_enviar(v_id);
  select * into a from con_alertas where id = v_id;
  return jsonb_build_object('ok', true, 'alerta', v_id, 'enviada', a.enviada, 'envio_id', a.envio_id);
end $$;

-- Respuesta del COE Bot a un envío (para diagnosticar)
create or replace function con_admin_estado_envio(p_token uuid, p_alerta uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u con_usuarios; v_req bigint; r record;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  select envio_id into v_req from con_alertas where id = p_alerta;
  if v_req is null then return jsonb_build_object('estado', 'sin_envio'); end if;
  begin
    select status_code, content, error_msg, timed_out into r from net._http_response where id = v_req;
    if not found then return jsonb_build_object('estado', 'pendiente'); end if;
    return jsonb_build_object('estado', 'respondido', 'codigo', r.status_code,
                              'respuesta', left(coalesce(r.content, r.error_msg, ''), 800),
                              'timeout', r.timed_out);
  exception when others then
    return jsonb_build_object('estado', 'desconocido', 'respuesta', sqlerrm);
  end;
end $$;

do $$
declare f text;
begin
  foreach f in array array['_con_enviar(uuid)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['con_admin_guardar_config(uuid,jsonb)','con_admin_catalogo(uuid)',
                           'con_admin_probar_aviso(uuid)','con_admin_estado_envio(uuid,uuid)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;
