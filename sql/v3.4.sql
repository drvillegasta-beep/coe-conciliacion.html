-- COE Conciliación · v3.4 · Caja de pagos (Contabilidad) vinculada a COE Finanzas
-- La contadora abre su caja con fondo, recibe efectivo del Director (con su PIN o por confirmar
-- después), registra pagos a proveedores con foto de la nota y cada pago queda como egreso en Finanzas
-- (nuevo o abono a una factura pendiente). No borra datos.

-- 1) Caja de pagos
alter table con_cajas drop constraint if exists con_cajas_modo_check;
alter table con_cajas add constraint con_cajas_modo_check
  check (modo_efectivo in ('por_turno','deposito_directo','pagos'));
update con_cajas set modo_efectivo = 'pagos' where nombre = 'Contabilidad'
  and sucursal_id = (select id from con_sucursales where nombre = 'COE Tacámbaro');
update con_usuarios set rol = 'contabilidad' where usuario = 'contador' and rol = 'cajero';

-- 2) Movimientos de la caja de pagos
create table if not exists con_movimientos_caja (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references con_turnos(id),
  tipo text not null check (tipo in ('ingreso','pago')),
  monto numeric(12,2) not null check (monto > 0),
  concepto text,
  categoria text,
  entidad_id uuid,
  entidad_nombre text,
  factura_id uuid,
  con_factura boolean,
  archivo_url text,
  usuario_id uuid not null references con_usuarios(id),
  entrega_id uuid references con_usuarios(id),
  estado text not null default 'confirmado' check (estado in ('confirmado','por_confirmar','rechazado','anulado')),
  confirmado_por uuid references con_usuarios(id),
  confirmado_en timestamptz,
  nota text,
  folio text unique,
  fin_factura_id uuid,
  fin_abono_id uuid,
  creado timestamptz not null default now()
);
create index if not exists con_mov_turno_idx on con_movimientos_caja(turno_id);
alter table con_movimientos_caja enable row level security;
revoke all on con_movimientos_caja from anon, authenticated;

-- 3) Acceso: la caja de pagos solo la usa Contabilidad (y el administrador)
create or replace function _con_acceso_caja(p_u con_usuarios, p_caja uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_suc uuid; v_modo text;
begin
  select sucursal_id, modo_efectivo into v_suc, v_modo from con_cajas where id = p_caja and activa;
  if v_suc is null then return null; end if;
  if p_u.rol = 'admin' then return 'admin'; end if;
  if v_modo = 'pagos' then
    return case when p_u.rol = 'contabilidad' and _con_ve_sucursal(p_u, v_suc) then 'titular' end;
  end if;
  if p_u.rol = 'contabilidad' then return null; end if;
  if exists (select 1 from con_usuario_sucursal where usuario_id = p_u.id and sucursal_id = v_suc) then
    return 'titular';
  end if;
  if exists (select 1 from con_coberturas
             where caja_id = p_caja and usuario_id = p_u.id and fecha = _con_hoy(v_suc)) then
    return 'cobertura';
  end if;
  return null;
end $$;

create or replace function _con_disponible(p_turno uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(t.fondo_inicial_total, 0)
       + coalesce((select sum(monto) from con_movimientos_caja m where m.turno_id = t.id and m.tipo = 'ingreso'
                   and m.estado in ('confirmado','por_confirmar')), 0)
       - coalesce((select sum(monto) from con_movimientos_caja m where m.turno_id = t.id and m.tipo = 'pago'
                   and m.estado = 'confirmado'), 0)
  from con_turnos t where t.id = p_turno
$$;

create or replace function _con_folio_mov(p_tipo text) returns text
language sql volatile security definer set search_path = public as $$
  select case when p_tipo = 'pago' then 'PAGO-' else 'ING-' end
      || to_char(now() at time zone 'America/Mexico_City', 'YYMMDD-HH24MI') || '-'
      || upper(left(md5(random()::text || clock_timestamp()::text), 4))
$$;

-- Turno de la caja de pagos abierto por quien llama
create or replace function _con_turno_pagos(p_u con_usuarios, p_turno uuid) returns con_turnos
language plpgsql security definer set search_path = public as $$
declare t con_turnos;
begin
  select * into t from con_turnos where id = p_turno for update;
  if not found then raise exception 'Turno no encontrado.'; end if;
  if (select modo_efectivo from con_cajas where id = t.caja_id) <> 'pagos' then
    raise exception 'Esta caja no es de pagos.';
  end if;
  if t.usuario_id <> p_u.id then raise exception 'Solo quien abrió la caja puede registrar movimientos.'; end if;
  if t.estado <> 'abierto' then raise exception 'La caja ya está cerrada.'; end if;
  return t;
end $$;

-- 4) Catálogo de Finanzas para la caja de pagos
create or replace function con_pagos_catalogo(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin', 'contabilidad');
  return jsonb_build_object(
    'proveedores', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'categoria', e.categoria)
                      order by e.nombre) from fin_entidades e where e.tipo = 'proveedor' and coalesce(e.activo, true)), '[]'::jsonb),
    'categorias', coalesce((select jsonb_agg(c order by c) from (select distinct categoria c from fin_facturas
                      where tipo = 'egreso' and coalesce(trim(categoria),'') <> '') q), '[]'::jsonb),
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'proveedor', e.nombre, 'entidad_id', f.entidad_id,
                      'numero', f.numero_factura, 'descripcion', f.descripcion, 'categoria', f.categoria,
                      'total', f.monto_total, 'saldo', f.monto_total - f.monto_pagado, 'vence', f.fecha_vencimiento)
                      order by f.fecha_vencimiento nulls last, e.nombre)
                    from fin_facturas f left join fin_entidades e on e.id = f.entidad_id
                    where f.tipo = 'egreso' and f.estado in ('pendiente','aprobado','en_proceso','parcial')
                      and not f.anulado and f.monto_total - f.monto_pagado > 0.009), '[]'::jsonb),
    'directores', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre) order by x.nombre)
                      from con_usuarios x where x.activo and x.rol = 'admin'), '[]'::jsonb));
end $$;

-- 5) Recibir efectivo (el Director deja dinero)
create or replace function con_recibir_efectivo(p_token uuid, p_turno uuid, p_monto numeric, p_nota text,
                                                p_entrega uuid, p_pin_entrega text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; t con_turnos; d con_usuarios; v_err text; v_estado text; v_id uuid; v_folio text;
begin
  u := _con_sesion(p_token);
  t := _con_turno_pagos(u, p_turno);
  if coalesce(p_monto, 0) <= 0 then raise exception 'Escribe el monto recibido.'; end if;
  select * into d from con_usuarios where id = p_entrega and activo and rol = 'admin';
  if not found then raise exception 'Elige quién entrega el dinero.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  v_estado := 'por_confirmar';
  if coalesce(p_pin_entrega, '') <> '' then
    v_err := _con_pin(d.id, p_pin_entrega);
    if v_err is not null then return jsonb_build_object('ok', false, 'error', 'PIN de ' || d.nombre || ': ' || v_err); end if;
    v_estado := 'confirmado';
  end if;
  v_folio := _con_folio_mov('ingreso');
  insert into con_movimientos_caja(turno_id, tipo, monto, concepto, usuario_id, entrega_id, estado,
                                   confirmado_por, confirmado_en, folio)
  values (t.id, 'ingreso', round(p_monto, 2), nullif(trim(p_nota), ''), u.id, d.id, v_estado,
          case when v_estado = 'confirmado' then d.id end, case when v_estado = 'confirmado' then now() end, v_folio)
  returning id into v_id;
  if v_estado = 'por_confirmar' then
    perform _con_alerta('ingreso_por_confirmar', t.id,
      _con_etiqueta(t.id) || ': ' || u.nombre || ' registró que recibió ' || _con_m(p_monto) || ' de ' || d.nombre
      || '. Falta que ' || d.nombre || ' lo confirme en el panel.');
  end if;
  perform _con_log(u.id, 'recibir_efectivo', jsonb_build_object('turno', t.id, 'mov', v_id, 'monto', p_monto, 'estado', v_estado));
  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio, 'estado', v_estado, 'disponible', _con_disponible(t.id));
end $$;

create or replace function con_ingresos_por_confirmar(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'monto', m.monto, 'nota', m.concepto, 'folio', m.folio,
      'creado', m.creado, 'recibio', ur.nombre, 'entrega', ue.nombre, 'mio', m.entrega_id = u.id, 'turno_id', m.turno_id)
      order by m.creado)
    from con_movimientos_caja m join con_usuarios ur on ur.id = m.usuario_id
    left join con_usuarios ue on ue.id = m.entrega_id
    where m.tipo = 'ingreso' and m.estado = 'por_confirmar'), '[]'::jsonb);
end $$;

create or replace function con_confirmar_ingreso(p_token uuid, p_mov uuid, p_aceptar boolean, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; m con_movimientos_caja; v_err text;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  select * into m from con_movimientos_caja where id = p_mov for update;
  if not found or m.tipo <> 'ingreso' then raise exception 'Movimiento no encontrado.'; end if;
  if m.estado <> 'por_confirmar' then raise exception 'Ese ingreso ya se revisó.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  update con_movimientos_caja set estado = case when p_aceptar then 'confirmado' else 'rechazado' end,
         confirmado_por = u.id, confirmado_en = now() where id = m.id;
  if not p_aceptar then
    perform _con_alerta('ingreso_rechazado', m.turno_id,
      _con_etiqueta(m.turno_id) || ': ' || u.nombre || ' NO reconoce el ingreso de ' || _con_m(m.monto)
      || ' registrado a las ' || to_char(m.creado at time zone 'America/Mexico_City', 'HH24:MI') || '.');
  end if;
  perform _con_log(u.id, 'confirmar_ingreso', jsonb_build_object('mov', m.id, 'aceptar', p_aceptar));
  return jsonb_build_object('ok', true);
end $$;

-- 6) Registrar un pago (queda como egreso en Finanzas)
create or replace function con_registrar_pago(p_token uuid, p_turno uuid, p_d jsonb, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u con_usuarios; t con_turnos; f fin_facturas; v_err text; v_monto numeric; v_url text; v_ent uuid; v_entnom text;
  v_conc text; v_cat text; v_confac boolean; v_fu uuid; v_fact uuid; v_abono uuid; v_id uuid := gen_random_uuid();
  v_folio text; v_hoy date; v_disp numeric; v_saldo numeric; v_doc text := 'si';
begin
  u := _con_sesion(p_token);
  t := _con_turno_pagos(u, p_turno);
  v_monto := round(coalesce((p_d->>'monto')::numeric, 0), 2);
  if v_monto <= 0 then raise exception 'Escribe el monto pagado.'; end if;
  v_url := nullif(trim(coalesce(p_d->>'archivo_url', '')), '');
  if v_url is null or v_url !~ '^https://ckjkdenwqicdjvodflba\.supabase\.co/storage/v1/object/public/comprobantes/' then
    raise exception 'Falta la foto de la nota o factura.';
  end if;
  v_disp := _con_disponible(t.id);
  if v_monto > v_disp + 0.009 then
    raise exception 'No alcanza el efectivo: hay % disponibles en la caja.', _con_m(v_disp);
  end if;
  v_hoy := t.fecha;
  v_folio := _con_folio_mov('pago');
  select id into v_fu from fin_usuarios where rol = 'contadora' limit 1;
  perform set_config('app.usuario_id', coalesce(v_fu::text, ''), true);
  perform set_config('app.usuario_nombre', 'Caja COE · ' || u.nombre, true);

  if nullif(p_d->>'factura_id', '') is not null then
    select * into f from fin_facturas where id = (p_d->>'factura_id')::uuid for update;
    if not found or f.tipo <> 'egreso' or f.anulado then raise exception 'Factura no encontrada.'; end if;
    v_saldo := f.monto_total - f.monto_pagado;
    if v_saldo <= 0.009 then raise exception 'Esa factura ya está pagada.'; end if;
    if v_monto > v_saldo + 0.009 then raise exception 'El monto es mayor al saldo de la factura (%).', _con_m(v_saldo); end if;
    v_fact := f.id; v_ent := f.entidad_id; v_confac := true;
    select nombre into v_entnom from fin_entidades where id = v_ent;
    v_conc := coalesce(nullif(trim(p_d->>'concepto'), ''), f.descripcion);
    v_cat := f.categoria;
  else
    v_conc := nullif(trim(coalesce(p_d->>'concepto', '')), '');
    if v_conc is null then raise exception 'Escribe el concepto del pago.'; end if;
    v_cat := nullif(trim(coalesce(p_d->>'categoria', '')), '');
    v_doc := coalesce(nullif(p_d->>'factura', ''), case when coalesce((p_d->>'con_factura')::boolean, false) then 'si' else 'no' end);
    if v_doc not in ('si','despues','no') then raise exception 'Indica si el pago trae factura.'; end if;
    v_confac := v_doc = 'si';
    if nullif(p_d->>'entidad_id', '') is not null then
      select id, nombre into v_ent, v_entnom from fin_entidades where id = (p_d->>'entidad_id')::uuid;
      if v_ent is null then raise exception 'Proveedor no encontrado.'; end if;
    else
      v_entnom := nullif(trim(coalesce(p_d->>'entidad_nombre', '')), '');
      if v_entnom is null then raise exception 'Elige o escribe el proveedor.'; end if;
      select id, nombre into v_ent, v_entnom from fin_entidades
       where tipo = 'proveedor' and lower(trim(nombre)) = lower(v_entnom) limit 1;
      if v_ent is null then
        v_entnom := upper(nullif(trim(coalesce(p_d->>'entidad_nombre', '')), ''));
        insert into fin_entidades(nombre, tipo, categoria, notas)
        values (v_entnom, 'proveedor', v_cat, 'Alta desde Caja COE (pago en efectivo).')
        returning id into v_ent;
      end if;
    end if;
  end if;

  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;

  perform set_config('app.usuario_id', coalesce(v_fu::text, ''), true);
  perform set_config('app.usuario_nombre', 'Caja COE · ' || u.nombre, true);

  if v_fact is null then
    insert into fin_facturas(tipo, entidad_id, descripcion, categoria, monto_total, monto_pagado, fecha_pago, estado,
                             notas, created_by, tipo_movimiento, comprobante_pago_url, sede, origen, origen_id,
                             documento_tipo, factura_pendiente, metodo_pago)
    values ('egreso', v_ent, v_conc, v_cat, v_monto, v_monto, v_hoy, 'pagado',
            'Pagado en efectivo desde la caja de Contabilidad · ' || v_folio, v_fu, 'normal', v_url,
            case when (select s.nombre from con_cajas c join con_sucursales s on s.id = c.sucursal_id where c.id = t.caja_id) ilike '%morelia%'
                 then 'Morelia' else 'Tacámbaro' end,
            'conciliacion', v_id::text, case v_doc when 'si' then 'factura' when 'no' then 'sin_factura' end,
            v_doc = 'despues', 'efectivo')
    returning id into v_fact;
    insert into fin_abonos(factura_id, monto, fecha_pago, referencia, comprobante_url, notas, metodo, created_by, firma1_por, firma1_at)
    values (v_fact, v_monto, v_hoy, v_folio, v_url, 'Caja COE · ' || u.nombre, 'efectivo', v_fu, v_fu, now())
    returning id into v_abono;
  else
    insert into fin_abonos(factura_id, monto, fecha_pago, referencia, comprobante_url, notas, metodo, created_by, firma1_por, firma1_at)
    values (v_fact, v_monto, v_hoy, v_folio, v_url, 'Caja COE · ' || u.nombre, 'efectivo', v_fu, v_fu, now())
    returning id into v_abono;
    update fin_facturas set monto_pagado = monto_pagado + v_monto,
           estado = case when monto_total - (monto_pagado + v_monto) <= 0.009 then 'pagado' else 'parcial' end,
           fecha_pago = case when monto_total - (monto_pagado + v_monto) <= 0.009 then v_hoy else fecha_pago end,
           comprobante_pago_url = coalesce(comprobante_pago_url, v_url), updated_by = v_fu, updated_at = now()
     where id = v_fact;
  end if;

  insert into con_movimientos_caja(id, turno_id, tipo, monto, concepto, categoria, entidad_id, entidad_nombre, factura_id,
                                   con_factura, archivo_url, usuario_id, estado, folio, fin_factura_id, fin_abono_id, nota)
  values (v_id, t.id, 'pago', v_monto, v_conc, v_cat, v_ent, v_entnom,
          case when nullif(p_d->>'factura_id', '') is not null then v_fact end,
          v_confac, v_url, u.id, 'confirmado', v_folio, v_fact, v_abono,
          case v_doc when 'despues' then 'Factura pendiente de entregar' when 'no' then 'Sin factura' end);
  perform _con_log(u.id, 'registrar_pago', jsonb_build_object('turno', t.id, 'mov', v_id, 'monto', v_monto, 'factura', v_fact));
  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio, 'disponible', _con_disponible(t.id));
end $$;

-- Anular un pago registrado por error (solo administrador, con la caja abierta)
create or replace function con_anular_pago(p_token uuid, p_mov uuid, p_motivo text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; m con_movimientos_caja; v_err text; v_fu uuid;
begin
  u := _con_sesion(p_token);
  perform _con_rol(u, 'admin');
  select * into m from con_movimientos_caja where id = p_mov for update;
  if not found or m.tipo <> 'pago' then raise exception 'Pago no encontrado.'; end if;
  if m.estado <> 'confirmado' then raise exception 'Ese pago ya está anulado.'; end if;
  if (select estado from con_turnos where id = m.turno_id) <> 'abierto' then
    raise exception 'La caja ya se cerró; corrígelo en Finanzas.';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escribe el motivo.'; end if;
  v_err := _con_pin(u.id, p_pin);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  select id into v_fu from fin_usuarios where rol = 'contadora' limit 1;
  perform set_config('app.usuario_id', coalesce(v_fu::text, ''), true);
  perform set_config('app.usuario_nombre', 'Caja COE · ' || u.nombre, true);
  update fin_abonos set anulado = true, anulado_motivo = 'Caja COE: ' || trim(p_motivo), anulado_at = now()
   where id = m.fin_abono_id;
  if m.factura_id is null then
    update fin_facturas set anulado = true, anulado_motivo = 'Caja COE: ' || trim(p_motivo), anulado_at = now(),
           monto_pagado = 0, estado = 'cancelado' where id = m.fin_factura_id;
  else
    update fin_facturas set monto_pagado = greatest(monto_pagado - m.monto, 0),
           estado = case when monto_pagado - m.monto <= 0.009 then 'pendiente' else 'parcial' end,
           fecha_pago = null, updated_at = now() where id = m.factura_id;
  end if;
  update con_movimientos_caja set estado = 'anulado', nota = trim(p_motivo), confirmado_por = u.id, confirmado_en = now()
   where id = m.id;
  perform _con_alerta('pago_anulado', m.turno_id,
    _con_etiqueta(m.turno_id) || ': ' || u.nombre || ' anuló el pago ' || m.folio || ' de ' || _con_m(m.monto)
    || '. Motivo: ' || trim(p_motivo));
  perform _con_log(u.id, 'anular_pago', jsonb_build_object('mov', m.id, 'motivo', p_motivo));
  return jsonb_build_object('ok', true);
end $$;

-- Detalle de un movimiento (para el comprobante y el QR)
create or replace function con_pago(p_token uuid, p_mov uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u con_usuarios; m con_movimientos_caja; r jsonb;
begin
  u := _con_sesion(p_token);
  select * into m from con_movimientos_caja where id = p_mov;
  if not found then raise exception 'Movimiento no encontrado.'; end if;
  if m.usuario_id <> u.id and u.rol not in ('admin','supervisor','contabilidad') then
    raise exception 'No tienes acceso a este movimiento.';
  end if;
  select to_jsonb(m) || jsonb_build_object(
      'usuario', (select nombre from con_usuarios where id = m.usuario_id),
      'entrega', (select nombre from con_usuarios where id = m.entrega_id),
      'confirmado_por_nombre', (select nombre from con_usuarios where id = m.confirmado_por),
      'factura_numero', (select numero_factura from fin_facturas where id = m.factura_id),
      'factura_saldo', (select monto_total - monto_pagado from fin_facturas where id = m.factura_id),
      'caja', c.nombre, 'sucursal', s.nombre, 'fecha', t.fecha)
    into r
  from con_turnos t join con_cajas c on c.id = t.caja_id join con_sucursales s on s.id = c.sucursal_id
  where t.id = m.turno_id;
  return r;
end $$;

-- 7) con_turno devuelve disponible y movimientos
do $$
declare v text; o text := $o$'gastos', coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'monto',g.monto,$o$;
begin
  v := pg_get_functiondef('con_turno(uuid,uuid)'::regprocedure);
  if position('''movimientos''' in v) = 0 then
    if position(o in v) = 0 then raise exception 'con_turno: patrón no encontrado'; end if;
    v := replace(v, o, $n$'disponible', _con_disponible(t.id),
      'movimientos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tipo', m.tipo, 'monto', m.monto,
                  'concepto', m.concepto, 'categoria', m.categoria, 'proveedor', m.entidad_nombre, 'factura_id', m.factura_id,
                  'con_factura', m.con_factura, 'archivo_url', m.archivo_url, 'estado', m.estado, 'folio', m.folio,
                  'entrega', (select nombre from con_usuarios where id = m.entrega_id), 'nota', m.nota, 'creado', m.creado)
                  order by m.creado) from con_movimientos_caja m where m.turno_id = t.id), '[]'::jsonb),
      $n$ || o);
    execute v;
  end if;
end $$;

-- 8) Cierre de la caja de pagos: esperado = fondo + ingresos − pagos
do $$
declare v text; o text := $o$  select lectura into eo from con_evidencias$o$;
begin
  v := pg_get_functiondef('con_cerrar_turno(uuid,uuid,jsonb,text,text)'::regprocedure);
  if position('modo_pagos' in v) = 0 then
    if position(o in v) = 0 then raise exception 'con_cerrar_turno: patrón no encontrado'; end if;
    v := replace(v, o, $n$  -- modo_pagos: caja de Contabilidad
  if (select modo_efectivo from con_cajas where id = t.caja_id) = 'pagos' then
    if exists (select 1 from con_movimientos_caja where turno_id = t.id and estado = 'por_confirmar') then
      null; -- se cierra igual; el Director confirma después
    end if;
    v_err := _con_pin(u.id, p_pin);
    if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
    select s.tolerancia into v_tol from con_cajas c join con_sucursales s on s.id = c.sucursal_id where c.id = t.caja_id;
    pe := coalesce((select sum(monto) from con_movimientos_caja where turno_id = t.id and tipo = 'ingreso' and estado in ('confirmado','por_confirmar')), 0);
    v_g := coalesce((select sum(monto) from con_movimientos_caja where turno_id = t.id and tipo = 'pago' and estado = 'confirmado'), 0);
    v_ff := _con_total(p_fondo_final);
    de := (v_ff + v_g) - (t.fondo_inicial_total + pe);
    dtot := de;
    v_estado := case when dtot < -v_tol then 'faltante' when dtot > v_tol then 'sobrante' else 'cuadrado' end;
    if v_estado <> 'cuadrado' and coalesce(trim(p_justificacion),'') = '' then
      return jsonb_build_object('ok', false, 'code', 'JUSTIFICAR', 'estado', v_estado,
        'dif_total', dtot, 'dif_efectivo', de, 'dif_tarjeta', 0, 'dif_transferencia', 0);
    end if;
    update con_turnos set cerrado_en = now(), fondo_final = p_fondo_final, fondo_final_total = v_ff,
      pos_efectivo = pe, pos_tarjeta = 0, pos_transferencia = 0, real_depositado = 0, real_voucher = 0, real_banco = 0,
      gastos_total = v_g, dif_efectivo = de, dif_tarjeta = 0, dif_transferencia = 0, dif_total = dtot,
      estado = v_estado, justificacion = nullif(trim(p_justificacion),'')
    where id = t.id;
    if v_estado <> 'cuadrado' then
      perform _con_alerta('diferencia', t.id, _con_etiqueta(t.id) || ': ' ||
        case v_estado when 'faltante' then 'FALTANTE de ' || _con_m(abs(dtot)) else 'sobrante de ' || _con_m(dtot) end
        || '. Justificación: ' || trim(p_justificacion));
    end if;
    perform _con_log(u.id, 'cerrar_turno', jsonb_build_object('turno', t.id, 'estado', v_estado, 'dif_total', dtot));
    return jsonb_build_object('ok', true, 'estado', v_estado, 'dif_total', dtot, 'dif_efectivo', de, 'dif_tarjeta', 0,
      'dif_transferencia', 0, 'fondo_final', v_ff, 'pos_efectivo', pe, 'pos_tarjeta', 0, 'pos_transferencia', 0,
      'real_depositado', 0, 'real_voucher', 0, 'real_banco', 0, 'gastos', v_g, 'pagos', true);
  end if;

$n$ || o);
    execute v;
  end if;
end $$;

-- 9) Cierre del día: la caja de pagos no participa
do $$
declare v text;
begin
  v := pg_get_functiondef('con_dia(uuid,uuid)'::regprocedure);
  if position('<> ''pagos''' in v) = 0 then
    if position('where c.sucursal_id = p_sucursal and t.fecha = v_hoy), ''[]''::jsonb)' in v) = 0 then raise exception 'con_dia: patrón'; end if;
    v := replace(v, 'where c.sucursal_id = p_sucursal and t.fecha = v_hoy), ''[]''::jsonb)',
                    'where c.sucursal_id = p_sucursal and t.fecha = v_hoy and c.modo_efectivo <> ''pagos''), ''[]''::jsonb)');
    execute v;
  end if;
  v := pg_get_functiondef('con_dia_cerrar(uuid,uuid,text,text)'::regprocedure);
  if position('<> ''pagos''' in v) = 0 then
    if position('where c.sucursal_id = p_sucursal and t.estado = ''abierto'';' in v) = 0 then raise exception 'con_dia_cerrar: patrón'; end if;
    v := replace(v, 'where c.sucursal_id = p_sucursal and t.estado = ''abierto'';',
                    'where c.sucursal_id = p_sucursal and t.estado = ''abierto'' and c.modo_efectivo <> ''pagos'';');
    execute v;
  end if;
end $$;

-- 10) Candado: la caja de pagos es de todo el día (aviso al final del vespertino, sin cierre automático)
do $$
declare v text; a text; b text; c text;
begin
  v := pg_get_functiondef('con_revisar_candado()'::regprocedure);
  if position('modo_efectivo' in v) = 0 then
    a := 'where cc.sucursal_id = r.sucursal_id and tt.estado = ''abierto'' and tt.turno = r.turno';
    b := 'and (tt.turno = r.turno or (r.turno = ''vespertino'' and tt.turno = ''comida''))';
    c := 'and not exists (select 1 from con_turnos tt where tt.caja_id = cc.id and tt.fecha = v_hoy and tt.turno = r.turno)';
    if position(a in v) = 0 or position(b in v) = 0 or position(c in v) = 0 then raise exception 'candado: patrón'; end if;
    v := replace(v, a, 'where cc.sucursal_id = r.sucursal_id and tt.estado = ''abierto''
        and (case when cc.modo_efectivo = ''pagos'' then r.turno = ''vespertino'' else tt.turno = r.turno end)');
    v := replace(v, b, b || ' and cc.modo_efectivo <> ''pagos''');
    v := replace(v, c, 'and (case when cc.modo_efectivo = ''pagos''
               then r.turno = ''matutino'' and not exists (select 1 from con_turnos tt where tt.caja_id = cc.id and tt.fecha = v_hoy)
               else not exists (select 1 from con_turnos tt where tt.caja_id = cc.id and tt.fecha = v_hoy and tt.turno = r.turno) end)');
    execute v;
  end if;
end $$;

-- 11) Permisos
do $$
declare f text;
begin
  foreach f in array array['_con_disponible(uuid)','_con_folio_mov(text)','_con_turno_pagos(con_usuarios,uuid)',
                           '_con_acceso_caja(con_usuarios,uuid)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['con_pagos_catalogo(uuid)','con_recibir_efectivo(uuid,uuid,numeric,text,uuid,text,text)',
                           'con_ingresos_por_confirmar(uuid)','con_confirmar_ingreso(uuid,uuid,boolean,text)',
                           'con_registrar_pago(uuid,uuid,jsonb,text)','con_anular_pago(uuid,uuid,text,text)',
                           'con_pago(uuid,uuid)'] loop
    execute format('revoke execute on function %s from public, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;

-- 12) Panel: el resumen indica el modo de cada caja y no cuenta como "cobrado" el efectivo de la caja de pagos
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('con_admin_resumen(uuid,date,date)'::regprocedure);
  if position('''modo''' in v) = 0 then
    a := $a$'cobrado', coalesce(t.pos_efectivo,0) + coalesce(t.pos_tarjeta,0) + coalesce(t.pos_transferencia,0),$a$;
    b := $b$'id', c.id, 'nombre', c.nombre, 'sucursal', s.nombre, 'sucursal_id', s.id,$b$;
    if position(a in v) = 0 or position(b in v) = 0 then raise exception 'con_admin_resumen: patrón'; end if;
    v := replace(v, a, $n$'modo', c.modo_efectivo,
        'pagado', case when c.modo_efectivo = 'pagos' then coalesce(t.gastos_total,0) end,
        'cobrado', case when c.modo_efectivo = 'pagos' then 0
                   else coalesce(t.pos_efectivo,0) + coalesce(t.pos_tarjeta,0) + coalesce(t.pos_transferencia,0) end,$n$);
    v := replace(v, b, b || ' ''modo'', c.modo_efectivo,');
    execute v;
  end if;
end $$;
