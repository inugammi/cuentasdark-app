// Copia de supabase/cuentas_v1.sql + cuentas_v2.sql + cuentas_v3.sql (si cambias uno, cambia el otro).
const cuentasSql = r'''
-- =====================================================================
-- Cuentas Dark (app Android) · supabase/cuentas_v1.sql
-- Pégalo COMPLETO en supabase.com > tu proyecto de TPVDark > SQL Editor > New query > RUN.
-- Es IDEMPOTENTE (se puede correr varias veces). Solo CREA cosas nuevas; no toca las tablas de TPVDark.
--   * v_ventas_dia / v_articulos_dia: ventas y artículos por día (sin anuladas), para que la app
--     baje poco en vez de todas las facturas.
--   * cuentas_*: respaldo de lo que capturas en la app (días, recargas, nombres, abonos).
-- =====================================================================

create or replace view public.v_ventas_dia with (security_invoker = true) as
select (v.fecha::date)::text as dia, sum(v.total) as ventas, count(*) as tickets
from public.ventas v
where v.estado <> 9
group by 1;

create or replace view public.v_articulos_dia with (security_invoker = true) as
select (v.fecha::date)::text as dia, coalesce(nullif(l.articulo, ''), l.descripcion) as articulo,
       max(l.descripcion) as descripcion, sum(l.cantidad) as cantidad, sum(l.total) as total
from public.ventas_lineas l
join public.ventas v on v.uuid = l.venta_uuid
where v.estado <> 9
group by 1, 2;

grant select on public.v_ventas_dia, public.v_articulos_dia to authenticated;

create table if not exists public.cuentas_dias (
    fecha text primary key,
    b20 double precision, b50 double precision, b100 double precision, b200 double precision,
    b500 double precision, b1000 double precision, billetes double precision, sencillo double precision,
    caja double precision, ingresos double precision, ingresos_txt text, gastos double precision, gastos_txt text,
    pagos double precision, pagos_txt text, gasto_banca double precision, gasto_banca_txt text,
    cambio double precision, sen_a_bil double precision, bil_a_sen double precision,
    otros_ingresos double precision, otros_ingresos_txt text, total_pdv double precision,
    recargas double precision, saldo double precision, notas text,
    venta double precision, banca double precision, sencillo_total double precision,
    calc integer default 1, updated_at bigint, deleted integer default 0
);

create table if not exists public.cuentas_recargas (
    clave text primary key, fecha text, compania text, telefono text, monto double precision,
    folio text, producto text, proveedor text, origen text, updated_at bigint, deleted integer default 0
);

create table if not exists public.cuentas_nombres (
    telefono text primary key, nombre text, notas text, updated_at bigint, deleted integer default 0
);

create table if not exists public.cuentas_abonos (
    id text primary key, fecha text, monto double precision, proveedor text, notas text,
    updated_at bigint, deleted integer default 0
);

do $$
declare t text;
begin
    foreach t in array array['cuentas_dias','cuentas_recargas','cuentas_nombres','cuentas_abonos'] loop
        execute format('alter table public.%I enable row level security;', t);
        execute format('drop policy if exists tpv_autenticado on public.%I;', t);
        execute format('create policy tpv_autenticado on public.%I for all to authenticated using (true) with check (true);', t);
        execute format('create index if not exists ix_%s_upd on public.%I (updated_at);', t, t);
    end loop;
end $$;

create index if not exists ix_cuentas_recargas_fecha on public.cuentas_recargas (fecha);

-- =====================================================================
-- Cuentas Dark · supabase/cuentas_v2.sql  (app 1.2)
-- Opción "Dejé la banca en caja" de cada día. Pégalo en SQL Editor > RUN. Idempotente.
-- =====================================================================
alter table public.cuentas_dias add column if not exists banca_en_caja double precision;

-- =====================================================================
-- Cuentas Dark · supabase/cuentas_v3.sql  (app 1.3)
-- Dinero recogido de la caja durante el día (TPVDark "Recoger dinero"). Pégalo en SQL Editor > RUN. Idempotente.
-- Los movimientos de caja se leen de v_cuentas_dark_movimientos (TPVDark schema_supabase_v1_35.sql).
-- =====================================================================
alter table public.cuentas_dias add column if not exists recogido double precision;
alter table public.cuentas_dias add column if not exists recogido_txt text;
''';
