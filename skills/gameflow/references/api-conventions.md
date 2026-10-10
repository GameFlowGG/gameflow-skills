# GameFlow API conventions

Base URL: `https://api.gameflow.gg/v1`. Interactive reference: https://docs.gameflow.gg/api/gameflow-api

## Authentication

```http
x-api-key: gf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

- **Where keys come from:** they're created in the dashboard (Settings → API Keys) and are org-wide. Each key acts with the role of the user who created it.
  - Writes (tickets, match start/end, rating reports and upserts) need at least the **Engineer** role.
  - Reads need **Viewer**.
- **Limits:** up to 3 active keys per org. The secret is shown once.
  - **Rotate** issues a new secret for the same key, and the old one stops immediately.
  - **Revoke later** schedules a cutoff, which helps with migrations.
- **Server-side only.** Never put a key in a game client, browser bundle, mobile app, public repo or log line.
- **Health check:** `GET /v1/identity/me` → `{user, organization, isOwner}`.

## Request and response bodies

- **Casing:** write JSON fields in **lowerCamelCase**: `gameId`, `gameMode`, `playerId`, `timeoutSeconds`, `externalPlayerId`.
  - **Responses are camelCase only.** `res.ticket_id` is `undefined`; use `res.ticketId`.
  - Requests also accept the snake_case proto names, but **unknown fields are silently dropped**. A misspelling such as `gameID` or `GameId` doesn't error by itself. It surfaces as "game_id is required".
  - Path params appear as `{game_id}` in the reference, but they are just URL segments.
- **Zero values are always present** in responses (`0`, `false`, `""`, `[]`), so check values, not key presence.
- **64-bit integers** (`int64`) are JSON **strings** in responses, e.g. `"startedAt": "1730000000000"` and `"durationMs": "53210"`. Convert them with `Number()` / `int()` before doing math.
- **Timestamps:** most are RFC 3339 strings. Match lifecycle fields (`startedAt`, `endedAt`) are Unix epoch **milliseconds**.
- **Enums** are strings, e.g. `"MATCH_RESULT_V1_SUCCESS"`.
- Set `Content-Type: application/json` on requests with a body.

## Errors

A non-2xx response carries the gRPC-gateway envelope:

```json
{ "code": 5, "message": "game abc not found", "details": [] }
```

| HTTP | `code` | Typical cause |
|---|---|---|
| 400 | 3 INVALID_ARGUMENT | Missing or misspelled field (check camelCase), bad region, attribute type mismatch |
| 401 | 16 UNAUTHENTICATED | Missing, invalid, expired or revoked `x-api-key` |
| 403 | 7 PERMISSION_DENIED | Role too low, or the resource belongs to another org |
| 404 | 5 NOT_FOUND | Wrong id, or path missing `/v1` |
| 400 | 9 FAILED_PRECONDITION | E.g. no published matchmaker for the queue, or game offline (read `message`) |
| 429 | 8 RESOURCE_EXHAUSTED | Rate limited, or no Ready server to allocate |
| 5xx | 13 / 14 | Retry with backoff |

**Retry policy:** retry only on 429, 5xx and network errors, with exponential backoff and jitter. Never retry 4xx validation errors unchanged.

## Pagination

Pagination styles differ per endpoint; follow the one each endpoint uses:

- Game servers, leaderboards and rating matches: `limit` + `cursor` → `nextCursor` (plus `hasMore` on servers).
- Builds: `pageSize` + `pageToken` → `nextPageToken`.
- Games: `page` + `pageSize`.

## Regions

- `GET /v1/ping/regions`: **no auth**. Returns `{"regions":[{"name":"us-east","endpoint":"https://…"}]}`.
  - Native game clients may call it directly.
  - Browser clients can't: CORS only allows the GameFlow dashboard origin. Proxy it through your backend.
- **CORS in general:** the API is not callable from browsers on your own domain. Every browser game talks to its own backend, which also keeps the key server-side.
- `GET /v1/regions/available`: auth. Returns `{"regions":["eu-central","us-east"]}`.
- Region ids are short slugs. Always take them from the API rather than hard-coding a list.

## Minimal TypeScript client

```ts
const GAMEFLOW_API = "https://api.gameflow.gg/v1";

export async function gameflow<T>(path: string, init: RequestInit = {}): Promise<T> {
  const key = process.env.GAMEFLOW_API_KEY;
  if (!key) throw new Error("GAMEFLOW_API_KEY is not set");
  const res = await fetch(`${GAMEFLOW_API}${path}`, {
    ...init,
    headers: {
      "x-api-key": key,
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...init.headers,
    },
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : {};
  if (!res.ok) {
    throw new Error(`GameFlow ${res.status} ${path}: ${body.message ?? text}`);
  }
  return body as T;
}

// usage: const me = await gameflow<{ organization: { id: string } }>("/identity/me");
```

## Minimal Python client

```python
import os, requests

GAMEFLOW_API = "https://api.gameflow.gg/v1"

def gameflow(method: str, path: str, **kwargs):
    key = os.environ["GAMEFLOW_API_KEY"]
    r = requests.request(method, f"{GAMEFLOW_API}{path}",
                         headers={"x-api-key": key}, timeout=kwargs.pop("timeout", 30), **kwargs)
    if not r.ok:
        raise RuntimeError(f"GameFlow {r.status_code} {path}: {r.text}")
    return r.json() if r.content else {}
```
