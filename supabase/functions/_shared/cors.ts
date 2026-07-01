// Shared CORS headers for Edge Functions called from the Flutter client.
// The mobile app uses `supabase_flutter`'s `functions.invoke`, which passes
// auth headers automatically — but a preflight `OPTIONS` still hits the
// function before the JS runtime gets a chance to authenticate, so the
// permissive headers below are necessary even for mobile-only callers.
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
