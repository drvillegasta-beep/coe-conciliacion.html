-- COE Óptica · esquema base (prefijo opt_). Acceso solo por funciones RPC con token de sesión.
create table if not exists public.opt_usuarios(
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  usuario text not null unique,
  pass_hash text not null,
  pin_hash text,
  rol text not null check (rol in ('ventas','admin','contabilidad')),
  sede text not null default 'Tacámbaro',
  activo boolean not null default true,
  debe_cambiar boolean not null default true,
  intentos_login int not null default 0,
  bloqueo_hasta timestamptz,
  intentos_pin int not null default 0,
  creado timestamptz not null default now()
);
create table if not exists public.opt_sesiones(
  token uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.opt_usuarios(id) on delete cascade,
  creado timestamptz not null default now(),
  ultimo timestamptz not null default now()
);
create table if not exists public.opt_config(
  clave text primary key,
  valor jsonb not null,
  actualizado timestamptz not null default now(),
  actualizado_por uuid references public.opt_usuarios(id)
);
create table if not exists public.opt_pacientes(
  id uuid primary key default gen_random_uuid(),
  expediente text unique,
  nombre text not null,
  nacimiento date,
  telefono text,
  sede text,
  creado timestamptz not null default now(),
  creado_por uuid references public.opt_usuarios(id)
);
create sequence if not exists public.opt_expediente_seq start 1001;
create table if not exists public.opt_examenes(
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.opt_pacientes(id) on delete cascade,
  fecha date not null default (now() at time zone 'America/Mexico_City')::date,
  optometrista text,
  av jsonb not null default '{}'::jsonb,
  rx jsonb not null default '{}'::jsonb,
  dx text[] not null default '{}',
  notas text,
  archivo text,
  creado timestamptz not null default now(),
  creado_por uuid references public.opt_usuarios(id)
);
create table if not exists public.opt_trabajos(
  id uuid primary key default gen_random_uuid(),
  venta text not null unique,
  id_trabajo text,
  paciente_id uuid references public.opt_pacientes(id),
  paciente_nombre text not null,
  telefono text,
  sede text not null default 'Tacámbaro',
  asesora_id uuid references public.opt_usuarios(id),
  fecha_venta date not null default (now() at time zone 'America/Mexico_City')::date,
  laboratorio text,
  tipo text,
  material text,
  tratamiento text,
  rx jsonb not null default '{}'::jsonb,
  armazon jsonb not null default '{}'::jsonb,
  precio jsonb not null default '{}'::jsonb,
  costo jsonb not null default '{}'::jsonb,
  total numeric(12,2) not null default 0,
  estado text not null default 'capturado' check (estado in ('capturado','enviado','recibido','listo','avisado','entregado','garantia','cancelado')),
  eventos jsonb not null default '{}'::jsonb,
  llega date,
  checklist jsonb not null default '{}'::jsonb,
  respaldo boolean not null default false,
  referido text,
  garantia_firmada boolean not null default false,
  garantia_motivo text,
  ticket_archivo text,
  ticket_leido jsonb,
  creado timestamptz not null default now()
);
create table if not exists public.opt_pagos(
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null references public.opt_trabajos(id) on delete cascade,
  monto numeric(12,2) not null check (monto>0),
  forma text not null default 'Efectivo',
  fecha timestamptz not null default now(),
  archivo text not null,
  origen text not null default 'capturado' check (origen in ('leido','capturado')),
  verificado boolean not null default false,
  verificado_por uuid references public.opt_usuarios(id),
  creado_por uuid references public.opt_usuarios(id)
);
create table if not exists public.opt_posventa(
  clave text primary key,
  motivo text,
  paciente text,
  resultado text not null,
  fecha timestamptz not null default now(),
  usuario_id uuid references public.opt_usuarios(id)
);
create table if not exists public.opt_comisiones_cierres(
  id uuid primary key default gen_random_uuid(),
  asesora_id uuid references public.opt_usuarios(id),
  periodo_ini date not null,
  periodo_fin date not null,
  generado numeric(12,2) not null,
  contracargos numeric(12,2) not null default 0,
  pagado numeric(12,2) not null,
  detalle jsonb not null default '{}'::jsonb,
  creado timestamptz not null default now(),
  creado_por uuid references public.opt_usuarios(id)
);
create table if not exists public.opt_contracargos(
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid references public.opt_trabajos(id),
  asesora_id uuid references public.opt_usuarios(id),
  monto numeric(12,2) not null,
  motivo text,
  estado text not null default 'pendiente' check (estado in ('pendiente','aplicado','condonado')),
  cierre_id uuid references public.opt_comisiones_cierres(id),
  creado timestamptz not null default now()
);
create table if not exists public.opt_referidos(
  codigo text primary key,
  paciente_nombre text not null,
  telefono text,
  usado numeric(12,2) not null default 0,
  creado timestamptz not null default now()
);
create sequence if not exists public.opt_referido_seq start 4001;
create table if not exists public.opt_log(
  id bigserial primary key,
  fecha timestamptz not null default now(),
  usuario_id uuid,
  accion text not null,
  entidad_id text,
  datos jsonb
);
create index if not exists opt_trabajos_estado_idx on public.opt_trabajos(estado);
create index if not exists opt_pagos_trabajo_idx on public.opt_pagos(trabajo_id);
create index if not exists opt_examenes_paciente_idx on public.opt_examenes(paciente_id);
create index if not exists opt_sesiones_usuario_idx on public.opt_sesiones(usuario_id);

do $$ declare t text; begin
  foreach t in array array['opt_usuarios','opt_sesiones','opt_config','opt_pacientes','opt_examenes','opt_trabajos','opt_pagos','opt_posventa','opt_comisiones_cierres','opt_contracargos','opt_referidos','opt_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

insert into public.opt_config(clave, valor) values ('general', '{
  "anticipo":50,
  "factor":{"armazon":2.5,"mica":3},
  "com":{"armazon":5,"mica":5,"lc":3,"accesorio":3},
  "comMomento":"liquidado y entregado",
  "promos":[],
  "labs":[{"nombre":"Sra. Angy","formato":"Pedido diario consolidado","recoleccion_dia":4,"dias":0},{"nombre":"Health Vision","formato":"Orden individual (formato HV) · vía sede Morelia","recoleccion_dia":null,"dias":7}],
  "mantenimiento":6,"revision":12,"renovacion":24,
  "waOptica":"4591035121",
  "ref":{"activo":true,"nuevoTipo":"monto","nuevoValor":200,"refiereMonto":200,"minCompra":1500,"vigencia":6,"tope":5,"comExtra":0}
}'::jsonb) on conflict (clave) do nothing;

insert into storage.buckets(id, name, public, file_size_limit)
values ('optica','optica', false, 15728640) on conflict (id) do nothing;
