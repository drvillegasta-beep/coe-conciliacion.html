create or replace function public.opt_accion(p_token uuid, p_accion text, p_data jsonb default '{}'::jsonb, p_pin text default null)
returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare
  u public.opt_usuarios; t public.opt_trabajos; cfg jsonb; v_id uuid; v_txt text; v_num numeric; v_total numeric; v_pag numeric;
  v_pac uuid; r jsonb; v_hoy date := (now() at time zone 'America/Mexico_City')::date; x jsonb;
begin
  u := opt__sesion(p_token);
  select valor into cfg from opt_config where clave='general';

  if p_accion = 'trabajo_crear' then
    if u.rol not in ('ventas','admin') then raise exception 'PERMISO: Solo Ventas o Dirección capturan trabajos.'; end if;
    if coalesce(p_data->>'venta','') !~ '^\d{3,}$' then raise exception 'DATOS: Falta el número de venta de eOptics.'; end if;
    if exists(select 1 from opt_trabajos where venta=p_data->>'venta') then raise exception 'DATOS: La venta % ya está registrada. Un ticket no se puede usar dos veces.', p_data->>'venta'; end if;
    if coalesce(p_data#>>'{pago,archivo}','')='' then raise exception 'DATOS: Suba el ticket de venta de eOptics.'; end if;
    if coalesce((p_data->>'garantia_firmada')::boolean,false) is not true then raise exception 'DATOS: Falta la firma de las políticas de garantía.'; end if;
    v_total := coalesce((p_data->>'total')::numeric,0);
    if v_total <= 0 then raise exception 'DATOS: El total de la venta debe ser mayor a cero.'; end if;
    v_num := coalesce((p_data#>>'{pago,monto}')::numeric,0);
    if v_num <= 0 then raise exception 'DATOS: Falta el monto del anticipo del ticket.'; end if;
    if v_num > v_total then raise exception 'DATOS: El anticipo no puede ser mayor al total.'; end if;
    insert into opt_trabajos(venta,id_trabajo,paciente_id,paciente_nombre,telefono,sede,asesora_id,fecha_venta,laboratorio,tipo,material,tratamiento,rx,armazon,precio,costo,total,respaldo,referido,garantia_firmada,ticket_archivo,ticket_leido,eventos)
    values (p_data->>'venta', p_data->>'id_trabajo', nullif(p_data->>'paciente_id','')::uuid, p_data->>'paciente_nombre', p_data->>'telefono',
      coalesce(p_data->>'sede',u.sede), u.id, coalesce((p_data->>'fecha_venta')::date, v_hoy), p_data->>'laboratorio', p_data->>'tipo', p_data->>'material', p_data->>'tratamiento',
      coalesce(p_data->'rx','{}'), coalesce(p_data->'armazon','{}'), coalesce(p_data->'precio','{}'), coalesce(p_data->'costo','{}'), v_total,
      coalesce((p_data->>'respaldo')::boolean,false), nullif(upper(p_data->>'referido'),''), true, p_data#>>'{pago,archivo}', p_data->'ticket_leido',
      jsonb_build_object('capturado', now()))
    returning id into v_id;
    insert into opt_pagos(trabajo_id,monto,forma,archivo,origen,creado_por)
      values (v_id, v_num, coalesce(p_data#>>'{pago,forma}','Efectivo'), p_data#>>'{pago,archivo}', case when (p_data#>>'{pago,leido}')::boolean then 'leido' else 'capturado' end, u.id);
    perform opt__log(u.id,'trabajo_crear',v_id::text,p_data);
    return jsonb_build_object('id',v_id);

  elsif p_accion = 'trabajo_estado' then
    select * into t from opt_trabajos where id=(p_data->>'id')::uuid for update;
    if not found then raise exception 'DATOS: Trabajo no encontrado.'; end if;
    v_txt := p_data->>'estado';
    if v_txt not in ('enviado','recibido','listo','avisado','entregado','garantia') then raise exception 'DATOS: Etapa no válida.'; end if;
    v_pag := opt__pagado(t.id);
    if v_txt='enviado' and v_pag < t.total * (cfg->>'anticipo')::numeric/100 then
      raise exception 'REGLA: El anticipo es menor al % por ciento. No se puede enviar al laboratorio.', cfg->>'anticipo'; end if;
    if v_txt='entregado' then
      if v_pag < t.total then raise exception 'REGLA: No se entrega con saldo pendiente (% por cobrar).', t.total-v_pag; end if;
      if t.estado <> 'avisado' and t.estado <> 'listo' then raise exception 'REGLA: Solo se entrega un trabajo que pasó la revisión de calidad.'; end if;
    end if;
    if v_txt='listo' and t.estado <> 'recibido' then raise exception 'REGLA: Primero registre la llegada del trabajo.'; end if;
    update opt_trabajos set estado=v_txt,
      eventos = eventos || jsonb_build_object(v_txt, now()),
      llega = coalesce((p_data->>'llega')::date, case when v_txt='enviado' and llega is null then v_hoy + coalesce((select (l->>'dias')::int from jsonb_array_elements(cfg->'labs') l where l->>'nombre'=t.laboratorio limit 1),5) else llega end),
      checklist = case when v_txt='recibido' then '{}'::jsonb else checklist end,
      garantia_motivo = coalesce(p_data->>'motivo', garantia_motivo)
      where id=t.id;
    -- Al entregar: código de referido del paciente
    if v_txt='entregado' and not exists(select 1 from opt_referidos where paciente_nombre=t.paciente_nombre) then
      insert into opt_referidos(codigo,paciente_nombre,telefono) values ('COE-'||nextval('opt_referido_seq'), t.paciente_nombre, t.telefono);
    end if;
    -- Garantía imputable a la asesora con comisión ya pagada: contracargo
    if v_txt='garantia' and coalesce((p_data->>'imputable_asesora')::boolean,false) then
      select (c.detalle->(t.id::text)->>'monto')::numeric into v_num from opt_comisiones_cierres c where c.detalle ? (t.id::text) order by c.creado desc limit 1;
      if v_num is not null and v_num > 0 then
        insert into opt_contracargos(trabajo_id,asesora_id,monto,motivo) values (t.id, t.asesora_id, v_num, coalesce(p_data->>'motivo','Garantía imputable a la asesora'));
      end if;
    end if;
    perform opt__log(u.id,'trabajo_estado',t.id::text,p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'trabajo_checklist' then
    update opt_trabajos set checklist = coalesce(p_data->'checklist','{}') where id=(p_data->>'id')::uuid;
    return jsonb_build_object('ok',true);

  elsif p_accion = 'trabajo_respaldo' then
    update opt_trabajos set respaldo=true, eventos = eventos || jsonb_build_object('respaldo_archivo', p_data->>'archivo') where id=(p_data->>'id')::uuid;
    perform opt__log(u.id,'trabajo_respaldo',p_data->>'id',p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'pedido_enviar' then
    for v_id in select (jsonb_array_elements_text(p_data->'ids'))::uuid loop
      select * into t from opt_trabajos where id=v_id for update;
      if t.estado='capturado' and opt__pagado(t.id) >= t.total*(cfg->>'anticipo')::numeric/100 then
        update opt_trabajos set estado='enviado', eventos=eventos||jsonb_build_object('enviado',now()), llega=coalesce((p_data->>'llega')::date, v_hoy+5) where id=v_id;
      end if;
    end loop;
    perform opt__log(u.id,'pedido_enviar',null,p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'pago_registrar' then
    select * into t from opt_trabajos where id=(p_data->>'trabajo_id')::uuid;
    if not found then raise exception 'DATOS: Trabajo no encontrado.'; end if;
    if coalesce(p_data->>'archivo','')='' then raise exception 'DATOS: Suba el ticket de eOptics del pago.'; end if;
    v_num := (p_data->>'monto')::numeric;
    if v_num is null or v_num<=0 then raise exception 'DATOS: Monto no válido.'; end if;
    if v_num > t.total - opt__pagado(t.id) + 0.01 then raise exception 'DATOS: El pago es mayor al saldo pendiente.'; end if;
    insert into opt_pagos(trabajo_id,monto,forma,archivo,origen,creado_por) values (t.id, v_num, coalesce(p_data->>'forma','Efectivo'), p_data->>'archivo', case when (p_data->>'leido')::boolean then 'leido' else 'capturado' end, u.id);
    perform opt__log(u.id,'pago_registrar',t.id::text,p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'pago_verificar' then
    if u.rol not in ('admin','contabilidad') then raise exception 'PERMISO: Solo Administración verifica tickets.'; end if;
    update opt_pagos set verificado=true, verificado_por=u.id where id=(p_data->>'id')::uuid;
    perform opt__log(u.id,'pago_verificar',p_data->>'id',null);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'pago_corregir' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección corrige pagos.'; end if;
    perform opt__pin(u, p_pin);
    select to_jsonb(p) into r from opt_pagos p where id=(p_data->>'id')::uuid;
    update opt_pagos set monto=(p_data->>'monto')::numeric, verificado=true, verificado_por=u.id where id=(p_data->>'id')::uuid;
    perform opt__log(u.id,'pago_corregir',p_data->>'id',jsonb_build_object('antes',r,'despues',p_data));
    return jsonb_build_object('ok',true);

  elsif p_accion = 'paciente_crear' then
    if coalesce(trim(p_data->>'nombre'),'')='' then raise exception 'DATOS: Falta el nombre del paciente.'; end if;
    insert into opt_pacientes(expediente,nombre,nacimiento,telefono,sede,creado_por)
      values ('EXP-'||nextval('opt_expediente_seq'), trim(p_data->>'nombre'), (p_data->>'nacimiento')::date, p_data->>'telefono', coalesce(p_data->>'sede',u.sede), u.id)
      returning id into v_pac;
    if p_data ? 'examen' then
      insert into opt_examenes(paciente_id,optometrista,av,rx,dx,notas,archivo,creado_por)
      values (v_pac, p_data#>>'{examen,optometrista}', coalesce(p_data#>'{examen,av}','{}'), coalesce(p_data#>'{examen,rx}','{}'),
        coalesce(array(select jsonb_array_elements_text(p_data#>'{examen,dx}')),'{}'), p_data#>>'{examen,notas}', p_data#>>'{examen,archivo}', u.id);
    end if;
    perform opt__log(u.id,'paciente_crear',v_pac::text,p_data);
    return jsonb_build_object('id',v_pac);

  elsif p_accion = 'examen_crear' then
    insert into opt_examenes(paciente_id,optometrista,av,rx,dx,notas,archivo,creado_por)
    values ((p_data->>'paciente_id')::uuid, p_data#>>'{examen,optometrista}', coalesce(p_data#>'{examen,av}','{}'), coalesce(p_data#>'{examen,rx}','{}'),
      coalesce(array(select jsonb_array_elements_text(p_data#>'{examen,dx}')),'{}'), p_data#>>'{examen,notas}', p_data#>>'{examen,archivo}', u.id);
    perform opt__log(u.id,'examen_crear',p_data->>'paciente_id',p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'posventa_resultado' then
    insert into opt_posventa(clave,motivo,paciente,resultado,usuario_id) values (p_data->>'clave', p_data->>'motivo', p_data->>'paciente', p_data->>'resultado', u.id)
      on conflict (clave) do update set resultado=excluded.resultado, fecha=now(), usuario_id=u.id;
    return jsonb_build_object('ok',true);

  elsif p_accion = 'aviso_registrar' then
    update opt_trabajos set eventos = eventos || jsonb_build_object('aviso_'||coalesce(p_data->>'tipo','x'), now()) where id=(p_data->>'id')::uuid;
    perform opt__log(u.id,'aviso',p_data->>'id',p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'config_guardar' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección cambia la configuración.'; end if;
    perform opt__pin(u, p_pin);
    select valor into r from opt_config where clave='general';
    update opt_config set valor = valor || (p_data->'valor'), actualizado=now(), actualizado_por=u.id where clave='general';
    perform opt__log(u.id,'config_guardar',null,jsonb_build_object('antes',r,'cambios',p_data->'valor'));
    return jsonb_build_object('ok',true);

  elsif p_accion = 'contracargo_condonar' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección condona contracargos.'; end if;
    perform opt__pin(u, p_pin);
    update opt_contracargos set estado='condonado', motivo = motivo || ' · Condonado: ' || coalesce(p_data->>'motivo','') where id=(p_data->>'id')::uuid and estado='pendiente';
    perform opt__log(u.id,'contracargo_condonar',p_data->>'id',p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'comisiones_cerrar' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección cierra la quincena.'; end if;
    perform opt__pin(u, p_pin);
    insert into opt_comisiones_cierres(asesora_id,periodo_ini,periodo_fin,generado,contracargos,pagado,detalle,creado_por)
      values ((p_data->>'asesora_id')::uuid, (p_data->>'ini')::date, (p_data->>'fin')::date, (p_data->>'generado')::numeric,
              (p_data->>'contracargos')::numeric, (p_data->>'pagado')::numeric, coalesce(p_data->'detalle','{}'), u.id) returning id into v_id;
    update opt_contracargos set estado='aplicado', cierre_id=v_id where asesora_id=(p_data->>'asesora_id')::uuid and estado='pendiente'
      and id in (select (jsonb_array_elements_text(coalesce(p_data->'contracargo_ids','[]'::jsonb)))::uuid);
    perform opt__log(u.id,'comisiones_cerrar',v_id::text,p_data);
    return jsonb_build_object('id',v_id);

  elsif p_accion = 'referido_usar' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección aplica saldo de referidos.'; end if;
    perform opt__pin(u, p_pin);
    update opt_referidos set usado = usado + (p_data->>'monto')::numeric where codigo=p_data->>'codigo';
    perform opt__log(u.id,'referido_usar',p_data->>'codigo',p_data);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'usuario_guardar' then
    if u.rol <> 'admin' then raise exception 'PERMISO: Solo Dirección administra usuarios.'; end if;
    perform opt__pin(u, p_pin);
    if p_data->>'rol' not in ('ventas','admin','contabilidad') then raise exception 'DATOS: Rol no válido.'; end if;
    if coalesce(p_data->>'id','')='' then
      if length(coalesce(p_data->>'pass',''))<8 then raise exception 'DATOS: La contraseña provisional debe tener al menos 8 caracteres.'; end if;
      insert into opt_usuarios(nombre,usuario,pass_hash,pin_hash,rol,sede,debe_cambiar)
        values (p_data->>'nombre', lower(trim(p_data->>'usuario')), crypt(p_data->>'pass', gen_salt('bf')),
                case when coalesce(p_data->>'pin','')<>'' then crypt(p_data->>'pin', gen_salt('bf')) end, p_data->>'rol', coalesce(p_data->>'sede','Tacámbaro'), true)
        returning id into v_id;
    else
      v_id := (p_data->>'id')::uuid;
      update opt_usuarios set nombre=p_data->>'nombre', rol=p_data->>'rol', sede=coalesce(p_data->>'sede',sede), activo=coalesce((p_data->>'activo')::boolean,activo),
        pass_hash = case when coalesce(p_data->>'pass','')<>'' then crypt(p_data->>'pass', gen_salt('bf')) else pass_hash end,
        debe_cambiar = case when coalesce(p_data->>'pass','')<>'' then true else debe_cambiar end,
        intentos_pin = case when coalesce(p_data->>'pass','')<>'' then 0 else intentos_pin end
        where id=v_id;
      if coalesce((p_data->>'activo')::boolean,true)=false then delete from opt_sesiones where usuario_id=v_id; end if;
    end if;
    perform opt__log(u.id,'usuario_guardar',v_id::text,p_data - 'pass' - 'pin');
    return jsonb_build_object('id',v_id);

  elsif p_accion = 'archivo_permitido' then
    return jsonb_build_object('ok',true,'usuario',u.id);
  end if;

  raise exception 'DATOS: Acción desconocida: %', p_accion;
end $$;

-- Permisos: solo las funciones públicas son invocables por la app
revoke all on function public.opt__sesion(uuid), public.opt__pin(public.opt_usuarios,text), public.opt__log(uuid,text,text,jsonb), public.opt__pagado(uuid) from public, anon, authenticated;
grant execute on function public.opt_login(text,text), public.opt_logout(uuid), public.opt_cambiar_acceso(uuid,text,text,text), public.opt_datos(uuid), public.opt_accion(uuid,text,jsonb,text) to anon, authenticated;
