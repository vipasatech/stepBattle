// =============================================================================
// StepBattle — send-push Edge Function (FCM HTTP v1)
//
// Sends a single push notification through Firebase Cloud Messaging. Called by
// the `notifications_push_trigger` Postgres trigger (see migration 0009) every
// time a row lands in `public.notifications`, so battle results / invites /
// level-ups can wake a backgrounded or terminated phone.
//
// AUTH: deployed WITHOUT JWT verification; instead it checks a shared secret
// header so only our database trigger can call it.
//
// DEPLOY (Supabase CLI, one-time):
//   1. Put your Firebase service-account JSON + a random secret into the
//      function's environment:
//        supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
//        supabase secrets set PUSH_WEBHOOK_SECRET="<random-long-string>"
//   2. Deploy with JWT verification off (the shared secret guards it):
//        supabase functions deploy send-push --no-verify-jwt
//   3. Mirror the URL + secret into Postgres Vault (see migration 0009 header).
//
// The Firebase service account is created in:
//   Firebase Console → Project Settings → Service accounts → Generate new
//   private key. It must belong to the SAME Firebase project as the app.
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri: string;
}

interface PushPayload {
  token?: string;
  title?: string;
  body?: string;
  data?: Record<string, unknown>;
  // When true, send a data-only message (no visible notification) — used for
  // the pre-end "sync_wake" nudge that just wakes the app to upload steps.
  silent?: boolean;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function base64url(input: string | Uint8Array): string {
  let raw: string;
  if (typeof input === "string") {
    raw = btoa(input);
  } else {
    let s = "";
    for (const b of input) s += String.fromCharCode(b);
    raw = btoa(s);
  }
  return raw.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Mint a short-lived OAuth2 access token for the FCM scope from the service
// account (RS256-signed JWT → Google token endpoint exchange).
async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  };
  const unsigned =
    `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claim))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json();
  return json.access_token as string;
}

serve(async (req: Request): Promise<Response> => {
  // Shared-secret gate (function is deployed with --no-verify-jwt).
  const secret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }

  let payload: PushPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const { token, title, body, data, silent } = payload;
  // Recipient has no registered device — nothing to do, not an error.
  if (!token) return new Response(JSON.stringify({ skipped: "no_token" }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!saRaw) return new Response("missing FCM_SERVICE_ACCOUNT", { status: 500 });

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saRaw);
  } catch {
    return new Response("invalid FCM_SERVICE_ACCOUNT json", { status: 500 });
  }

  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa);
  } catch (e) {
    return new Response(`auth error: ${e}`, { status: 502 });
  }

  // FCM data values must all be strings.
  const stringData: Record<string, string> = {};
  for (const [k, v] of Object.entries(data ?? {})) {
    stringData[k] = typeof v === "string" ? v : JSON.stringify(v);
  }

  const message = {
    message: {
      token,
      // Silent wake-ups are data-only (no notification block) so nothing is
      // shown to the user — they just nudge the app to sync.
      ...(silent
        ? {}
        : { notification: { title: title ?? "StepBattle", body: body ?? "" } }),
      data: stringData,
      android: { priority: "high" },
      apns: silent
        ? {
          headers: { "apns-priority": "5" },
          payload: { aps: { "content-available": 1 } },
        }
        : { headers: { "apns-priority": "10" } },
    },
  };

  const fcmRes = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(message),
    },
  );

  const respText = await fcmRes.text();
  return new Response(respText, {
    status: fcmRes.ok ? 200 : 502,
    headers: { "Content-Type": "application/json" },
  });
});
