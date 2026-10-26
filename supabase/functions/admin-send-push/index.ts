import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const APP_ORIGIN = 'https://hazelawan.github.io';
const APP_PAGES: Record<string, string> = {
  customer: 'customer.html',
  shop: 'restaurant.html',
  rider: 'rider.html',
};

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function corsHeaders(req: Request): Record<string, string> {
  const requestedOrigin = req.headers.get('origin');
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
  if (requestedOrigin === APP_ORIGIN) headers['Access-Control-Allow-Origin'] = APP_ORIGIN;
  return headers;
}

function json(req: Request, data: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json; charset=utf-8' },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(req) });
  }
  if (req.method !== 'POST') return json(req, { error: 'Method not allowed' }, 405);

  const origin = req.headers.get('origin');
  if (origin && origin !== APP_ORIGIN) return json(req, { error: 'Origin not allowed' }, 403);

  const authorization = req.headers.get('authorization') || '';
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json(req, { error: 'Sign in as an administrator to send notifications.' }, 401);

  const { data: authData, error: authError } = await supabase.auth.getUser(tokenMatch[1]);
  if (authError || !authData.user) return json(req, { error: 'Your session is invalid or expired. Please sign in again.' }, 401);

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('role, is_blocked')
    .eq('id', authData.user.id)
    .maybeSingle();
  if (profileError) return json(req, { error: 'Could not verify administrator permissions.' }, 500);
  if (profile?.role !== 'admin' || profile.is_blocked === true) {
    return json(req, { error: 'Only an active administrator can send notifications.' }, 403);
  }

  let rawInput: unknown;
  try {
    rawInput = await req.json();
  } catch {
    return json(req, { error: 'Request body must be valid JSON.' }, 400);
  }
  if (!rawInput || typeof rawInput !== 'object' || Array.isArray(rawInput)) {
    return json(req, { error: 'Request body must be a JSON object.' }, 400);
  }
  const input = rawInput as Record<string, unknown>;

  const app = typeof input.app === 'string' ? input.app : 'all';
  const title = typeof input.title === 'string' ? input.title.trim() : '';
  const body = typeof input.body === 'string' ? input.body.trim() : '';
  if (app !== 'all' && !Object.hasOwn(APP_PAGES, app)) {
    return json(req, { error: 'Choose a valid app.' }, 400);
  }
  if (!title || title.length > 80 || !body || body.length > 300) {
    return json(req, { error: 'Enter a title (up to 80 characters) and message (up to 300 characters).' }, 400);
  }

  const { data: config, error: configError } = await supabase
    .from('push_config')
    .select('subject, vapid_public, vapid_private')
    .eq('id', 1)
    .single();
  if (configError || !config) return json(req, { error: 'Push notification settings are not configured.' }, 500);

  let subscriptionQuery = supabase
    .from('push_subscriptions')
    .select('id, app, endpoint, p256dh, auth')
    .limit(5000);
  if (app !== 'all') subscriptionQuery = subscriptionQuery.eq('app', app);
  const { data: subscriptions, error: subscriptionError } = await subscriptionQuery;
  if (subscriptionError) return json(req, { error: 'Could not load notification devices.' }, 500);

  webpush.setVapidDetails(config.subject, config.vapid_public, config.vapid_private);
  let sent = 0;
  let failed = 0;
  const expiredIds: string[] = [];
  await Promise.all((subscriptions || []).map(async (subscription: any) => {
    const targetPage = APP_PAGES[subscription.app] || APP_PAGES.customer;
    const payload = JSON.stringify({ title, body, url: targetPage, tag: `admin-${Date.now()}` });
    try {
      await webpush.sendNotification(
        { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } },
        payload,
        { TTL: 3600, urgency: 'high' },
      );
      sent++;
    } catch (error: any) {
      if (error?.statusCode === 404 || error?.statusCode === 410) expiredIds.push(subscription.id);
      else failed++;
    }
  }));

  if (expiredIds.length) {
    const { error: deleteError } = await supabase.from('push_subscriptions').delete().in('id', expiredIds);
    if (deleteError) console.error('Could not remove expired push subscriptions', deleteError.message);
  }

  return json(req, { sent, failed, removed: expiredIds.length, total: (subscriptions || []).length });
});
