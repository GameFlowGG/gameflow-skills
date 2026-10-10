# Game server API

**Conventions:**
- Base `https://api.gameflow.gg/v1`, header `x-api-key`. Call these from your **backend or tooling only**, never from a game client.
- Bodies are camelCase. A misspelled request field is silently ignored, so a "missing" payload or buildId usually means a typo. int64 fields (`cpuRequestMillicores`, `memoryUsageBytes`, `durationSeconds`, …) come back as **strings**. Timestamps are RFC 3339.
- The `region` must be one of the game's configured regions (`GET /v1/games/{gameId}` → `.game.game.config`). Per-server calls **require `?region=`**, because the server name alone is not enough.

## Start a standalone server (blocks until Ready)

`POST /v1/games/{gameId}/servers`

```json
{ "region": "us-east", "payload": "{\"lobbyId\":\"abc\"}", "buildId": "1a2b3c4d", "launchArgs": ["-map", "arena"] }
```

**Request fields:**
- Only `region` is required.
- `payload` is an opaque string; the server reads it via the SDK.
- `buildId` defaults to the current build, or the latest successful one if none is current.
- `launchArgs` are appended after the game's launch options as container args, after a leading `--`.

**Behavior:**
- The call returns when the server is Ready, after up to ~120 s, so set your HTTP timeout to at least 150 s.
- It fails if the game is offline, the region isn't configured, or free-tier caps are hit.

```json
{
  "server": {
    "name": "gs-org-game-x7k2p",
    "state": "Ready",
    "address": "203.0.113.42",
    "host": "203.0.113.42",
    "port": 7342,
    "ports": [{ "name": "default", "port": 7342, "protocol": "udp" }],
    "region": "us-east",
    "gameId": "…",
    "buildId": "1a2b3c4d",
    "playerCount": 0,
    "playerCapacity": 16,
    "connectedPlayers": [],
    "createdAt": "2026-10-07T12:00:00Z"
  }
}
```

**Connecting to it:**
- Clients connect to `host` + `port` (or a named entry in `ports`).
- For TLS games `host` is a hostname (e.g. `203-0-113-42.server.gameflow.gg`), the port's `protocol` is `"tls"`, and clients connect with TLS (`wss://`).
- `port` here is the **external** port, not `GAMEFLOW_DEFAULT_PORT`.

## Launch without waiting

`POST /v1/games/{gameId}/servers/launch` takes the same body and returns `{server}` immediately (not yet Ready). Poll the details every 2–5 s until `state` is `Ready`.

## Allocate a Ready server from the fleet (fast path)

`POST /v1/fleets/{gameId}/allocate` with `{ "region": "eu-central", "payload": "{…}" }`

```json
{
  "allocation": {
    "address": "198.51.100.7",
    "host": "198.51.100.7",
    "port": 7105,
    "serverName": "gs-org-game-abcde",
    "ports": [{ "name": "default", "port": 7105, "protocol": "udp" }],
    "imageUri": "…"
  }
}
```

**Requirements:**
- Intelligent Autoscaling must be on for the game, and a fleet must exist in that region.
- Don't rely on `buildId` in this response; it may be empty.

**What happens:**
- The payload is written onto the claimed server. The server sees it through the SDK payload-change event, not at startup.
- `429` / `code 8` (`RESOURCE_EXHAUSTED`, "no available game servers") means no Ready server is free. Retry with backoff, raise the fleet buffer, or fall back to `POST …/servers`.

## List, details, deletion

| Call | Returns |
|---|---|
| `GET /v1/games/{gameId}/servers?limit=&cursor=&search=&sort=` | `{servers:[GameServer], nextCursor, hasMore}` (may include `historical: true` entries with `endedAt`, `durationSeconds`) |
| `GET /v1/servers?limit=&cursor=&search=&region=` | Same shape, across all games of the org |
| `GET /v1/games/{gameId}/servers/{serverName}?region=` | `{name, state, address, host, port, ports, playerCount, playerCapacity, connectedPlayers, buildId, cpuUsageMillicores, memoryUsageBytes, …}` |
| `DELETE /v1/games/{gameId}/servers/{serverName}?region=` | `{}`. Sends SIGTERM; the process has ~45 s to call SDK Shutdown and exit. |
| `GET /v1/games/{gameId}/servers/{serverName}/deletion-status?region=` | `{status, message, progress}` |

`connectedPlayers` is the list of ids your server reported via the SDK. If it stays empty while players are connected, the SDK player calls are missing (and the server risks idle shutdown).

## Logs, events, metrics

| Call | Notes |
|---|---|
| `GET …/servers/{serverName}/logs?region=` | Live stream: newline-delimited JSON, each line `{"result":{"message","timestamp"}}`. Use `curl -N`. |
| `GET …/servers/{serverName}/logs/history?region=&limit=&start=&end=` | `{serverName, entries:[{timestamp, message}], content}` |
| `GET …/servers/{serverName}/logs/download?region=` | `{content, serverName}` |
| `GET …/servers/{serverName}/events?region=` | `{events:[{type, reason, message, source, firstTimestamp, lastTimestamp, count}]}`. Look here for crash loops, image pull or scheduling errors. |
| `GET …/servers/{serverName}/metrics?region=&startTime=&endTime=&stepSeconds=` | `{cpuMillicores:[{timestamp, value}], memoryBytes:[…], source, partial}` |

## Regions

- `GET /v1/regions/available` (auth) → `{regions:["eu-central","us-east"]}`
- `GET /v1/ping/regions` (**no auth**, fine for clients) → `{regions:[{name, endpoint}]}`. The client measures latency to each `endpoint` and sends the best `name` to your backend.

## Backend example (TypeScript, Node 18+)

```ts
const API = "https://api.gameflow.gg/v1";
const KEY = process.env.GAMEFLOW_API_KEY!;   // backend env only
const GAME_ID = process.env.GAMEFLOW_GAME_ID!;

type Port = { name: string; port: number; protocol: string };
type Allocation = { host: string; address: string; port: number; serverName: string; ports: Port[] };

async function post<T>(path: string, body: unknown, timeoutMs = 15_000): Promise<{ status: number; body: T }> {
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "x-api-key": KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  return { status: res.status, body: (text ? JSON.parse(text) : {}) as T };
}

/** Called by your authenticated "join/host game" endpoint, never by the client directly. */
export async function getServerFor(region: string, payload: object): Promise<{ host: string; port: number; serverName: string }> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const r = await post<{ allocation?: Allocation; message?: string }>(`/fleets/${GAME_ID}/allocate`, {
      region,
      payload: JSON.stringify(payload),
    });
    if (r.status === 200 && r.body.allocation) {
      const a = r.body.allocation;
      return { host: a.host, port: a.port, serverName: a.serverName };
    }
    if (r.status !== 429 && r.status < 500) throw new Error(`allocate ${r.status}: ${r.body.message}`);
    await new Promise((res) => setTimeout(res, 500 * 2 ** attempt + Math.random() * 250));
  }
  // Fleet exhausted: cold-start one (slow, up to ~120 s).
  const s = await post<{ server?: { host: string; port: number; name: string }; message?: string }>(
    `/games/${GAME_ID}/servers`,
    { region, payload: JSON.stringify(payload) },
    150_000,
  );
  if (s.status !== 200 || !s.body.server) throw new Error(`start ${s.status}: ${s.body.message}`);
  return { host: s.body.server.host, port: s.body.server.port, serverName: s.body.server.name };
}
```

Return `host` and `port` to the client, and keep `serverName` + `region` server-side if you may need to stop the server.
