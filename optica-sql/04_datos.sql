create or replace function public.opt_datos(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u public.opt_usuarios; v_out jsonb;
begin
  u := opt__sesion(p_token);
  select jsonb_build_object(
    'yo', jsonb_build_object('id',u.id,'nombre',u.nombre,'rol',u.rol,'sede',u.sede,'debe_cambiar',u.debe_cambiar),
    'hoy', (now() at time zone 'America/Mexico_City')::date,
    'config', (select valor from opt_config where clave='general'),
    'trabajos', coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object(
        'pagos', coalesce((select jsonb_agg(to_jsonb(p) order by p.fecha) from opt_pagos p where p.trabajo_id=t.id),'[]'::jsonb),
        'asesora', (select a.nombre from opt_usuarios a where a.id=t.asesora_id)) order by t.creado desc)
      from opt_trabajos t where t.estado<>'cancelado' and (t.estado<>'entregado' or t.fecha_venta > (now()-interval '400 days')::date)),'[]'::jsonb),
    'pacientes', coalesce((select jsonb_agg(to_jsonb(pa) || jsonb_build_object(
        'examenes', coalesce((select jsonb_agg(to_jsonb(e) order by e.fecha desc, e.creado desc) from opt_examenes e where e.paciente_id=pa.id),'[]'::jsonb)) order by pa.nombre)
      from opt_pacientes pa),'[]'::jsonb),
    'posventa', coalesce((select jsonb_object_agg(pv.clave, jsonb_build_object('resultado',pv.resultado,'fecha',pv.fecha)) from opt_posventa pv),'{}'::jsonb),
    'contracargos', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('paciente',(select x.paciente_nombre from opt_trabajos x where x.id=c.trabajo_id),'venta',(select x.venta from opt_trabajos x where x.id=c.trabajo_id)) order by c.creado desc) from opt_contracargos c where u.rol<>'ventas' or c.asesora_id=u.id),'[]'::jsonb),
    'cierres', coalesce((select jsonb_agg(to_jsonb(c) order by c.periodo_fin desc) from opt_comisiones_cierres c where u.rol<>'ventas' or c.asesora_id=u.id),'[]'::jsonb),
    'referidos', coalesce((select jsonb_agg(to_jsonb(rf) order by rf.creado desc) from opt_referidos rf),'[]'::jsonb),
    'usuarios', case when u.rol='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',us.id,'nombre',us.nombre,'usuario',us.usuario,'rol',us.rol,'sede',us.sede,'activo',us.activo,'tiene_pin',us.pin_hash is not null) order by us.nombre) from opt_usuarios us),'[]'::jsonb)
                else coalesce((select jsonb_agg(jsonb_build_object('id',us.id,'nombre',us.nombre,'rol',us.rol)) from opt_usuarios us where us.rol='ventas'),'[]'::jsonb) end
  ) into v_out;
  return v_out;
end $$;
revoke all on function public.opt_datos(uuid) from public;
grant execute on function public.opt_datos(uuid) to anon, authenticated;
