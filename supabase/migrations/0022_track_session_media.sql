-- =============================================================================
-- StepBattle — Track session media + description.
--
-- WHY: The End-Run flow now opens a Save Activity page that lets the user
-- caption their run and attach up to 5 photos. The photos live in Supabase
-- Storage; we keep their public URLs alongside the row so the session
-- detail screen can render them as a swipeable carousel without re-listing
-- the bucket each time.
--
-- WHAT:
--   1. `track_sessions.description text`    — optional free-text note.
--   2. `track_sessions.media_urls jsonb`    — JSON array of public URLs in
--                                              user-chosen order. Empty
--                                              array (or null) when no
--                                              photos were attached.
--   3. `track-media` storage bucket          — public-read bucket; clients
--                                              upload to
--                                                track-media/<user_id>/<file>
--                                              and only the owner can
--                                              write/delete via RLS.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this file → Run.
--   Safe to re-run.
-- =============================================================================

-- ---- Columns ---------------------------------------------------------------

alter table public.track_sessions
  add column if not exists description text;

alter table public.track_sessions
  add column if not exists media_urls jsonb;

-- ---- Storage bucket -------------------------------------------------------

-- Public-read so the session-detail carousel can <Image.network> without
-- signed-URL rotation. Owner-only write enforced via the storage.objects
-- RLS policies below.
insert into storage.buckets (id, name, public)
  values ('track-media', 'track-media', true)
  on conflict (id) do nothing;

-- Allow any signed-in user to upload to a folder named after their own
-- user id (e.g. `track-media/<uid>/<file>`).
drop policy if exists "track_media_own_upload" on storage.objects;
create policy "track_media_own_upload"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'track-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Owner can delete / update / read their own objects. Everyone can read
-- (bucket is public) so the policy below is technically a no-op for
-- SELECT but kept for symmetry — if we ever tighten the bucket to
-- private we already have the right policy.
drop policy if exists "track_media_own_read" on storage.objects;
create policy "track_media_own_read"
  on storage.objects for select
  to public
  using (bucket_id = 'track-media');

drop policy if exists "track_media_own_delete" on storage.objects;
create policy "track_media_own_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'track-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "track_media_own_update" on storage.objects;
create policy "track_media_own_update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'track-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
