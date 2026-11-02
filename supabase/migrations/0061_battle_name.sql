-- =============================================================================
-- Migration 0061 — Add optional user-provided battle name to `battles`.
--
-- WHY: 1.1.6+39 lets users name a battle from any setup sheet ("🌅 Morning
-- Warriors", "Revenge match", …) so the name shows up on Discover cards,
-- Battle-Ground headers, and Day-Summary tiles in place of the auto-
-- generated "1v1 battle by X". The client already has:
--   • `BattleModel.name : String?` (models/battle_model.dart:221) —
--     `(d['name'] as String?)`, trimmed, null when blank.
--   • `BattleNameField` widget wired into all three setup sheets.
--   • `BattleService.createBattle(name: name)` passing `name` through the
--     RPC.
-- The column simply doesn't exist server-side yet — every insert with a
-- non-null name would fail. This migration adds it.
--
-- SCHEMA: `battles.name text null`. No default (null = "no user name;
-- render the auto-generated label"). No length CHECK — the client
-- trims + caps at ~40 chars via [BattleNameField]'s
-- inputFormatters; a server-side guard could be added later if we see
-- abuse, but for now the input widget is the whole enforcement.
--
-- BACKFILL: none needed. Existing battles have no name; they render as
-- "$type battle by $creator" (client-side fallback in
-- lib/screens/battles/discover_battles_screen.dart line ~290 and
-- friends). Column default = null so ALTER TABLE ADD COLUMN is O(1)
-- metadata-only, no full-table rewrite.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
--
-- ROLLBACK:
--   alter table public.battles drop column if exists name;
--   (Loses any user-set names — irreversible for the affected rows.)
-- =============================================================================

alter table public.battles
  add column if not exists name text;

-- Optional: comment for anyone poking around the schema later.
comment on column public.battles.name is
  'Optional user-provided battle name (migration 0061, 2026-09-04). '
  'NULL = render the auto-generated "<type> battle by <creator>" label. '
  'Client-side length cap ~40 chars via BattleNameField input formatters.';

-- =============================================================================
-- Verification queries (run separately after the ALTER above):
--
--   1. Confirm column exists + nullable + no default:
--        select column_name, data_type, is_nullable, column_default
--        from information_schema.columns
--        where table_schema='public'
--          and table_name='battles'
--          and column_name='name';
--      Expected: name | text | YES | NULL
--
--   2. Confirm existing rows carry NULL (backfill would be visible here):
--        select count(*) as total,
--               count(name) as named,
--               count(*) - count(name) as anonymous
--        from public.battles;
--      Expected: named = 0, anonymous = total (until users start naming).
--
--   3. Smoke-test an insert with a name (using a real UID + type):
--        insert into public.battles (created_by, type, stake_xp, name)
--        values (
--          <your-test-uid>::uuid, 'oneVsOne', 100,
--          '0061 self-test — delete me'
--        )
--        returning id, name;
--      then:
--        delete from public.battles
--         where name = '0061 self-test — delete me';
-- =============================================================================
