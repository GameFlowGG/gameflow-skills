---
name: gameflow-troubleshooting
description: Fix a broken game server, matchmaking or skill rating integration on GameFlow (gameflow.gg). Starts from the exact error or symptom and works through the cause, the check and the fix for API errors (401, 403, 404, 429, FailedPrecondition), builds that fail or stay queued, servers that never become Ready or keep restarting, players who can't connect, "no available game servers" on allocation, matchmaking tickets stuck pending, an empty launch payload, or ratings that don't update. Use it whenever a GameFlow integration isn't working or you need to dig into server logs, events or metrics.
license: MIT
metadata:
  author: GameFlow
  version: "0.1.0"
---

# GameFlow troubleshooting

Triage a broken GameFlow integration: collect facts, match the symptom, run the check, apply the fix. Conventions (base URL, auth header, casing, error envelope) are in the `gameflow` skill's [api-conventions.md](../gameflow/references/api-conventions.md); this skill links to it rather than repeating it.

**Rules while debugging**
- Never ask the user to paste their API key into chat, logs or a support ticket. Run commands that read `$GAMEFLOW_API_KEY` from their environment.
- If you find a key in game-client code (Unity/Godot/Unreal client, browser, mobile), stop and flag it: move the call to the backend and rotate the key. That's a bug in its own right, whatever else is wrong.
- Read-only checks first. Don't stop servers, delete builds or cancel tickets without asking.
- Causes marked *(inferred)* come from reading the platform code, not from a documented guarantee.

## Step 1: Collect facts

Get these before guessing:

1. **The exact error body**: `{"code": <int>, "message": "...", "details": []}` and the HTTP status. The `message` is the most useful clue; look it up in [references/error-catalog.md](references/error-catalog.md).
2. **Endpoint + method** as actually sent (full URL, including `/v1`).
3. **`gameId`, `gameMode`, region**, and for servers the `serverName`; for builds the `buildId`.
4. **Who makes the call**: backend, dedicated server, CI, or (bug) the client.

Then rule out auth with the identity check:

```bash
curl -sS https://api.gameflow.gg/v1/identity/me -H "x-api-key: $GAMEFLOW_API_KEY"
```

- 200 with `{user, organization, isOwner}`: the key works. Note `user.role` (Viewer can't write) and `organization.autoscalingEnabled`.
- 401 `invalid API key`: wrong, expired or revoked key (the API deliberately doesn't say which). Create or rotate one in the dashboard.

For a one-shot snapshot (identity, games, game config, builds, servers), run [scripts/diagnose.sh](scripts/diagnose.sh) `[gameId]`. It never prints the key.

## Step 2: Match the symptom

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| **401** `access token not present in metadata` | No `x-api-key` header (empty env var, header dropped by a proxy, wrong header name) | `echo ${GAMEFLOW_API_KEY:+set}` in the process's environment | Send `x-api-key: <key>` from server-side env |
| **401** `invalid API key` | Mistyped, expired, rotated or revoked key | `/identity/me` | New key in Settings → API Keys; update the secret everywhere |
| **403** `insufficient permissions` | Key's creator is a Viewer; writes (tickets, reports, builds, servers) need Engineer | `/identity/me` → `user.role` | Ask an admin to raise the role, or use a key made by an Engineer/Admin |
| **403** `this endpoint requires session authentication` | Calling a dashboard-only endpoint (API keys, members, billing, support tickets) with a key | Path is under settings/identity org management | Do it in the dashboard |
| **403** `user not authorized to access game` | The `gameId` belongs to another org | `GET /v1/games` with this key | Use the right key or game |
| **404** with no JSON body, or on a path you expected | Missing `/v1`, typo in path, wrong method | Print the full URL | Base is `https://api.gameflow.gg/v1` |
| **404** `game <id> not found` / `game not found or does not belong to your organization` | Wrong or deleted `gameId`, or a title used instead of an id | `GET /v1/games` | Use `game.id` from the list |
| **400** `game_id is required` (or `player_id`, `game_mode`, `region`, `s3_path` ...) | Field missing or misspelled. Errors name fields in snake_case; JSON uses `gameId`. Any other spelling (`gameID`, `GameId`, nesting under `data`) is silently dropped | Log the exact JSON sent | Send the camelCase name at the top level, `Content-Type: application/json` |
| Response field is `undefined` | Code reads `ticket_id`, `server_name` ...; responses are camelCase only | Dump the raw response | Read `ticketId`, `serverName`; parse int64 strings |
| **Build `failed`** | Wrong archive layout, no Linux executable found, Dockerfile error, unsupported `.gz` | `GET /v1/images/builds/{buildId}` → `message`; then `.../logs` | See [Build failures](#build-failures) |
| **Build stuck `queued`/`running`** | Builds queue; large images take minutes | Poll every ~10 s; `.../logs` steps | If no progress for 30+ min, escalate with the `buildId` |
| **New build not running** | A successful upload isn't promoted automatically (only the first one, or when none is current) | `GET /v1/images/builds?gameId=` → `isCurrent` / `currentBuild` | Promote it in the dashboard (Builds → Set as Current) |
| **Start server → 504** `game server <name> did not become ready within 120 seconds` | SDK `ready()` never called, process crashed, wrong engine/executable | Logs **history** (the server is deleted on timeout) and events | See [Server never Ready](#server-never-ready) |
| **Start → 500** `game server <name> failed to start (state: Unhealthy\|Error\|Shutdown)` | Crash on boot, health heartbeats stopped, or `shutdown()` called early | Logs history + events | Fix the crash; let the SDK send health |
| **Start → 400** `This game is offline for maintenance...` | Game set offline | `GET /v1/games/{gameId}` → `offline` | Bring it online in the dashboard |
| **Start → 400** `no successful build found, please build first` | No `success` build | Builds list | Upload and wait for `success` |
| **400** `region "x" is not configured for game <id> (available: [...])` | Region not in the game config | Game → `config.regions`; `GET /v1/regions/available` | Use a listed region, or add it to the game |
| **Allocate → 429** `no available game servers in fleet gs-...` | No Ready server in that region: autoscaling off for this game, buffer used up, or servers crash before Ready | Game `fleetConfig.scalingStrategy`; `GET .../servers` states | Enable Intelligent Autoscaling, raise buffer/max, fix crashes; or use `POST /v1/games/{gameId}/servers` |
| **Enabling autoscaling → 403** `Intelligent Autoscaling is not included in your current plan` | Plan entitlement | `organization.autoscalingEnabled` | Upgrade, or start standalone servers |
| **429** `monthly server-hours cap reached` / `monthly egress cap reached` | Free-tier cap | Usage page | Upgrade, or wait for the period to reset |
| **Players can't connect** | Wrong port/host/protocol, server not listening on `GAMEFLOW_DEFAULT_PORT`, TLS to the IP | See [references/connectivity.md](references/connectivity.md) | Connect to the returned `host` + `port` with the game's protocol |
| **Ticket → 400** `no matchmaker is currently loaded for game_id="..." game_mode="..."` | No published Live matchmaker for that exact `(gameId, gameMode)`, or a typo/case mismatch; briefly after a platform restart | Dashboard → Matchmaking: published + Live, Ticket Input game mode | Publish; match `gameMode` exactly; retry once after a few seconds |
| **Ticket → 400** `unknown attribute "x"; declare it...` / `attribute "x" must be a number` | `attributes` don't match the Ticket Input node schema | Ticket Input custom attributes | Declare the attribute or fix the JSON type (`5`, not `"5"`) |
| **Ticket → 400** `sigma must be greater than 0` | Skill-rated queue, new player, no stored rating, no starting `sigma` sent | `player-rating:resolve` → `found` | Attach a model (then it's resolved server-side) or send `mu`/`sigma > 0` |
| **Ticket stays `pending`** | Not enough compatible tickets; region/skill/tag rules too strict; queue for a different `gameId`/`gameMode`; server provisioning failing | See [Ticket stuck pending](#ticket-stuck-pending) | |
| **Cancel → 404** `ticket not found` | Already matched/removed, or `playerId` isn't the ticket owner | Same `playerId` as create? | Treat 404 as done; pass the owner's `playerId` |
| **Payload empty on the server** | Read with getenv, read once before allocation, or local mode | See [Payload empty](#payload-empty) | Use the SDK payload getter + change event |
| **Ratings not updating** | No model on the live matchmaker, report never sent or failed, ranks inverted, model paused | See [Ratings not updating](#ratings-not-updating) | |

## Build failures

`GET /v1/images/builds/{buildId}` returns `{status, message, imageUri}`. On `failed`, `message` is `build failed: <cause>`:

- `unsupported artifact type: ...`: the extractor handles `.zip`, `.tar`, `.tar.gz`/`.tgz` and `.pck`. A bare `.gz` passes the upload check but cannot be built *(inferred from code)*. Repack as `.zip` or `.tar.gz`.
- `detect executable: executable not found`: no Dockerfile at the archive root and the engine template found no server binary. Unity/Godot need a **Linux** `*.x86_64`/`*.x86` (Godot: or a `.pck`); Unreal needs a file under `Binaries/Linux` whose name contains `server` or ends in `-linux-shipping`. A Windows `.exe` build always fails here.
- `detect executable: package.json not found` (Colyseus/Node): ship `package.json` and `package-lock.json` at the archive root; the template runs `npm ci` then `npx tsx src/index.ts`.
- A custom `Dockerfile` is used only when it sits at the **archive root** (any case). Zipping the parent folder hides it, and GameFlow falls back to the engine template.
- Anything else (Dockerfile step failed, missing library): `GET /v1/images/builds/{buildId}/logs` returns `{steps:[{name, completed, error, logs}]}`; read the step with `error: true`. `build logs not available: no depot build ID found` means it failed before the image build started, so `message` is all there is.
- The same `version` twice is not an error: the second build gets a prefixed id. Use the returned `buildId`, not the version.

## Server never Ready

A server counts as Ready only after the process calls the SDK's `ready()`.

1. Find the server: `GET /v1/games/{gameId}/servers?sort=latest` → `servers[].name`, `state`, `region`, `historical`.
2. Read its output: running → `.../logs/download?region=`; gone (start timeouts delete the server) → `.../logs/history`.
3. Read `.../events?region=`: `BackOff`, `Failed`, `OOMKilled`-style reasons and image pull errors show here. Commands are in [references/diagnostics-api.md](references/diagnostics-api.md).

Common causes:
- `ready()` never called, or called before the socket listens. Call it after `listen` succeeds.
- The SDK fails with `SIDECAR_UNAVAILABLE`: `GAMEFLOW_SDK_MODE=local` forced in the game's env vars, or a network sandbox. Remove the override.
- The process exits (missing library, wrong launch options, crash on a missing env var). Logs show it.
- Out of memory/CPU: `.../metrics` near the configured `config.memory`/`config.vcpu`. Raise them in the game config.
- Server becomes Ready then disappears: zero reported players past the org idle timeout (track players with `players.connect`), or `shutdown()` called too early.

## Players can't connect

First confirm the server is `Ready` or `Allocated` in server details. Then check, in order:

1. **Port:** the client uses the **returned** public `port` (allocation, server details, or the ticket's `connection`), not the configured 7777. Inside the container the server listens on `GAMEFLOW_DEFAULT_PORT` on `0.0.0.0`.
2. **Host:** the client uses `host`. For TLS games that's a `*.server.gameflow.gg` hostname; TLS to the raw IP fails the certificate check.
3. **Protocol:** the game config's `UDP`/`TCP`/`TLS` matches the networking library (UDP transport vs TCP/WebSocket). For `TLS` the server speaks plain TCP/`ws://` and GameFlow terminates TLS; the client uses TLS/`wss://`.
4. **Named ports:** extra ports are `GAMEFLOW_<NAME>_PORT` in the server and `ports[]` (by `name`) for the client.
5. **Network:** UDP blocked on the player's network *(inferred)*: try another network.

Details and a "works locally, fails deployed" checklist: [references/connectivity.md](references/connectivity.md).

## Allocate fails

`POST /v1/fleets/{gameId}/allocate` only claims an **already Ready** server; it never starts one.

- `no available game servers in fleet ...` (429): check `fleetConfig.scalingStrategy` is `intelligent-autoscaling`, the region is in `config.regions`, and `GET .../servers` shows `Ready` servers in that region. Zero Ready servers plus crash-looping ones means fix the server first; all `Allocated` means raise `bufferSize`/`maxReplicas`.
- Retry 429 with backoff a few times; a buffer refills as servers shut down.
- No autoscaling on the plan? Use `POST /v1/games/{gameId}/servers` (cold start, blocks up to ~120 s) instead.

## Ticket stuck pending

`pending` from `GET /v1/matchmaking/tickets/{ticketId}/status` only means "no assignment within `timeoutSeconds`". Check in order:

1. **Enough tickets?** A 2v2 needs 4 compatible tickets in the same queue. Test with enough concurrent players or scripted tickets on a staging game.
2. **Same queue?** Every ticket must use the same `gameId` and exactly the same `gameMode` (case-sensitive) as the published Ticket Input. A ticket for another game sits in another queue.
3. **Rules too strict?** Region, skill-window, Bucket/Split/tag rules split the pool. Loosen or add expansion over time in the matchmaker.
4. **`preferredAz` valid?** It picks the server region. A region not in the game's `config.regions` makes provisioning fail every cycle, so the match never gets a server *(inferred: the director skips the match and retries)*. Send only region ids from `GET /v1/regions/available` that the game lists.
5. **Can a server be provisioned?** With autoscaling, the fleet must have Ready servers in that region; without it, each match cold-starts a server (up to ~120 s) and inherits every [Server never Ready](#server-never-ready) problem. Check `GET .../servers`.
6. **Polling right?** Long-poll in a loop with `timeoutSeconds` ≤ 30 and an HTTP timeout above it. Cancel (`DELETE ...?playerId=`) when players leave, or stale tickets get matched with live ones.

## Payload empty

- `GAMEFLOW_PAYLOAD` is an **annotation**, not an env var on GameFlow: `getenv` returns nothing in production. Use the SDK (`gf.payload()` and `gf.onPayloadChange(...)`, or the engine equivalent).
- Fleet servers boot and become Ready **before** a match is assigned, so the payload is empty at startup and arrives on allocation. Subscribe to the change event; don't read once in `main`.
- Locally the SDK runs in local mode; set `GAMEFLOW_PAYLOAD='{"match_id":"test"}'` to simulate it.
- Manual `/allocate` or start: the payload is exactly the `payload` string your backend sent. Empty there means empty here.
- Matchmade payload JSON is snake_case (`match_id`, `teams[].players[].player_id`), unlike the REST API.

## Ratings not updating

1. Check the report call's response, not just that it was called. `POST /v1/skill-rating/matches:report` returns the new `ratings`; log the error body when it fails.
2. `no skill model is configured for game <id> mode <mode>; select a skill model on the Ticket Input node of the live matchmaker and publish`: attach a model and **publish** again.
3. `skill model <id> is paused; resume it to record ratings` / `model has no active season`: fix in the dashboard.
4. `ranks must have one entry per team`, `at least two teams are required`, `team N has no players`: fix the body. `ranks` is parallel to `teams` and **lower is better** (0 = winner). Inverted ranks make winners lose rating.
5. Same `externalPlayerId` everywhere: the ticket's `playerId` must equal the report's `externalPlayerId`, or the update lands on a different player.
6. Verify: `POST /v1/skill-rating/player-rating:resolve {gameId, gameMode, externalPlayerId}` → `rating.matchesCount` should grow.
7. Don't retry a report blindly after a timeout: nothing dedupes on `externalMatchId`, so a second success rates the match twice *(inferred from the schema)*.

## When to escalate

Escalate to GameFlow (Discord or the dashboard's support form) when the error is `code` 13/14 (`Internal`/`Unavailable`) and persists after retries with backoff, a build stays `queued` for over 30 minutes, or a check above contradicts what the platform does. Send:

- Time (UTC) and region; the endpoint and method; the full error body.
- `gameId`, `gameMode`, `buildId`, `serverName`, `ticketId` or `matchId` as relevant.
- The [scripts/diagnose.sh](scripts/diagnose.sh) output and relevant server log lines.
- **Never the API key**, nor a `curl` command that contains it. Replace it with `$GAMEFLOW_API_KEY`.

## References

- [references/error-catalog.md](references/error-catalog.md): real error messages by area with cause and fix
- [references/diagnostics-api.md](references/diagnostics-api.md): servers, logs (stream/history/download), events, metrics, builds
- [references/connectivity.md](references/connectivity.md): protocols, ports, env vars, TLS hosts, local vs deployed, regions
- [../gameflow/references/api-conventions.md](../gameflow/references/api-conventions.md): auth, casing, HTTP/gRPC code table, retries
