# Ticket API (create, status, cancel)

These calls come **only from your trusted backend**, with `x-api-key`. Base URL: `https://api.gameflow.gg/v1`. JSON is lowerCamelCase. Errors use the envelope `{"code": <grpc code>, "message": "...", "details": []}` (see the `gameflow` skill, api-conventions).

## Create a ticket

`POST /v1/matchmaking/tickets`

```bash
curl -sS -X POST https://api.gameflow.gg/v1/matchmaking/tickets \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "playerId": "u_123",
    "gameId": "'"$GAME_ID"'",
    "gameMode": "ranked-1v1",
    "preferredAz": "us-east",
    "attributes": { "character": "mage", "crossplay": true, "level": 12 }
  }'
```

```json
{ "ticketId": "d3k2...", "status": "queued" }
```

```ts
const res = await fetch("https://api.gameflow.gg/v1/matchmaking/tickets", {
  method: "POST",
  headers: { "x-api-key": process.env.GAMEFLOW_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({
    playerId,                       // from YOUR auth, never the request body
    gameId: process.env.GAMEFLOW_GAME_ID,
    gameMode: "ranked-1v1",
    preferredAz: region,            // validated against your allowlist
    attributes: { character: "mage" },
  }),
});
if (!res.ok) throw new Error(`create ticket ${res.status}: ${await res.text()}`);
const { ticketId } = (await res.json()) as { ticketId: string; status: string };
```

| Field | Required | Meaning |
|---|---|---|
| `playerId` | yes | Your stable player id. It appears as `player_id` in the server payload, and the cancel call must repeat it. Use the same id as `externalPlayerId` in skill rating. |
| `gameId` | yes | GameFlow game id. |
| `gameMode` | yes | Must equal the **Ticket Input** game mode of a **Live** matchmaker for this game. Case-sensitive. |
| `preferredAz` | strongly recommended | The region name the client picked from `GET /v1/ping/regions` (e.g. `us-east`). The match's server is started in the first matched player's `preferredAz`. Leave it empty only if the platform's default region suits you. |
| `attributes` | if declared | JSON object. Each key must be a custom attribute declared on Ticket Input, and each value a scalar of the declared type: String → `"x"`, Number → `5`, Boolean → `true`. Undeclared keys are rejected. Declared keys may be omitted. The values reach the game server in the payload. |
| `tags` | optional | String tags. A Bucket by Field node with Source = Tag can group on them. |
| `mu`, `sigma` | usually omit | A starting rating, read **only** on a queue with a Skill Rule when the player has no stored rating **and** the matchmaker has no Skill Rating Model node. In that case `sigma` must be > 0. With a model node, the server resolves the stored rating (unknown players get the model's initial rating, by default μ 25 / σ ≈ 8.333) and ignores these. FIFO queues ignore them too. |
| `ratingBucket` | usually omit | A number used only if a Bucket by Field node buckets on `rating_bucket`. It is **not verified** server-side, so compute it in your backend (e.g. from `POST /v1/skill-rating/player-rating:resolve`), never from client input. |

Create errors:

| HTTP / code | Message (prefix) | Meaning |
|---|---|---|
| 400 / 3 | `player_id is required`, `game_id is required`, `game_mode is required` | Field missing or misspelled. Unknown keys are dropped silently, so a typo looks like a missing field. |
| 400 / 9 | `no matchmaker is currently loaded for game_id=… game_mode=…` | No Live matchmaker for that exact pair. The published-queue list is cached for about 10 s, so retry once if you just published. |
| 400 / 3 | `unknown attribute "…"` / `attribute "…" must be a string|number|boolean` | Attribute schema mismatch. |
| 400 / 3 | `sigma must be greater than 0` | See `mu`/`sigma` above. |
| 401 / 403 | | Bad key, or role below Engineer. |
| 503 / 14 | `unable to verify matchmaker availability`, `resolve player rating: …`, `create ticket: …` | Transient. Retry with backoff. |

## Get ticket status (long-poll)

`GET /v1/matchmaking/tickets/{ticketId}/status?timeoutSeconds=25`

The server holds the request until the ticket is assigned or `timeoutSeconds` passes, then answers.

```bash
curl -sS --max-time 40 -H "x-api-key: $GAMEFLOW_API_KEY" \
  "https://api.gameflow.gg/v1/matchmaking/tickets/$TICKET_ID/status?timeoutSeconds=25"
```

```json
{ "ticketId": "d3k2...", "status": "pending" }
{ "ticketId": "d3k2...", "status": "assigned", "connection": "203-0-113-42.server.gameflow.gg:7777" }
```

```ts
async function waitForMatch(ticketId: string, signal: AbortSignal): Promise<{ host: string; port: number }> {
  let failures = 0;
  while (!signal.aborted) {
    try {
      const res = await fetch(
        `https://api.gameflow.gg/v1/matchmaking/tickets/${encodeURIComponent(ticketId)}/status?timeoutSeconds=25`,
        { headers: { "x-api-key": process.env.GAMEFLOW_API_KEY! }, signal: AbortSignal.any([signal, AbortSignal.timeout(40_000)]) },
      );
      if (res.status === 429 || res.status >= 500) throw new Error(`transient ${res.status}`);
      if (!res.ok) throw Object.assign(new Error(`status ${res.status}: ${await res.text()}`), { fatal: true });
      const body = (await res.json()) as { status: string; connection?: string };
      failures = 0;
      if (body.status === "assigned" && body.connection) {
        const i = body.connection.lastIndexOf(":");
        return { host: body.connection.slice(0, i), port: Number(body.connection.slice(i + 1)) };
      }
      // "pending" or "queued": the call already waited, so loop immediately
    } catch (err) {
      if ((err as { fatal?: boolean }).fatal || signal.aborted || ++failures >= 5) throw err;
      await new Promise((r) => setTimeout(r, Math.min(1000 * 2 ** failures, 10_000)));
    }
  }
  throw new Error("cancelled");
}
```
(`AbortSignal.any` needs Node 20.3+. On older runtimes, use one `AbortController` plus `setTimeout`.)

| Response field | Meaning |
|---|---|
| `status` | `"assigned"`: matched and the server is up. `"pending"`: no assignment within the window. `"queued"`: still waiting (the create response uses it, and the proto lists it for status). Treat anything other than `assigned` as "keep polling". |
| `connection` | `"host:port"`, set only when assigned. Split on the **last** `:`. `host` is a hostname for TLS games and an IP otherwise. |
| `extensions` | Map of strings. Currently not populated for matchmade tickets, so ignore it. |

Long-poll semantics:
- `timeoutSeconds` omitted or 0 → 30 s (`DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS`). The server enforces **no maximum**. Proxies and load balancers in the path may cut long requests, so stay ≤ 30.
- An HTTP timeout below `timeoutSeconds` turns every "pending" into a client error. Use `timeoutSeconds + 10` s or more.
- Polls after assignment return `assigned` again. Still, cache the result in your backend rather than relying on this.
- After a cancel, a status poll does **not** return a clean `pending`/404. It fails, and the code maps it to 503. Track cancelled tickets yourself and stop polling them.
- Polling the status is not a heartbeat for GameFlow: an abandoned ticket stays in the queue until you cancel it.

## Cancel a ticket

`DELETE /v1/matchmaking/tickets/{ticketId}?playerId=<owner>`

```bash
curl -sS -X DELETE -H "x-api-key: $GAMEFLOW_API_KEY" \
  "https://api.gameflow.gg/v1/matchmaking/tickets/$TICKET_ID?playerId=u_123"
# -> {}
```

```ts
const res = await fetch(
  `https://api.gameflow.gg/v1/matchmaking/tickets/${encodeURIComponent(ticketId)}?playerId=${encodeURIComponent(playerId)}`,
  { method: "DELETE", headers: { "x-api-key": process.env.GAMEFLOW_API_KEY! } },
);
if (!res.ok && res.status !== 404) throw new Error(`cancel ${res.status}: ${await res.text()}`);
```

- `playerId` is required and must equal the ticket's `playerId`. A mismatch returns **404 `ticket not found`**, deliberately the same as a missing ticket.
- Cancelling a ticket that is already gone (cancelled before, or cleaned up after matching) returns **404**. Treat 404 as success.
- Cancel when the player stops searching, disconnects, or stops polling. If the ticket was already assigned, cancelling does not stop the match: the server starts with an empty slot. Handle that with the join timeout on the server.

## Who calls what

| Caller | Calls |
|---|---|
| Game client | your backend; `GET /v1/ping/regions` (no auth); the region ping endpoints; the game server |
| Your backend (key) | tickets create, status and cancel |
| Game server (key, or via your backend) | `matches:start`, `matches:end`, `skill-rating/matches:report` |

The client gets only `host:port`. `match_id` and teams go to the game server through its payload.
