-- =====================================================================
-- Cuentas Dark · supabase/cuentas_v3.sql  (app 1.3)
-- Dinero recogido de la caja durante el día (TPVDark "Recoger dinero"). Pégalo en SQL Editor > RUN. Idempotente.
-- Los movimientos de caja se leen de v_cuentas_dark_movimientos (TPVDark schema_supabase_v1_35.sql).
-- =====================================================================
alter table public.cuentas_dias add column if not exists recogido double precision;
alter table public.cuentas_dias add column if not exists recogido_txt text;
