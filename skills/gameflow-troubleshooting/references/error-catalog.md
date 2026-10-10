# GameFlow error catalog

Real `message` strings returned by the GameFlow API, grouped by area. `%s`/`%d`/`%v` mark values filled in at runtime. The HTTP status follows the gRPC code (table in [api-conventions.md](../../gameflow/references/api-conventions.md#errors)): InvalidArgument and FailedPrecondition → 400, Unauthenticated → 401, PermissionDenied → 403, NotFound → 404, AlreadyExists → 409, ResourceExhausted → 429, Internal → 500, Unimplemented → 501, Unavailable → 503, DeadlineExceeded → 504.

**Field names in messages are snake_case** (`game_id is required`) because they come from the proto definitions. In JSON send the camelCase name (`gameId`). The gateway also accepts the exact snake_case name, but any other spelling (`gameID`, `GameId`) is silently dropped, which produces these "is required" errors.

Causes marked *(inferred)* are read from the platform code, not documented.

## Authentication and roles

| Message | Code | Cause | Fix |
|---|---|---|---|
| `access token not present in metadata` | 401 | No `x-api-key` header (or empty) | Send the header from server-side env |
| `invalid API key` | 401 | Wrong, expired, rotated or revoked key (same message for all) | Create or rotate a key in Settings → API Keys |
| `access token has expired` | 401 | Dashboard session/JWT expired (not an API-key problem) | Sign in again; scripts should use an API key |
| `account no longer exists` | 401 | The key's creator was deleted | Create a new key from an existing member |
| `insufficient permissions` | 403 | Creator's role is below the method's minimum (writes need Engineer; billing/org admin needs Admin) | Raise the role or use another member's key |
| `account suspended` | 403 | Account banned/suspended | Contact GameFlow support |
| `this endpoint requires session authentication` | 403 | Key used on a dashboard-only method: API keys, org members/invites, billing, email change, data export, support tickets | Do it in the dashboard |
| `user not authorized to access game` | 403 | `gameId` belongs to another organization | Use the right key or game id |
| `user must belong to an organization` | 403 | Key's user has no org | Recreate the key from an org member |

## Games and regions

| Message | Code | Cause | Fix |
|---|---|---|---|
| `game %s not found` / `game not found` | 404 | Wrong or deleted id; title used as id | `GET /v1/games` → `games[].game.id` |
| `game not found or does not belong to your organization` | 404 | Upload/build for another org's or a missing game | Check `gameId` |
| `region %q is not configured for game %s (available: %v)` | 400 | Start/allocate in a region the game doesn't list (no regions configured means `us-east` only) | Use one of `available`, or add the region in the game config |
| `region is required` | 400 | Missing `region` in body (start/allocate) or query (details/logs/events/metrics/stop) | Pass `region` |
| `unsupported region: %s` | 400 | Region id the platform doesn't run | `GET /v1/regions/available` |

## Builds and uploads

| Message | Code | Cause | Fix |
|---|---|---|---|
| `file extension not allowed. Allowed extensions: .zip, .tar, .tar.gz, .gz, .pck` | 400 | Other archive type (`.7z`, `.rar`, `.tgz`) | Repack as `.zip` or `.tar.gz` |
| `file_size must be greater than 0` / `file_size exceeds maximum allowed size` | 400 | `fileSize` missing/0, or too big for single PUT (100 MB) | Send the byte size; use multipart above 100 MB |
| `s3_path is required` / `upload_id is required` / `parts are required` / `invalid part entry` / `part_number must be greater than 0` | 400 | Incomplete multipart/start-build body | Pass `s3Path`, `uploadId`, `parts:[{partNumber, etag}]` from earlier responses |
| `invalid s3_path: does not belong to your organization` | 403 | `s3Path` not from your own upload-url call | Use the `s3Path` returned to you |
| `build not found` | 404 | Wrong `buildId` (use the returned id, not the version) | `GET /v1/images/builds?gameId=` |
| `build logs not available: no depot build ID found` | 404 | Build failed before the image build started (or is still queued) | Read `message` from the build status instead |
| `build is not in a successful state` / `build %s is not in a successful state` | 400 | Promoting or starting a server on a failed/running build | Use a `success` build |
| `no successful build found, please build first` | 400 | Starting a server with no successful build | Upload and wait for `success` |
| `build %s not found for game %s` | 404 | `buildId` passed to start belongs to another game | Pick a build from that game |
| `cannot delete the current build; promote another build first` | 400 | Deleting the current build | Promote another first (dashboard) |
| `invalid page_token` | 400 | Stale or hand-built page token | Use `nextPageToken` as returned |

**Build status `message` values** (from `GET /v1/images/builds/{buildId}`): `queued`, `building image`, `build completed`, or `build failed: <cause>`. Causes seen in the build pipeline:

| `build failed: ...` | Cause | Fix |
|---|---|---|
| `unsupported artifact type: %s` | Archive the extractor can't open; a bare `.gz` passes upload but lands here *(inferred)* | Use `.zip`, `.tar`, `.tar.gz` or `.pck` |
| `detect executable: executable not found` | No root Dockerfile and no Linux server binary (Unity/Godot `*.x86_64`/`*.x86` or Godot `.pck`; Unreal file under `Binaries/Linux` containing `server` or ending `-linux-shipping`) | Export a Linux dedicated-server build, or add a Dockerfile at the archive root |
| `detect executable: package.json not found` | Colyseus/Node archive without `package.json` | Put `package.json` + lockfile at the root |
| `detect executable: unsupported engine: %s` | Engine without a managed template (e.g. Custom) and no Dockerfile | Add a Dockerfile at the archive root |
| `invalid zip path: %s` / `invalid tar path: %s` | Archive entries with `..` or absolute paths | Re-create the archive from inside the build folder |

Uploading the same `version` twice is **not** rejected: the second build gets a prefixed id.

## Game servers and fleets

| Message | Code | Cause | Fix |
|---|---|---|---|
| `This game is offline for maintenance. Starting servers is disabled until it is brought back online.` | 400 | Game `offline: true` (start, launch, allocate, matchmaking) | Bring the game online in the dashboard |
| `no available game servers in fleet %s` | 429 | Allocate found no Ready server in that region: autoscaling not enabled for the game (no fleet) *(inferred)*, buffer exhausted, or servers fail before Ready | Enable Intelligent Autoscaling; raise buffer/max replicas; fix crashing servers; retry with backoff |
| `Intelligent Autoscaling is not included in your current plan` | 403 | Turning on autoscaling without the entitlement | Upgrade, or use standalone servers |
| `monthly server-hours cap reached (%d h) — upgrade to start more servers` | 429 | Free-tier hours cap | Upgrade or wait for the period reset |
| `monthly egress cap reached (%d GB) — upgrade to start more servers` | 429 | Free-tier egress cap | Upgrade or wait |
| `game server %s did not become ready within %d seconds` | 504 | Start (`POST .../servers`) waited 120 s without SDK `ready()`; the server is deleted | Logs history + events for that server name |
| `game server %s failed to start (state: %s)` | 500 | Server went `Unhealthy`, `Error` or `Shutdown` while starting | Crash on boot, no health heartbeats, or early `shutdown()`; read logs |
| `request canceled while waiting for game server %s to become ready` | 499 | Your HTTP client gave up before 120 s; the server keeps starting | Set the client timeout above 120 s, or use `/servers/launch` and poll |
| `TLS protocol requested but no TLS hostname domain is configured` | 400 | Platform-side TLS config missing | Escalate to GameFlow |
| `too many launch args: %d (max %d)` / `launch arg %d exceeds max length of %d` / `launch arg %d contains a control character` | 400 | Invalid `launchArgs` | Shorten/clean them |
| `game server not found` / `game server %s not found for game %s` / `game server %s not found` | 404 | Wrong `serverName`, wrong `region`, other game, or the server already exited | List servers; use `logs/history` for exited ones |
| `historical server %s not found for game %s` | 404 | No history row for that name in that game | Check name and `gameId` |
| `server_name must be alphanumeric` | 400 | Metrics call with a malformed server name | Use `servers[].name` as returned |
| `end must be after start` / `end_time must be after start_time` / `invalid start: %v` / `invalid end: %v` | 400 | Bad RFC 3339 time window | Fix `start`/`end` (`startTime`/`endTime` for metrics) |
| `invalid cursor format: %v` | 400 | Hand-built cursor | Use `nextCursor` as returned |
| `no fleet found for game %s in any region` | 404 | Changing a fleet build on a game with no fleet | Enable autoscaling first |

## Matchmaking tickets

| Message | Code | Cause | Fix |
|---|---|---|---|
| `player_id is required` / `game_id is required` / `game_mode is required` | 400 | Field missing or misspelled (`playerId`, `gameId`, `gameMode`) | Fix the JSON |
| `no matchmaker is currently loaded for game_id=%q game_mode=%q; if it is published and Live, retry shortly` | 400 | No published Live matchmaker for that exact pair, a `gameMode` typo/case mismatch, or a brief reload after a platform restart | Publish; copy `gameMode` from the Ticket Input; retry once after a few seconds |
| `unknown attribute %q; declare it on the matchmaker's ticket input node` | 400 | `attributes` key not declared | Declare it, or drop it from the ticket |
| `attribute %q must be a string` / `... must be a number` / `... must be a boolean` | 400 | JSON type mismatch (`"5"` vs `5`) | Send the declared type; only scalars are allowed |
| `attribute %q has unsupported declared type %q` | 400 | Matchmaker declares an unsupported type | Fix the attribute type in the matchmaker |
| `sigma must be greater than 0` | 400 | Skill-matched queue, player has no stored rating, no positive `sigma` sent | Attach a skill model, or send a starting `mu`/`sigma` |
| `unable to verify matchmaker availability` / `unable to resolve player rating` / `resolve player rating: %v` / `create ticket: %v` | 503 | Transient platform failure | Retry with backoff; escalate if persistent |
| `ticket_id is required` | 400 | Empty ticket id in path | Pass the `ticketId` from create |
| `ticket not found` | 404 | Cancel: ticket already matched/removed, or `playerId` isn't the owner (same message on purpose) | Treat as done; pass the creator's `playerId` |
| `watch assignment: %v` | 503 | Status long-poll failed; an unknown or expired `ticketId` may surface this way *(inferred)* | Check the id; retry with backoff |

Status responses: create returns `status: "queued"`; status returns `"pending"` (no assignment within `timeoutSeconds`) or `"assigned"` with `connection: "host:port"`.

## Match lifecycle (matches:start / matches:end)

| Message | Code | Cause | Fix |
|---|---|---|---|
| `match_id is required` / `game_id is required` | 400 | Missing `matchId`/`gameId` | Use `match_id` from the payload as `matchId` |
| `no match %s for game %s` | 404 | `matchId` not formed by GameFlow matchmaking for that game (manual allocations have none) | Only call for matchmade matches; check `gameId` |
| `result is required and must be SUCCESS, FAILURE or CANCELED` | 400 | Missing/invalid `result` | `"MATCH_RESULT_V1_SUCCESS"` etc. |
| `match history is not configured` | 503 | Platform-side | Escalate if persistent |

## Skill rating

| Message | Code | Cause | Fix |
|---|---|---|---|
| `game_id is required` / `game_mode is required` | 400 | Missing fields in report/resolve | Fix the body |
| `at least two teams are required` | 400 | One team (or none) reported | Report every team, including losers |
| `ranks must have one entry per team` | 400 | `ranks` length ≠ `teams` length | One rank per team, lower is better |
| `team %d has no players` | 400 | Empty team | Remove it or add its players |
| `player external_player_id is required` / `external_player_id is required` | 400 | Missing `externalPlayerId` | Send the same id used as the ticket `playerId` |
| `no skill model is configured for game %s mode %s; select a skill model on the Ticket Input node of the live matchmaker and publish` | 400 | No live matchmaker with a model for that `(gameId, gameMode)` | Attach a model in Ticket Input and publish |
| `skill model %s is paused; resume it to record ratings` | 400 | Model paused | Resume it in the dashboard |
| `model has no active season` | 400 | Season ended, none active | Start a season |
| `skill model not found` / `season not found` | 404 | Wrong model/season id, or another org's | List models/seasons |
| `matchmaking service unavailable; cannot resolve skill model` / `resolve skill model: %v` | 503 | Transient | Retry with backoff (see the double-count note in SKILL.md) |
| `skill rating compute timed out` | 504 | Rating compute slow | Retry carefully; escalate if persistent |
