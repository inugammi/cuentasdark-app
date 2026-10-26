-- =====================================================================
-- Cuentas Dark · supabase/cuentas_v2.sql  (app 1.2)
-- Opción "Dejé la banca en caja" de cada día. Pégalo en SQL Editor > RUN. Idempotente.
-- =====================================================================
alter table public.cuentas_dias add column if not exists banca_en_caja double precision;
