# Match lifecycle on the game server

What a matchmade dedicated server does, in order:

1. SDK connect, listen on `GAMEFLOW_DEFAULT_PORT`, then `ready()`.
2. Read the payload (and keep listening for payload changes).
3. Admit only the players in the payload.
4. Call `matches:start` once all are connected.
5. Play.
6. Call `matches:end`, then `skill-rating/matches:report` on rated queues.
7. SDK `shutdown()`, then exit the process.

SDK install and the rest of the server lifecycle: the `gameflow-servers` skill.

## The payload

GameFlow builds this JSON when it forms the match. It is **snake_case** (unlike the REST API):

```json
{
  "match_id": "7c1d0a52-...",
  "game_mode": "ranked-2v2",
  "team_count": 2,
  "teams": [
    { "team_index": 0, "players": [
      { "player_id": "u_123", "ticket_id": "d3k2...", "slot_index": 0, "attributes": { "character": "mage" } },
      { "player_id": "u_456", "ticket_id": "e9f1...", "slot_index": 1 }
    ]},
    { "team_index": 1, "players": [ "..." ] }
  ]
}
```

| Field | Notes |
|---|---|
| `match_id` | Opaque string. Pass it as `matchId` to `matches:start`, `matches:end` and `skill-rating/matches:report`. |
| `game_mode` | The ticket's `gameMode`. One server build can serve several modes. |
| `team_count` | Number of teams formed. |
| `teams[]` | Sorted by `team_index` (from 0). Players are sorted by `slot_index`. |
| `players[].player_id` | The `playerId` your backend put on the ticket. |
| `players[].ticket_id` | The ticket that produced this seat. |
| `players[].attributes` | That player's custom ticket attributes, with types preserved (string, number, boolean). **Omitted** when the ticket had none. |

How to read it:
- Use the SDK: TS `gf.payload()` / `gf.onPayloadChange(fn)`, Unity `await gf.Payload()` / `gf.OnPayloadChange(fn)`, Godot `(await gf.payload()).value` / `gf.on_payload_change(fn)`.
- The payload is a Kubernetes **annotation**, not an env var. `getenv("GAMEFLOW_PAYLOAD")` is empty in production.
- It may be empty at startup and arrive when the server is allocated to a match, so subscribe to changes as well as reading once.
- **Local testing:** in SDK local mode, export `GAMEFLOW_PAYLOAD='{"match_id":"local-1",...}'` to simulate it. `matches:start` will return 404 for a fake `match_id`, so skip the API calls when `match_id` starts with `local-`.

## Admit only matched players

The payload tells you **who** should join. You still have to prove that a connecting client **is** that player. Two levels:

- **Minimum:** the client sends its `playerId`, and the server rejects ids not in the payload and duplicate joins. This blocks strangers who scan `host:port`, but anyone who knows a matched id can impersonate that player.
- **Recommended:** a join token from your backend. When the status route returns `assigned`, your backend also returns `joinToken = base64url(JSON{p: playerId, t: ticketId, exp}) + "." + base64url(HMAC-SHA256(secret, firstPart))`. The game server holds the same secret (a game env var, e.g. `MATCH_JOIN_SECRET`), verifies the token, and checks that `p`/`t` match a payload seat. The [asset module](../assets/matchmaking-routes.ts) produces this token when `joinTokenSecret` is set.

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyJoinToken(token: string, secret: string): { p: string; t: string } | null {
  const [body, sig] = token.split(".");
  if (!body || !sig) return null;
  const expected = createHmac("sha256", secret).update(body).digest("base64url");
  const a = Buffer.from(sig), b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  const claims = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as { p: string; t: string; exp: number };
  return claims.exp > Date.now() ? { p: claims.p, t: claims.t } : null;
}
```

## TypeScript server (Node, `@gameflow.gg/gameserver-sdk`)

```ts
import { GameFlow } from "@gameflow.gg/gameserver-sdk";

type Seat = { player_id: string; ticket_id: string; slot_index: number; attributes?: Record<string, unknown> };
type MatchPayload = { match_id: string; game_mode: string; team_count: number;
  teams: { team_index: number; players: Seat[] }[] };

const API = "https://api.gameflow.gg/v1";
const GAME_ID = process.env.GAMEFLOW_GAME_ID!;      // your own game env var
const API_KEY = process.env.GAMEFLOW_API_KEY!;      // game env var/secret; never sent to clients
const JOIN_TIMEOUT_MS = 60_000;

const gf = await GameFlow.connect();
let match: MatchPayload | null = null;
const expected = new Map<string, { team: number; slot: number; seat: Seat }>();
const connected = new Set<string>();
let started = false;
let finished = false;

function applyPayload(raw: string | undefined) {
  if (!raw || match) return;                         // one match per server process
  match = JSON.parse(raw) as MatchPayload;
  for (const team of match.teams)
    for (const seat of team.players) expected.set(seat.player_id, { team: team.team_index, slot: seat.slot_index, seat });
  setTimeout(() => { if (!started) void finish("MATCH_RESULT_V1_FAILURE"); }, JOIN_TIMEOUT_MS);
}
gf.onPayloadChange(applyPayload);
applyPayload(await gf.payload());

startMyGameServer(Number(gf.ports.default ?? 7777)); // your netcode
await gf.ready();

// Call from your netcode when a client authenticates (after verifyJoinToken)
export async function onPlayerJoin(playerId: string): Promise<boolean> {
  if (!match || !expected.has(playerId) || connected.has(playerId)) return false; // reject
  connected.add(playerId);
  await gf.players.connect(playerId);
  if (!started && connected.size === expected.size) {
    started = true;
    await callWithRetry("/matchmaking/matches:start", { gameId: GAME_ID, matchId: match.match_id, startedAt: Date.now() });
  }
  return true;
}

export async function finish(result: "MATCH_RESULT_V1_SUCCESS" | "MATCH_RESULT_V1_FAILURE" | "MATCH_RESULT_V1_CANCELED") {
  if (finished) return;
  finished = true;
  if (match) {
    const res = await callWithRetry("/matchmaking/matches:end",
      { gameId: GAME_ID, matchId: match.match_id, result, endedAt: Date.now() });
    console.log("match ended", res?.state, "durationMs", res?.durationMs && Number(res.durationMs));
    // Rated queues: POST /v1/skill-rating/matches:report with matchId: match.match_id (gameflow-skill-rating skill)
  }
  await gf.shutdown();
  process.exit(0);
}

async function callWithRetry(path: string, body: unknown, attempts = 5): Promise<any> {
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(`${API}${path}`, {
        method: "POST",
        headers: { "x-api-key": API_KEY, "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) return res.json();
      if (res.status !== 429 && res.status < 500) {          // 4xx: don't retry unchanged
        console.error(path, res.status, await res.text());
        return null;
      }
    } catch { /* network error: retry */ }
    await new Promise((r) => setTimeout(r, 500 * 2 ** i));
  }
  console.error(path, "gave up"); // analytics are best-effort: never block the match on them
  return null;
}

declare function startMyGameServer(port: number): void;
```

## Unity (C#) server sketch

```csharp
// After: await gf.Start(); start your transport; await gf.Ready();
gf.OnPayloadChange(ApplyPayload);
ApplyPayload(await gf.Payload());

void ApplyPayload(string raw)
{
    if (string.IsNullOrEmpty(raw) || match != null) return;
    // Use Newtonsoft (JsonUtility can't read the per-player "attributes" object)
    match = Newtonsoft.Json.JsonConvert.DeserializeObject<MatchPayload>(raw);
    foreach (var team in match.teams)
        foreach (var p in team.players) expected[p.player_id] = team.team_index;
}

[System.Serializable] public class MatchPayload { public string match_id; public string game_mode; public int team_count; public Team[] teams; }
[System.Serializable] public class Team { public int team_index; public Seat[] players; }
[System.Serializable] public class Seat { public string player_id; public string ticket_id; public int slot_index;
    public System.Collections.Generic.Dictionary<string, object> attributes; }
```

Send `matches:start` and `matches:end` with `HttpClient` from the server process. Use the header `x-api-key` and a camelCase body: `{"gameId":…,"matchId":…,"result":"MATCH_RESULT_V1_SUCCESS"}`. Then call `await gf.Shutdown();` and `Application.Quit();`.

## Godot server sketch

```gdscript
func _on_ready_done() -> void:
    gf.on_payload_change(_apply_payload)
    var res := await gf.payload()
    _apply_payload(res.value)

func _apply_payload(raw) -> void:
    if raw == null or raw == "" or match_data != null:
        return
    match_data = JSON.parse_string(raw)
    for team in match_data["teams"]:
        for seat in team["players"]:
            expected[seat["player_id"]] = int(team["team_index"])
```

Post lifecycle calls with `HTTPRequest.request(url, ["x-api-key: " + OS.get_environment("GAMEFLOW_API_KEY"), "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))`. Then call `await gf.shutdown()` and `get_tree().quit()`. (`OS.get_environment` is fine for **your own** env vars like the key. Only the payload must come from the SDK.)

## `matches:start`

`POST /v1/matchmaking/matches:start`

```json
{ "gameId": "…", "matchId": "<payload match_id>", "startedAt": 1730000000000 }
```
→ `{"matchId":"…","state":"…","startedAt":"1730000000000","alreadyRecorded":false}`

- Call it when **every** expected player has connected and play begins. `startedAt` is epoch ms and optional (defaults to now). Send it explicitly when retrying later.
- **First call wins.** A repeat returns the original `startedAt` with `alreadyRecorded: true`. It is not an error.

## `matches:end`

`POST /v1/matchmaking/matches:end`

```json
{ "gameId": "…", "matchId": "…", "result": "MATCH_RESULT_V1_SUCCESS", "endedAt": 1730000600000, "externalMatchId": "my-match-42" }
```
→ `{"matchId":"…","state":"…","endedAt":"1730000600000","durationMs":"600000","alreadyRecorded":false}`

| `result` | Use when |
|---|---|
| `MATCH_RESULT_V1_SUCCESS` | The match played out. |
| `MATCH_RESULT_V1_FAILURE` | It broke: not enough players joined (join timeout), a crash, an unrecoverable error. |
| `MATCH_RESULT_V1_CANCELED` | Deliberately abandoned (e.g. the players agreed to cancel). |

- `result` is required. An unset value or `MATCH_RESULT_V1_UNSPECIFIED` is rejected with 400.
- `durationMs` is present only if `matches:start` was recorded: absent, not zero.
- **First call wins.** A retry returns the recorded outcome with `alreadyRecorded: true`.
- `externalMatchId` is optional: your own id, for joining records.

## Types and errors

- int64 response fields (`startedAt`, `endedAt`, `durationMs`) are **strings**: use `Number(x)`. Inputs accept numbers or strings.
- Epoch **milliseconds**, not seconds: `Date.now()`, `DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()`, `Time.get_unix_time_from_system() * 1000` (Godot returns float seconds, so convert with `int()`).
- 404 `no match <id> for game <id>`: wrong `gameId`, or a `matchId` that did not come from a matchmade payload.
- 400 `game_id is required` / `match_id is required`: field missing or misspelled. Unknown keys are dropped silently, so write `gameId` and `matchId`.
- 401/403: key or role (Engineer or higher).
- 503 `match history is not configured`: platform-side. Retry later. The match itself is unaffected.
- These writes are best-effort analytics. Never fail or delay the match because one failed.

## Rated queues

After `matches:end`, report placements with `POST /v1/skill-rating/matches:report` (`ranks` parallel to `teams`, lower is better, 0 = winner). Pass `matchId` set to the payload `match_id` to link ratings to match analytics. Full details are in the `gameflow-skill-rating` skill.

**Unlike `matches:start` and `matches:end`, `matches:report` is not idempotent:** every successful call applies the ratings again.
- An error response means nothing was written, so retrying it is safe.
- On a timeout or network error, the call may have succeeded. Check the model's recorded matches (`GET /v1/skill-rating/models/{modelId}/matches`) before sending it again.
- Send it once per match, from one place (server **or** backend, not both).
