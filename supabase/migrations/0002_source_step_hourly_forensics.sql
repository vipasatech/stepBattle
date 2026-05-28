-- =============================================================================
-- StepBattle — extend source_step_hourly with the forensic columns the
-- Firestore version carried (per-source error strings, device fingerprint,
-- updated_at, hour_key).
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
--   Safe to re-run: every ALTER uses IF NOT EXISTS.
-- =============================================================================

alter table public.source_step_hourly
  add column if not exists hour_key text,
  add column if not exists winning_source text,
  add column if not exists native_error text,
  add column if not exists health_connect_error text,
  add column if not exists google_fit_error text,
  add column if not exists device_manufacturer text,
  add column if not exists device_model text,
  add column if not exists android_version text,
  add column if not exists app_version text,
  add column if not exists updated_at timestamptz;

-- Drop the placeholder column we no longer use (winning_source replaces it).
alter table public.source_step_hourly
  drop column if exists source_label;

create index if not exists source_step_hourly_hour_key_idx
  on public.source_step_hourly (hour_key);
