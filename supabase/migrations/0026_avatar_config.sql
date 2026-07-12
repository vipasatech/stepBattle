-- 0026_avatar_config.sql
--
-- Bitmoji-style character avatar. `profiles.avatar_config` stores the
-- user's chosen face / hair / eyes / mouth / outfit / accessory ids
-- as a JSON blob (the `fluttermoji` package hands us this shape
-- verbatim from its FluttermojiFunctions.getFluttermojiConfig()
-- helper). Everywhere the app currently reads `avatar_url` it can
-- optionally prefer `avatar_config` and render the character rig
-- inline instead of loading a bitmap.
--
-- The column is nullable — a user without one still renders via the
-- existing `avatar_url` (Google OAuth photo, uploaded picture, or
-- initials fallback). A "Set up your avatar" sheet pops when the
-- user first taps `Create battle` or opens the Map's "who's leading
-- near you" view.
--
-- Shape example (elided):
--   {
--     "topType": "ShortHairShortWaved",
--     "accessoriesType": "Blank",
--     "hairColor": "Black",
--     "facialHairType": "Blank",
--     "clotheType": "Hoodie",
--     "clotheColor": "PastelBlue",
--     "eyeType": "Default",
--     "eyebrowType": "Default",
--     "mouthType": "Smile",
--     "skinColor": "Light"
--   }
--
-- No CHECK constraint on shape — the package's schema drifts across
-- releases and validating server-side would just cause a client-
-- side upgrade to 400. Rely on the client-side codec.

alter table public.profiles
  add column if not exists avatar_config jsonb;

comment on column public.profiles.avatar_config is
  'Fluttermoji character avatar spec (nullable). When present, clients render this in place of avatar_url.';
