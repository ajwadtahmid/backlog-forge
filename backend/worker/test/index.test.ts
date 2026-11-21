import { describe, expect, it, vi } from 'vitest';
import { handle, safeEqual, type Env, type RateLimit } from '../src/handler';

const STEAM_ID = '76561197960287930';
const env: Env = { STEAM_API_KEY: 'test-key', CLIENT_TOKEN: 'secret' };

const req = (path: string, init: RequestInit = {}) =>
  new Request(`https://api.example.com${path}`, init);
const authed = (path: string) => req(path, { headers: { 'X-Client-Token': 'secret' } });

/** Fake Steam: records the URL it was called with and returns [body]. */
function steam(body: unknown, status = 200) {
  const calls: string[] = [];
  const fetchImpl = vi.fn(async (url: string | URL | Request) => {
    calls.push(String(url));
    return new Response(JSON.stringify(body), { status });
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

const games = [
  { appid: 620, name: 'Portal 2', playtime_forever: 1200, rtime_last_played: 1700000000 },
];

describe('/user/library', () => {
  it('returns the Steam games array unchanged', async () => {
    const s = steam({ response: { game_count: 1, games } });
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, s.fetchImpl);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(games);
    const url = new URL(s.calls[0]);
    expect(url.origin + url.pathname).toBe(
      'https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/',
    );
    expect(url.searchParams.get('key')).toBe('test-key');
    expect(url.searchParams.get('steamid')).toBe(STEAM_ID);
    expect(url.searchParams.get('include_appinfo')).toBe('true');
    expect(url.searchParams.get('include_played_free_games')).toBe('true');
  });

  it('passes app_id as appids_filter[0] with literal brackets', async () => {
    const s = steam({ response: { games } });
    await handle(authed(`/user/library?steam_id=${STEAM_ID}&app_id=620`), env, s.fetchImpl);
    expect(s.calls[0]).toContain('&appids_filter[0]=620');
  });

  it('private profile (empty response) → 403 profile_private', async () => {
    const s = steam({ response: {} });
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, s.fetchImpl);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'profile_private' });
  });

  it('owns zero games → 200 []', async () => {
    const s = steam({ response: { game_count: 0, games: [] } });
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, s.fetchImpl);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([]);
  });

  it('Steam error status → 502 without leaking the key', async () => {
    const s = steam('Forbidden', 403);
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, s.fetchImpl);
    expect(res.status).toBe(502);
    expect(await res.text()).not.toContain('test-key');
  });

  it('Steam non-JSON body → 502', async () => {
    const fetchImpl = (async () =>
      new Response('<html>', { status: 200 })) as unknown as typeof fetch;
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, fetchImpl);
    expect(res.status).toBe(502);
  });

  it('Steam timeout → 504 steam_api_timeout', async () => {
    const fetchImpl = (async () => {
      throw new DOMException('timed out', 'TimeoutError');
    }) as unknown as typeof fetch;
    const res = await handle(authed(`/user/library?steam_id=${STEAM_ID}`), env, fetchImpl);
    expect(res.status).toBe(504);
    expect(await res.json()).toEqual({ error: 'steam_api_timeout' });
  });

  it.each([
    ['', 'steam_id required'],
    ['steam_id=123', 'invalid_steam_id'],
    [`steam_id=${STEAM_ID}&app_id=abc`, 'invalid_app_id'],
    [`steam_id=${STEAM_ID}x`, 'invalid_steam_id'],
  ])('rejects bad input "%s" → 400 %s', async (query, error) => {
    const s = steam({});
    const res = await handle(authed(`/user/library?${query}`), env, s.fetchImpl);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error });
    expect(s.calls).toHaveLength(0);
  });

  it('missing or wrong X-Client-Token → 401, Steam never called', async () => {
    const s = steam({ response: { games } });
    const variants: Record<string, string>[] = [{}, { 'X-Client-Token': 'wrong' }];
    for (const headers of variants) {
      const res = await handle(
        req(`/user/library?steam_id=${STEAM_ID}`, { headers }),
        env,
        s.fetchImpl,
      );
      expect(res.status).toBe(401);
    }
    expect(s.calls).toHaveLength(0);
  });

  it('no CLIENT_TOKEN configured → auth skipped (self-hosting)', async () => {
    const s = steam({ response: { games } });
    const res = await handle(
      req(`/user/library?steam_id=${STEAM_ID}`),
      { STEAM_API_KEY: 'k' },
      s.fetchImpl,
    );
    expect(res.status).toBe(200);
  });

  it('missing STEAM_API_KEY → 500', async () => {
    const res = await handle(req(`/user/library?steam_id=${STEAM_ID}`), { STEAM_API_KEY: '' });
    expect(res.status).toBe(500);
  });

  it('rate limiter: denied → 429; keyed by IP + Steam ID', async () => {
    const keys: string[] = [];
    let allow = true;
    const limiter: RateLimit = {
      limit: async ({ key }) => {
        keys.push(key);
        return { success: allow };
      },
    };
    const s = steam({ response: { games } });
    const request = () =>
      req(`/user/library?steam_id=${STEAM_ID}`, {
        headers: { 'X-Client-Token': 'secret', 'CF-Connecting-IP': '203.0.113.7' },
      });
    const limited = { ...env, LIBRARY_LIMITER: limiter };
    expect((await handle(request(), limited, s.fetchImpl)).status).toBe(200);
    allow = false;
    expect((await handle(request(), limited, s.fetchImpl)).status).toBe(429);
    expect(keys).toEqual([`203.0.113.7:${STEAM_ID}`, `203.0.113.7:${STEAM_ID}`]);
    expect(s.calls).toHaveLength(1);
  });
});

describe('/auth/steam/callback', () => {
  it('302 to backlogforge://auth with every openid param, verbatim and in order', async () => {
    const query =
      'openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0&openid.mode=id_res' +
      '&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Fid%2F76561197960287930' +
      '&openid.signed=signed%2Cop_endpoint&openid.sig=abc%2B%2F%3D&openid.extra=1&openid.extra=2';
    const res = await handle(req(`/auth/steam/callback?${query}`), env);
    expect(res.status).toBe(302);
    const location = res.headers.get('location')!;
    expect(location.startsWith('backlogforge://auth?')).toBe(true);

    const forwarded = new URLSearchParams(location.split('?')[1]);
    const original = new URLSearchParams(query);
    expect([...forwarded]).toEqual([...original]); // includes repeated keys
    expect(forwarded.get('openid.sig')).toBe('abc+/='); // signature survives encoding
  });

  it('works without X-Client-Token (browser redirect)', async () => {
    const res = await handle(req('/auth/steam/callback?openid.mode=cancel'), env);
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('backlogforge://auth?openid.mode=cancel');
  });
});

describe('routing', () => {
  it('/health → ok', async () => {
    const res = await handle(req('/health'), env);
    expect(await res.json()).toEqual({ status: 'ok' });
  });

  it('unknown path → 404, non-GET → 405', async () => {
    expect((await handle(req('/lookup?q=x'), env)).status).toBe(404);
    expect((await handle(req('/health', { method: 'POST' }), env)).status).toBe(405);
  });
});

describe('safeEqual', () => {
  it('compares exactly', () => {
    expect(safeEqual('secret', 'secret')).toBe(true);
    expect(safeEqual('secret', 'secreT')).toBe(false);
    expect(safeEqual('secret', 'secret1')).toBe(false);
    expect(safeEqual('', 'x')).toBe(false);
  });
});
