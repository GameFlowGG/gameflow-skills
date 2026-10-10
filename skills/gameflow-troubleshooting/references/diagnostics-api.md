# GameFlow diagnostics API

Read-only endpoints for finding out what a game, build or server is doing. All need `x-api-key` (the Viewer role is enough). Base URL `https://api.gameflow.gg/v1`. Responses are camelCase; int64 values (`cpuUsageMillicores`, `memoryUsageBytes`, `originalFileSize`) come back as strings.

```bash
export API=https://api.gameflow.gg/v1
H="x-api-key: $GAMEFLOW_API_KEY"   # never echo $H or paste it anywhere
```

## Account and game config

```bash
curl -sS "$API/identity/me" -H "$H"
# {"user":{"id","email","globalname","organizationId","role"},"organization":{"id","name","autoscalingEnabled","ownerId"},"isOwner":true}

curl -sS "$API/games?pageSize=50" -H "$H"
# {"games":[{"game":{"id","title","engine","config",...},"live":true,"serversCount":2,"playersCount":5}]}

curl -sS "$API/games/$GAME_ID" -H "$H"
# Wrapped twice: {"game":{"game":{"id","title","engine","config":{...},"fleetConfig":{...},"offline":false},"live":true,"serversCount":2,"playersCount":5}}
# jq: .game.game.config

curl -sS "$API/regions/available" -H "$H"   # {"regions":["eu-central","us-east"]}
```

Fields of a game (inside `.game.game`) worth checking:

| Field | What to look for |
|---|---|
| `offline` | `true` blocks starting, allocating and matchmaking servers |
| `config.port`, `config.protocol` | Default port and protocol (`UDP`, `TCP` or `TLS`). Unknown/empty protocol means UDP; empty port means 7777 |
| `config.additionalPorts[]` | `{name, port, protocol}`; each becomes `GAMEFLOW_<NAME>_PORT` |
| `config.regions` | Regions servers may run in; empty means `us-east` only |
| `config.maxPlayers` | `0` disables player tracking (`players.connect` fails with `PLAYER_TRACKING_DISABLED`) |
| `config.vcpu`, `config.memory` | Compare with metrics when servers die under load |
| `config.environmentVariables`, `config.launchOptions` | Your own env vars and start arguments |
| `fleetConfig.scalingStrategy` | `intelligent-autoscaling` is required for `/allocate`; anything else means standalone servers |
| `fleetConfig.bufferSize`, `minReplicas`, `maxReplicas` | Too small a buffer means allocate returns 429 under load |

## Builds

```bash
# Recent builds (pageSize defaults to 15; paginate with pageToken → nextPageToken)
curl -sS "$API/images/builds?gameId=$GAME_ID&pageSize=10" -H "$H"
# {"builds":[{"buildId","gameId","engine","status","imageUri","createdAt","isCurrent","isPrevious","uploadSource","tags":[]}],
#  "nextPageToken":"", "currentBuild":{...}}

# One build: status is queued | running | success | failed
curl -sS "$API/images/builds/$BUILD_ID" -H "$H"
# {"status":"failed","message":"build failed: detect executable: executable not found","imageUri":""}

# Build steps and their log lines
curl -sS "$API/images/builds/$BUILD_ID/logs" -H "$H"
# {"steps":[{"name":"...","completed":true,"error":false,"logs":["..."]}]}
```

- `currentBuild` (or `isCurrent: true`) is what new servers run. A new `success` build is not current until promoted in the dashboard, unless no build is current yet.
- With `jq`: `jq '.steps[] | select(.error) | .logs[]'` shows only the failing step.

## Finding the serverName

Every per-server endpoint needs the server's `name` (the `serverName`) and, except history logs, its `region` as a query parameter.

- From an allocation: `allocation.serverName` in the `/allocate` response.
- From a start: `server.name` in the `POST .../servers` or `.../servers/launch` response.
- From matchmaking: no name is returned to the client. List the game's servers around the match time, or search by the address from `connection`.
- From the list:

```bash
curl -sS "$API/games/$GAME_ID/servers?limit=50&sort=latest" -H "$H"
# {"servers":[{"name","state","address","port","host","region","ports":[{"name","port","protocol"}],
#   "buildId","source","playerCount","playerCapacity","historical":false,"endedAt":...}],"nextCursor":"","hasMore":false}
```

`sort` is `latest` (default), `oldest`, `name` or `status`; `search` filters by name. Rows with `historical: true` have exited; use logs history for them. `GET /v1/servers` lists servers across all games.

Typical `state` values (from the underlying server lifecycle): `Scheduled`/`Creating`/`Starting` (booting), `RequestReady` → `Ready` (SDK `ready()` called), `Allocated` (claimed for a match), `Unhealthy`/`Error`/`Shutdown` (dying). A server stuck before `Ready` never called `ready()` or crashed.

## Server details

```bash
curl -sS "$API/games/$GAME_ID/servers/$SERVER?region=$REGION" -H "$H"
# {"name","state","address","port","host","ports":[...],"buildId","imageUri",
#  "cpuUsageMillicores":"120","memoryUsageBytes":"314572800","playerCount":2,"playerCapacity":8,"connectedPlayers":["p1","p2"]}
```

Check `buildId` (is it the build you expect?), `host` + `ports` (what clients must use), and `playerCount` (zero for long means the idle timeout will reap it).

## Logs

Three endpoints; all return stdout/stderr of the game server process.

```bash
# 1. Live stream of a running server (newline-delimited JSON; -N disables buffering; Ctrl+C to stop)
curl -sS -N "$API/games/$GAME_ID/servers/$SERVER/logs?region=$REGION" -H "$H"
# {"result":{"message":"[gameflow] ready","timestamp":"..."}}

# 2. Snapshot of a running server's logs as one string
curl -sS "$API/games/$GAME_ID/servers/$SERVER/logs/download?region=$REGION" -H "$H" | jq -r .content

# 3. Logs of a server that has exited (region optional; start/end RFC 3339; limit ≤ 5000)
curl -sS "$API/games/$GAME_ID/servers/$SERVER/logs/history?limit=5000" -H "$H" | jq -r .content
# {"serverName","entries":[{"timestamp","message"}],"content":"line1\nline2..."}
```

- A server deleted after the 120 s start timeout, or one that crashed, only has history logs.
- History is bounded by your plan's analytics retention (Free tier: about 24 h). An empty `entries` for an old server can just mean it aged out.
- Unity templates log to stdout (`-logFile /dev/stdout`). For other engines and custom Dockerfiles, make sure the server logs to stdout/stderr, not a file.

## Events

Platform events for the server and its container, newest first. Use them when logs are empty: the process never started, the image failed to pull, the container was killed for memory.

```bash
curl -sS "$API/games/$GAME_ID/servers/$SERVER/events?region=$REGION" -H "$H"
# {"events":[{"type":"Warning","reason":"BackOff","message":"Back-off restarting failed container ...",
#   "source":"kubelet","firstTimestamp","lastTimestamp","count":4}]}
```

Read `type: "Warning"` entries first. `BackOff`/`Failed` with a restart count means the process keeps crashing; a message about memory means raise `config.memory`.

## Metrics

CPU and memory time series; works for running and recently exited servers.

```bash
curl -sS "$API/games/$GAME_ID/servers/$SERVER/metrics?region=$REGION" -H "$H"
# optional: &startTime=2026-10-08T10:00:00Z&endTime=2026-10-08T11:00:00Z&stepSeconds=30
# {"cpuMillicores":[...],"memoryBytes":[...],"source":"prometheus","partial":false}
```

Default window is the last hour. Memory climbing to `config.memory` before a restart points to OOM; CPU pinned at `config.vcpu` points to tick-rate problems and lag.

## Stop and deletion status

Stopping is destructive (players are disconnected); ask before running it.

```bash
curl -sS -X DELETE "$API/games/$GAME_ID/servers/$SERVER?region=$REGION" -H "$H"
curl -sS "$API/games/$GAME_ID/servers/$SERVER/deletion-status?region=$REGION" -H "$H"
# {"status":"deleting","message":"...","progress":60}
```

The process gets SIGTERM and is force-killed about 45 s later; drain and call SDK `shutdown()` within that window.

## Matchmaking and ratings checks

```bash
# Long-poll one ticket (≤ 30 s); "pending" just means not matched yet
curl -sS "$API/matchmaking/tickets/$TICKET_ID/status?timeoutSeconds=10" -H "$H"

# Did ratings move?
curl -sS -X POST "$API/skill-rating/player-rating:resolve" -H "$H" -H "Content-Type: application/json" \
  -d '{"gameId":"'"$GAME_ID"'","gameMode":"ranked","externalPlayerId":"player-123"}'
# {"found":true,"skillModelId":"...","rating":{"mu":27.1,"sigma":7.9,"ordinal":3.4,"matchesCount":5,...}}
```
