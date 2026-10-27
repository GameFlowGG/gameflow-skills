---
name: gameflow-matchmaking
description: Add matchmaking to a multiplayer game with GameFlow (gameflow.gg). Covers designing a matchmaker in the dashboard (teams, skill rules, region buckets, rules that relax over time), creating and polling tickets from your backend, choosing a region from player ping, sending players to their assigned server, and recording match start and end. Use it for a find-match or quick-match button, lobby queues, ranked or MMR queues, game modes, region-based matching, or tickets that stay pending and never find a match.
license: MIT
metadata:
  author: GameFlow
  version: "0.1.0"
---

# GameFlow Matchmaking

GameFlow forms matches from **tickets** and hands each match a dedicated server. You draw the matching rules as a node graph in the dashboard. Your **backend** creates and polls tickets. The **game client** only talks to your backend and then connects to `host:port`. The **game server** learns who is in the match from its payload.

```
client --find match--> your backend --POST /v1/matchmaking/tickets--> GameFlow
client <--host:port--- your backend <--status "assigned", "host:port"-- GameFlow (long-poll)
client --connect--> game server (reads payload: match_id, teams) --matches:start / matches:end--> GameFlow
```

Essentials (details in the `gameflow` skill):
- Base URL `https://api.gameflow.gg/v1`, header `x-api-key: $GAMEFLOW_API_KEY`. A 404 on a known path usually means `/v1` is missing.
- Write request JSON in **lowerCamelCase** (`playerId`, `gameMode`, `timeoutSeconds`). Responses are camelCase only. **Unknown or misspelled fields are silently dropped.** The **server payload** JSON is the exception: it is snake_case (`match_id`).
- **The API key never ships in a game client.** Clients call your backend. `playerId` comes from **your** auth, never from the request body.
- If the GameFlow docs MCP is connected, check each request body against `get_api_operation` before writing it. If a field name differs from this skill, **don't choose yourself or write code with either name**. The docs can be ahead of the deployed API, and the wrong name is silently dropped. Show the user both names and ask which one their environment accepts.

## 0. Prerequisites

Check these before writing code:

- [ ] An API key with at least the **Engineer** role in `GAMEFLOW_API_KEY`. If missing, use the `gameflow` skill.
- [ ] A game with an uploaded server build that reaches Ready and uses the Game Server SDK. If missing, use the `gameflow-servers` skill. Note the `gameId` (`GET /v1/games` returns `{games: [{game: {id, title, ...}, live, ...}]}`).
- [ ] A **trusted backend** to hold the key: your own Node/Go/etc. service, or Supabase edge functions. No backend yet? Suggest the 3 routes in [references/backend-examples.md](references/backend-examples.md).
- [ ] For testing, prefer a separate staging game. There is no sandbox.

## 1. Design and publish the matchmaker (human, in the dashboard)

Ask the user about their game, then hand them a checklist with exact values. Recipes are in [references/matchmaker-design.md](references/matchmaker-design.md).

Questions to ask:
1. How many teams, and how many players per team? (Team Composition supports 2 to 8 teams of 1 to 64.)
2. Ranked or casual? Ranked needs a skill model (the `gameflow-skill-rating` skill) plus **Skill Rating Model** and **Skill Rule** nodes.
3. Should players only match within their region? If yes, add **Bucket by Field** on `preferred_az`.
4. What per-player data must the server know (e.g. `character`, `map_vote`, `crossplay`)? Each becomes a **custom attribute** on Ticket Input, with a type: String, Number or Boolean.
5. What is the game mode string (e.g. `ranked-1v1`)? Your backend must send it **exactly**.

Checklist for the user:
1. app.gameflow.gg → **Matchmaking → Create matchmaker**. Pick the game and give it a name.
2. Start from a sample (FIFO, Ranked 5v5, Split by Mode) or build the graph: `Ticket Input → … → Team Composition → Output`.
3. **Ticket Input**: set the game mode. The default is `default`, so change it. Add the custom attributes with their types.
4. Configure the remaining nodes from the recipe, and fix every issue in the validation panel.
5. **Publish**. The status must read **Live**: drafts and paused matchmakers reject tickets.
6. Keep one Live matchmaker per `(game, gameMode)`.

**Verify (agent):** create a test ticket, then cancel it.
```bash
curl -sS -X POST https://api.gameflow.gg/v1/matchmaking/tickets \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"playerId":"smoke-test-1","gameId":"'"$GAME_ID"'","gameMode":"ranked-1v1","preferredAz":"us-east"}'
# -> {"ticketId":"...","status":"queued"}
curl -sS -X DELETE "https://api.gameflow.gg/v1/matchmaking/tickets/$TICKET_ID?playerId=smoke-test-1" \
  -H "x-api-key: $GAMEFLOW_API_KEY"
```
A 400 response saying `no matchmaker is currently loaded for game_id=… game_mode=…` means the matchmaker is not published for that exact mode, or it was published seconds ago (retry after ~10 s).

## 2. Backend: three routes

Put the ticket calls in your backend behind your own auth. Recommended shape:

| Your route | Does | GameFlow call |
|---|---|---|
| `POST /matchmaking/join` body `{region, gameMode?}` | Authenticates the player, reuses an open ticket or creates one | `POST /v1/matchmaking/tickets` |
| `GET /matchmaking/status/:ticketId` | Checks ownership, long-polls, maps to `{status, host, port}` | `GET /v1/matchmaking/tickets/{id}/status?timeoutSeconds=25` |
| `DELETE /matchmaking/:ticketId` | Cancels the player's own ticket | `DELETE /v1/matchmaking/tickets/{id}?playerId=…` |

Rules:
- **`playerId` = your authenticated user id.** Never read it from the client body. Use the same id later as `externalPlayerId` in skill rating.
- **Allowlist** `gameMode` and `region` server-side. Build `attributes` server-side, or validate them, with the exact declared types (`5`, not `"5"`).
- **Idempotent join:** keep `playerId → ticketId`. A second join while searching returns the existing ticket instead of queueing the player twice.
- **Long-poll:** use `timeoutSeconds` ≤ 30 (default 30; the server enforces no maximum). Set the HTTP timeout to at least `timeoutSeconds + 10` s, both backend→GameFlow and client→backend.
- **Status values:** `assigned` means `connection` is `"host:port"`. `pending` and `queued` both mean "still searching: poll again". Treat any other value as still searching and log it.
- **Split `host:port` on the last `:`.** `host` can be a hostname (TLS games) or an IP.
- **Retries:** retry 429, 5xx and network errors with backoff, and give up after about 5 consecutive failures. Don't retry other 4xx errors.
- **Cancel** when the player presses cancel, closes the socket, or stops polling. A sweep that cancels tickets not polled for about 60 s covers crashed clients. A cancel that returns **404** means the ticket is already gone or matched: treat it as success. Stop polling after a cancel.
- **Cache the assignment.** Once a ticket is assigned, store `{host, port}` and return it on later polls. The ticket is spent: never re-queue it.

Full API detail: [references/ticket-api.md](references/ticket-api.md). Complete Node/Express and Supabase (Deno) code: [references/backend-examples.md](references/backend-examples.md). Drop-in module: [assets/matchmaking-routes.ts](assets/matchmaking-routes.ts).

## 3. Client: region, join, wait, connect

1. **Measure ping.** `GET https://api.gameflow.gg/v1/ping/regions` needs **no auth** and returns `{"regions":[{"name":"us-east","endpoint":"https://…"}]}`. Time 3 to 4 requests to each `endpoint`, drop the first, keep the lowest median, and let the player override.
   - Native clients can call it directly. Browser games may be blocked by CORS on the API host: serve the region list from your backend instead.
   - Never hard-code region lists. `eu-west` does not exist.
2. Call **your** backend: `POST /matchmaking/join {region}` with the player's session token (not a GameFlow key).
3. Loop on `GET /matchmaking/status/:ticketId` until it returns `assigned`. Show a timer and a Cancel button.
4. Connect to `host:port` with your netcode (TLS/WSS for TLS games).
5. On Cancel or quit, call `DELETE /matchmaking/:ticketId`. On transient errors, retry with backoff. On a failed connect, show "Match failed, search again?" and start a **new** join.

Unity C#, Godot GDScript and browser TypeScript: [references/client-examples.md](references/client-examples.md).

## 4. Game server: payload, start, end, rating, shutdown

On a matchmade server, GameFlow writes the match into the server's payload. Read it with the SDK's payload getter (`gf.payload()` / `Payload()` / `payload()`) and subscribe to payload-change events: it can arrive after connect. **Never `getenv("GAMEFLOW_PAYLOAD")`**: that is empty in production and only simulates the payload locally.

```json
{"match_id":"…","game_mode":"ranked-1v1","team_count":2,
 "teams":[{"team_index":0,"players":[{"player_id":"u_123","ticket_id":"…","slot_index":0,"attributes":{"character":"mage"}}]}]}
```

Server checklist:
1. SDK connect → listen on `GAMEFLOW_DEFAULT_PORT` → `ready()`.
2. Read the payload and build `allowed = set(player_id)`. **Reject joins from players not in the payload.** Proving identity needs a token your backend issues: see [references/match-lifecycle.md](references/match-lifecycle.md).
3. Seat players by `team_index` and `slot_index`. Use each player's `attributes`.
4. Once **all** expected players are connected: `POST /v1/matchmaking/matches:start {gameId, matchId}`. If someone never shows up, end with `MATCH_RESULT_V1_FAILURE` after a join timeout.
5. When play ends: `POST /v1/matchmaking/matches:end {gameId, matchId, result}`. `result` is `MATCH_RESULT_V1_SUCCESS`, `MATCH_RESULT_V1_FAILURE` or `MATCH_RESULT_V1_CANCELED`.
6. Rated queue: `POST /v1/skill-rating/matches:report` with `matchId` set to `match_id` (the `gameflow-skill-rating` skill).
7. SDK `shutdown()`, then exit the process.

Both lifecycle calls are idempotent: the first call wins and a retry returns `alreadyRecorded: true`. So retry them with backoff. `skill-rating/matches:report` is **not** idempotent: each call re-applies ratings. Retry it only after an error response, and after a timeout check the recorded matches first. Timestamps are epoch **ms**, and int64 responses are strings (`"durationMs": "53210"`).

**Key placement:** the server needs `GAMEFLOW_API_KEY` (set it as a game env var in the dashboard), or it can send these events to your backend, which makes the calls. Either way the key never goes to a client.

Code for TS, Unity and Godot servers: [references/match-lifecycle.md](references/match-lifecycle.md).

## 5. Verify end to end

- [ ] Smoke ticket from §1 returns `{ticketId, status: "queued"}`, and its cancel succeeds.
- [ ] With N test players (N = teams × players per team), each gets `assigned` with the **same** `host:port`.
- [ ] The server logs the parsed payload with the expected `player_id`s and attributes.
- [ ] `matches:start` and `matches:end` return 200, and the end response includes `durationMs`.
- [ ] Cancel mid-search: a later player is not matched into an empty slot.
- [ ] `grep -rn "x-api-key\|GAMEFLOW_API_KEY\|gf_" <client dirs>` finds nothing.

## Common failures

| Symptom | Cause / fix |
|---|---|
| 400 `no matchmaker is currently loaded for game_id=… game_mode=…` | Not published or Live, wrong `gameId`, or a `gameMode` typo or case mismatch with the Ticket Input mode. Just published? Retry in ~10 s. |
| 400 `unknown attribute "x"; declare it on the matchmaker's ticket input node` | Attribute not declared, or its name differs. Declare it, then republish. |
| 400 `attribute "x" must be a number` | Type mismatch: `"5"` sent where a Number was declared, or `"true"` for a Boolean. |
| 400 `sigma must be greater than 0` | Skill Rule without a Skill Rating Model node, new player. Add the model node (preferred) or send `mu`/`sigma`. |
| 400 `player_id is required` (or `game_id`, `game_mode`) | Field missing or misspelled: unknown keys are dropped silently. Use `playerId`, `gameId`, `gameMode`. |
| Attributes or `preferredAz` silently ignored | Misspelled key (e.g. `preferred_region`, `attrs`): it was dropped. |
| 401 / 403 | Missing or invalid key, or the key creator's role is too low (writes need Engineer, reads need Viewer). |
| 404 on every call | Path missing `/v1`. |
| 503 on create | Rating lookup or Open Match briefly unavailable. Retry with backoff. |
| Always `pending` | Not enough compatible players (team size × count, buckets too narrow), or the server can't be provisioned in `preferredAz` (region not deployed for the game, no build). Check the dashboard queue and the `gameflow-troubleshooting` skill. |
| Players from different regions in one match | No Bucket by Field on `preferred_az`. The server goes to the first player's region. |
| Next player lands on an empty server | Tickets not cancelled on disconnect. Add cancel on close plus a stale sweep. |
| `matches:start` 404 `no match … for game …` | `matchId` not taken from a matchmade payload (e.g. local test or manual allocate), or wrong `gameId`. |

## References

- [references/ticket-api.md](references/ticket-api.md): create, status and cancel requests and responses, fields, status values, long-poll, errors
- [references/matchmaker-design.md](references/matchmaker-design.md): every node, design recipes, how attributes reach the server
- [references/backend-examples.md](references/backend-examples.md): Node/Express and Supabase edge function implementations
- [references/client-examples.md](references/client-examples.md): Unity, Godot and browser clients, plus ping-based region choice
- [references/match-lifecycle.md](references/match-lifecycle.md): payload handling, join verification, `matches:start` and `matches:end` with retries
- [assets/matchmaking-routes.ts](assets/matchmaking-routes.ts): framework-agnostic backend module (Node 18+, Deno, Bun)
