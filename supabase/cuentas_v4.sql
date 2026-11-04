-- =====================================================================
-- Cuentas Dark · supabase/cuentas_v4.sql  (app 1.6)
-- Fotos de los clientes de recargas (las toma el Vigilante en la PC) para verlas también en el celular.
-- Pégalo en SQL Editor > RUN. Idempotente.
-- =====================================================================
create table if not exists public.cuentas_fotos (
    telefono text primary key, jpg text, updated_at bigint
);
alter table public.cuentas_fotos enable row level security;
drop policy if exists tpv_autenticado on public.cuentas_fotos;
create policy tpv_autenticado on public.cuentas_fotos for all to authenticated using (true) with check (true);
create index if not exists ix_cuentas_fotos_upd on public.cuentas_fotos (updated_at);
