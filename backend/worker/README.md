# BacklogForge API (Cloudflare Worker)

Replaces the Python server on Render. HowLongToBeat lookups run on the device
now, so the backend only does two things that need a secret or an https URL:

| Route | Purpose |
|---|---|
| `GET /user/library?steam_id=…[&app_id=…]` | Proxies Steam `GetOwnedGames` with your `STEAM_API_KEY`. Requires `X-Client-Token`. |
| `GET /auth/steam/callback?openid.*` | Steam sign-in redirect → `backlogforge://auth?…` (params forwarded verbatim; the app verifies the signature). |
| `GET /health` | `{"status":"ok"}` |

Responses match the old server exactly, so the app only needs a new `BACKEND_URL`.

Free-plan cost: ~1–2 requests per sync and 1 per sign-in, with no storage.
That is a tiny slice of the 100k requests/day Workers allowance.

## 1. Prerequisites

- A Cloudflare account (the one you already use is fine).
- Node.js 20+.
- Your Steam Web API key (<https://steamcommunity.com/dev/apikey>). You can
  reuse the key from Render.
- A long random client token. The app embeds it (obfuscated) and the Worker checks it:
  ```sh
  openssl rand -hex 32
  ```

## 2. Install and log in

```sh
cd backend/worker
npm install
npx wrangler login        # opens the browser once
```

## 3. Set the secrets

```sh
npx wrangler secret put STEAM_API_KEY    # paste the Steam key
npx wrangler secret put CLIENT_TOKEN     # paste the random token
```

Secrets are stored encrypted by Cloudflare and never go in the repo.
If the Worker does not exist yet, `secret put` offers to create it. Say yes,
or run step 4 first and set the secrets afterwards.

## 4. Deploy

```sh
npm test          # 20 unit tests
npm run deploy    # = wrangler deploy
```

Wrangler prints the URL, e.g. `https://backlogforge-api.<your-subdomain>.workers.dev`.

> **Rate limiter.** `wrangler.jsonc` configures a `LIBRARY_LIMITER` binding
> (10 library requests per minute per IP + Steam ID). If your plan rejects
> the `ratelimits` block on deploy, delete it; the Worker skips the check
> when the binding is absent.

**Optional custom domain:** Dashboard → Workers & Pages → `backlogforge-api` →
Settings → Domains & Routes → Add → Custom domain (e.g. `api.yourdomain.com`).
A custom domain lets you change the backend later without an app update.

## 5. Verify the deployment

```sh
URL=https://backlogforge-api.<your-subdomain>.workers.dev
TOKEN=<your client token>
STEAM_ID=<your 17-digit Steam ID>

curl $URL/health                                                  # {"status":"ok"}
curl -H "X-Client-Token: $TOKEN" "$URL/user/library?steam_id=$STEAM_ID" | head -c 300   # your games
curl -i "$URL/user/library?steam_id=$STEAM_ID"                    # 401 without the token
curl -si "$URL/auth/steam/callback?openid.mode=cancel" | grep -i location
# location: backlogforge://auth?openid.mode=cancel
```

To watch live logs: `npx wrangler tail`. Logs are also in Dashboard → Observability.

## 6. Point the app at the Worker

In the Flutter project root:

1. Edit `.env`:
   ```
   BACKEND_URL=https://backlogforge-api.<your-subdomain>.workers.dev
   CLIENT_TOKEN=<the same token as the Worker secret>
   ```
   No trailing slash on `BACKEND_URL`.
2. **Regenerate the obfuscated env file.** envied bakes the values into
   `lib/env.g.dart` at build time:
   ```sh
   dart run build_runner build --delete-conflicting-outputs
   ```
3. Rebuild the app. Then test sign-in (Steam's login page shows the Worker's
   domain as the "realm") and a sync.

## 7. Retire Render

Keep the Render service running until most users are on the new app version.
Older builds still call Render's `/lookup` and `/search`, which this Worker
does not provide. After that, shut Render down and archive
`backlog-forge-server`.

## Local development

```sh
cp .dev.vars.example .dev.vars   # fill in a real or dummy key
npm run dev                      # http://localhost:8787
```

With a dummy Steam key, `/user/library` returns `502 steam_api_error`.
That is expected and shows the request reached Steam.

## Layout

```
src/index.ts      entry point. Default export only: workerd treats named
                  exports of the entry module as entrypoints.
src/handler.ts    routing, Steam proxy, OpenID bounce (unit-tested)
test/             vitest tests; fetch is injected, no network
wrangler.jsonc    Worker config + rate limiter binding
```
