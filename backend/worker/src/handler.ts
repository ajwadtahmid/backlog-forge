/**
 * BacklogForge API — request handling (entry point: src/index.ts).
 *
 * Replaces the Python/Render server. HLTB lookups now run on the device, so
 * this Worker only does what needs a secret or an https URL:
 *
 *   GET /user/library?steam_id=…[&app_id=…]  Steam GetOwnedGames proxy (holds STEAM_API_KEY)
 *   GET /auth/steam/callback?openid.*         Bounces Steam OpenID back into the app
 *   GET /health
 *
 * Response contract is identical to the old server, so the app only needs a
 * new BACKEND_URL.
 */

export interface Env {
  /** Steam Web API key (secret). */
  STEAM_API_KEY: string;
  /** Shared token the app sends as X-Client-Token (secret). Empty = no auth. */
  CLIENT_TOKEN?: string;
  /** Optional Workers Rate Limiting binding; skipped when not configured. */
  LIBRARY_LIMITER?: RateLimit;
}

/** Minimal shape of the Workers rate limiting binding. */
export interface RateLimit {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export const STEAM_OWNED_GAMES =
  'https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/';
export const APP_CALLBACK = 'backlogforge://auth';
const STEAM_TIMEOUT_MS = 15_000;

const STEAM_ID = /^\d{17}$/;
const APP_ID = /^\d{1,10}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    },
  });

/** Constant-time string comparison (avoids leaking the token via timing). */
export function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

async function userLibrary(
  request: Request,
  env: Env,
  url: URL,
  fetchImpl: typeof fetch,
): Promise<Response> {
  const expected = env.CLIENT_TOKEN ?? '';
  if (expected && !safeEqual(request.headers.get('X-Client-Token') ?? '', expected)) {
    return json({ error: 'unauthorized' }, 401);
  }
  if (!env.STEAM_API_KEY) {
    return json({ error: 'STEAM_API_KEY not configured' }, 500);
  }

  const steamId = (url.searchParams.get('steam_id') ?? '').trim();
  if (!steamId) return json({ error: 'steam_id required' }, 400);
  if (!STEAM_ID.test(steamId)) return json({ error: 'invalid_steam_id' }, 400);

  const appId = (url.searchParams.get('app_id') ?? '').trim();
  if (appId && !APP_ID.test(appId)) return json({ error: 'invalid_app_id' }, 400);

  if (env.LIBRARY_LIMITER) {
    // Key on the Steam ID too, so one abusive client can't drain a shared IP.
    const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    const { success } = await env.LIBRARY_LIMITER.limit({ key: `${ip}:${steamId}` });
    if (!success) return json({ error: 'rate_limited' }, 429);
  }

  const steamUrl = new URL(STEAM_OWNED_GAMES);
  steamUrl.searchParams.set('key', env.STEAM_API_KEY);
  steamUrl.searchParams.set('steamid', steamId);
  steamUrl.searchParams.set('include_appinfo', 'true');
  steamUrl.searchParams.set('include_played_free_games', 'true');
  // Literal brackets, exactly as the old server sent them (appId is digits only).
  const target = appId
    ? `${steamUrl.toString()}&appids_filter[0]=${appId}`
    : steamUrl.toString();

  let res: Response;
  try {
    res = await fetchImpl(target, {
      signal: AbortSignal.timeout(STEAM_TIMEOUT_MS),
    });
  } catch (e) {
    const timedOut =
      e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError');
    // Never log steamUrl — it contains the API key.
    console.error('steam fetch failed', timedOut ? 'timeout' : String(e));
    return json(
      { error: timedOut ? 'steam_api_timeout' : 'steam_api_error' },
      timedOut ? 504 : 502,
    );
  }

  if (res.status !== 200) {
    console.error('steam returned', res.status);
    return json({ error: 'steam_api_error' }, 502);
  }

  let data: { response?: { games?: unknown } };
  try {
    data = await res.json();
  } catch {
    return json({ error: 'steam_api_error' }, 502);
  }
  // Steam answers 200 with an empty `response` when the profile/games are private.
  const games = data?.response?.games;
  if (!Array.isArray(games)) return json({ error: 'profile_private' }, 403);
  return json(games);
}

/**
 * Steam requires an http(s) return_to, so it redirects here and we bounce to
 * the app's custom scheme. Every openid.* parameter is forwarded verbatim
 * (repeated keys preserved): the app re-verifies the signature with Steam via
 * check_authentication, which fails if anything is altered. Unauthenticated
 * by design — it is a browser redirect and only reflects Steam's own response.
 */
function steamCallback(url: URL): Response {
  const query = url.searchParams.toString();
  return new Response(null, {
    status: 302,
    headers: {
      location: query ? `${APP_CALLBACK}?${query}` : APP_CALLBACK,
      'cache-control': 'no-store',
    },
  });
}

/** Request handler; [fetchImpl] is injectable for tests. */
export async function handle(
  request: Request,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  switch (url.pathname) {
    case '/user/library':
      return userLibrary(request, env, url, fetchImpl);
    case '/auth/steam/callback':
      return steamCallback(url);
    case '/health':
      return json({ status: 'ok' });
    default:
      return json({ error: 'not_found' }, 404);
  }
}

