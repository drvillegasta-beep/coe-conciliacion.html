-- COE Conciliación · v3.9.1 · Avisos al iPhone separados en prioritarios y de operación diaria
-- Prioritarios: turnos sin cerrar o sin registro, cortes que no cuadraron, fondos que no coinciden y cierres del día atrasados.
-- No borra datos.

create or replace function _con_alerta_prioritaria(p_tipo text) returns boolean
language sql immutable as $$
  select p_tipo in ('diferencia','aclaracion','fondo_apertura','turno_sin_cerrar','turno_sin_registro',
                    'cierre_automatico','cierre_pendiente','cierre_dia_tardio','ingreso_rechazado')
$$;

create or replace function _con_push(p_alerta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a con_alertas; v_tipos text; v_tit text; v_lista jsonb; v_pri boolean;
begin
  select * into a from con_alertas where id = p_alerta;
  if not found then return; end if;
  select valor into v_tipos from con_config where clave = 'push_tipos';
  v_tipos := coalesce(nullif(trim(v_tipos),''),
    'diferencia,aclaracion,turno_sin_cerrar,cierre_automatico,cierre_pendiente,fecha_distinta,captura_manual,captura_rechazada,cierre_dia_tardio');
  if not (a.tipo = any(string_to_array(replace(v_tipos,' ',''), ','))) then return; end if;
  v_pri := _con_alerta_prioritaria(a.tipo);
  v_tit := case when v_pri then '🔴 PRIORITARIA · ' else 'Caja COE · ' end || case a.tipo
    when 'diferencia' then 'Turno no cuadrado' when 'aclaracion' then 'Turno no cuadrado'
    when 'fondo_apertura' then 'Fondo no coincide'
    when 'turno_sin_cerrar' then 'Turno sin cerrar' when 'turno_sin_registro' then 'Turno sin registro'
    when 'cierre_automatico' then 'Turno cerrado sin corte'
    when 'cierre_pendiente' then 'Turno cerrado por supervisión' when 'fecha_distinta' then 'Comprobante a destiempo'
    when 'captura_manual' then 'Captura a mano por firmar' when 'captura_rechazada' then 'Comprobante no aprobado'
    when 'cierre_dia_tardio' then 'Cierre del día tardío' when 'ingreso_rechazado' then 'Ingreso no reconocido'
    else replace(a.tipo,'_',' ') end;
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'title', v_tit, 'body', left(a.mensaje, 400),
           'tag', 'coe-caja-' || a.id, 'url', 'https://drvillegasta-beep.github.io/coe-conciliacion.html/coe-conciliacion.html'))
    into v_lista from fin_usuarios u where u.rol = 'admin' and u.activo;
  if v_lista is null then return; end if;
  perform fin__avisos_disparar(jsonb_build_object('momento', 'caja', 'directo', v_lista));
exception when others then null;
end $$;

-- Lista de avisos: se agregan fondo no coincide e ingreso no reconocido (prioritarios)
update con_config set valor = 'diferencia,aclaracion,fondo_apertura,turno_sin_cerrar,cierre_automatico,cierre_pendiente,cierre_dia_tardio,ingreso_rechazado,fecha_distinta,captura_manual,captura_rechazada'
 where clave = 'push_tipos' and valor = 'diferencia,aclaracion,turno_sin_cerrar,cierre_automatico,cierre_pendiente,fecha_distinta,captura_manual,captura_rechazada,cierre_dia_tardio';

revoke execute on function _con_push(uuid) from public, anon, authenticated;
revoke execute on function _con_alerta_prioritaria(text) from public, anon, authenticated;
