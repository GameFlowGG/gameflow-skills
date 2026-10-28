---
name: gameflow-servers
description: Host your game's dedicated servers on GameFlow (gameflow.gg). Walks through adding the GameFlow Game Server SDK to a Unity, Unreal, Godot, Node/TypeScript (Colyseus), Go or Rust/Bevy server, packaging the Linux build, uploading it from the CLI, GitHub Actions or the REST API, and getting players connected to a running server's host and port. Use it to deploy a server build, set up CI uploads, start a test server, allocate servers from an autoscaled fleet, configure ports or TLS/WSS, track connected players, find out why idle servers shut down, or move off a self-managed Kubernetes setup.
license: MIT
metadata:
  author: GameFlow
  version: "0.1.0"
---

# GameFlow dedicated servers

You ship a Linux server build. GameFlow builds it into an image, runs it in your regions, autoscales it and hands players a `host:port`. Your server process talks to the platform only through the **GameFlow Game Server SDK**.

Account, API key and CLI setup live in the `gameflow` skill. The essentials, repeated here:
- API base `https://api.gameflow.gg/v1`, header `x-api-key: $GAMEFLOW_API_KEY`.
- Write **lowerCamelCase** JSON. Unknown or misspelled request fields are **silently dropped**, not rejected.
- Responses are camelCase and always include zero values. int64 fields come back as **strings**.
- **The key never goes into a game client.** Only your backend, CI, and (if it calls the API) the dedicated server hold it.
- Don't invent endpoints, CLI flags or SDK methods. If it isn't here or in the references, say "verify in the docs or API reference".
- If the GameFlow docs MCP is connected, check each request body against `get_api_operation` before writing it. If a field name differs from this skill, **don't choose yourself or write code with either name**. The docs can be ahead of the deployed API, and the wrong name is silently dropped. Show the user both names and ask which one their environment accepts.

## 0. Prerequisites

1. You're authenticated. With the CLI, `gameflow login` then `gameflow whoami`. With an API key: `curl -sS https://api.gameflow.gg/v1/identity/me -H "x-api-key: $GAMEFLOW_API_KEY"` returns `{user, organization, isOwner}`. If not, use the `gameflow` skill.
2. A game exists. Create it with `gameflow games create --title <t> --engine <e> --port <p> --protocol UDP --region us-east` (more flags in the `gameflow` skill's CLI reference), or give the user this checklist (app.gameflow.gg → Games → Create Game). Fleet scaling and extra ports are dashboard-only. The values to decide are:
   - **Engine**: Unity, Unreal, Godot, Colyseus (Node) or Custom. For Godot, set the **engine version** to the exact editor version you export with (e.g. `4.4.1`).
   - **Port + protocol**: the port your server listens on *inside* the container (e.g. `7777`) and UDP, TCP or TLS. TLS = platform-terminated TLS for WebSocket/browser games. Add named extra ports if needed.
   - **Regions**: pick from what `GET /v1/regions/available` returns (currently `us-east`, `eu-central`).
   - **Max players per server**: set it to more than 0, or player tracking is disabled and idle servers can be reaped.
   - **CPU/memory**, **environment variables** (put secrets such as `GAMEFLOW_API_KEY` here only if the server calls the API), optional **launch options**.
   - **Scaling**: enable **Intelligent Autoscaling** (min/max/buffer) if you want `/allocate` or matchmaking. Without it you can only start servers one at a time.
3. Get the `gameId`. The list wraps each game:
   ```bash
   curl -sS "https://api.gameflow.gg/v1/games?pageSize=50" -H "x-api-key: $GAMEFLOW_API_KEY" \
     | jq '.games[] | {id: .game.id, title: .game.title, engine: .game.engine, live}'
   ```
   `GET /v1/games/{gameId}` is double-wrapped: `{game: {game: {id, engine, config, fleetConfig, offline, …}, live, serversCount, playersCount}}`. Read ports, protocol, regions and max players from `.game.game.config`. Recommend a separate "MyGame (staging)" game for testing. There is no sandbox.

## 1. Integrate the SDK in the server

**Detect the stack** before writing code:

| Signal in the repo | Stack | Reference |
|---|---|---|
| `ProjectSettings/`, `Assets/`, `Packages/manifest.json` | Unity 2022.3+ | [references/sdk-unity.md](references/sdk-unity.md) |
| `*.uproject`, `Source/*.Build.cs` | Unreal 5.3+ | [references/sdk-unreal.md](references/sdk-unreal.md) |
| `project.godot` | Godot 4.4+ | [references/sdk-godot.md](references/sdk-godot.md) |
| `package.json` (Colyseus, ws, socket.io, net) | Node ≥ 18.17 | [references/sdk-typescript.md](references/sdk-typescript.md) |
| `go.mod` | Go 1.23+ | [references/sdk-go.md](references/sdk-go.md) |
| `Cargo.toml` (tokio, Bevy) | Rust | [references/sdk-rust.md](references/sdk-rust.md) |

Integrate only in the **server** build (dedicated-server target, headless mode, `HasAuthority()`), never in the shipped client.

**Lifecycle every integration must have:**
1. **Connect** at startup (`GameFlow.connect()` / `start()` / `Start()`). On GameFlow it retries for up to 30 s, then fails hard. Off-platform it enters **local mode** automatically.
2. **Listen on the platform port**: `GAMEFLOW_DEFAULT_PORT`, read through the SDK port helper (`gf.ports.default` etc.). Bind `0.0.0.0`, not `127.0.0.1`. Keep a local fallback such as 7777; never hard-code the port as the only option.
3. **Ready** only once the listener accepts connections. Health heartbeats then start automatically; never ping by hand.
4. **Track players**: connect/track on join and disconnect/untrack on leave, with a stable id. Handle `SERVER_FULL` (reject) and `PLAYER_ALREADY_CONNECTED` (reconnect). Servers that report zero players past the org's idle timeout are shut down.
5. **Payload**: read it once via the SDK **and** subscribe to payload changes. On fleet servers it arrives at allocation, after Ready. Never `getenv("GAMEFLOW_PAYLOAD")`: in production it is an annotation, and the env var only simulates it locally. See [references/env-and-payload.md](references/env-and-payload.md).
6. **Shutdown** when the match/session ends **and** on SIGTERM (the platform force-kills about 45 s after SIGTERM). Then exit the process. The fleet replaces the server.

Run it locally with no platform: `GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=8 GAMEFLOW_PAYLOAD='{"match_id":"local-1"}'` plus your start command. Expect one log line saying local mode.

## 2. Package the build

The archive must be a Linux server build. Use `.zip`, `.tar` or `.tar.gz` (Godot can also upload a bare `.pck`). Avoid a bare `.gz`: the upload accepts it but the builder can't extract it.

- **No `Dockerfile` at the archive root:** GameFlow uses its managed template for the game's engine. It finds the executable by name and runs it as non-root UID 1000.
- **`Dockerfile` at the archive root** (any case): it is used as is. Required for Go, Rust, custom engines, plain Node that isn't `src/index.ts`, and any build that needs extra args or libraries.

Quick rules per engine (details and Dockerfiles in [references/build-packaging.md](references/build-packaging.md)):
- **Unity**: the Linux Dedicated Server build folder contents with the `*.x86_64` file, `*_Data/`, `UnityPlayer.so` (and `GameAssembly.so` for IL2CPP). The template runs `-batchmode -nographics -logFile /dev/stdout`.
- **Godot**: the exported `.pck` (the template runs `godot --headless --main-pack <pck> --server` with the game's engine version).
- **Unreal**: the packaged `LinuxServer` output. The executable must be under `Binaries/Linux/` with `Server` in its name or ending `-Linux-Shipping`. Prefer your own Dockerfile so you control args and the port.
- **Colyseus/Node**: `package.json` + `package-lock.json` + `src/index.ts`; the template runs `npx tsx src/index.ts`.

Size: up to 100 MB uses one presigned PUT. Above that, use multipart (the CLI handles both).

## 3. Upload and build

Preferred: the CLI (install in the `gameflow` skill):
```bash
gameflow builds create --game-id "$GAMEFLOW_GAME_ID" --file ./dist/server.zip --version "$(git rev-parse --short HEAD)"
```
It uses the `gameflow login` session or `GAMEFLOW_API_KEY` (CI), uploads single or multipart, and **waits for the build to finish** (exit code `6` if it fails), so there's nothing to poll afterwards. `gameflow games list` shows the game ids. Other commands (`builds status`, `servers logs --tail`, `servers stop --dry-run`) are in the `gameflow` skill's CLI reference.

CI: `GameFlowGG/gameflow-deploy-action@v1` (inputs `api-key`, `game-id`, `file`, `version`; output `build-id`).

REST (no CLI): run [scripts/upload-build.sh](scripts/upload-build.sh), or follow [references/upload-and-builds.md](references/upload-and-builds.md):
- **≤ 100 MB:** `POST /v1/images/generate-upload-url` → `PUT uploadUrl` → `POST /v1/images/start-build`. The upload alone does not build.
- **> 100 MB:** `multipart/create` → per part `multipart/part-url` + `PUT` (keep each `ETag`) → `multipart/complete`. Complete starts the build itself, so don't call start-build again.
- **Poll** (REST only) `GET /v1/images/builds/{buildId}` every ~10 s until `status` is `success` or `failed`. On failure read `message` and `GET /v1/images/builds/{buildId}/logs`.

New builds are **not** made current automatically. When the game has no current build, the latest successful build is used. Otherwise the user promotes the build in the dashboard (Game → Builds; promote and rollback are dashboard-only), which rolls the fleet. To test a build before promoting it, start a server with `buildId`.

## 4. Run and test

**Start a test server** (cold start; the call blocks until Ready, up to ~120 s, so set the client timeout above 120 s):
```bash
curl -sS -m 150 -X POST "https://api.gameflow.gg/v1/games/$GAMEFLOW_GAME_ID/servers" \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"region":"us-east","payload":"{\"mode\":\"test\"}"}'
```
Or use [scripts/start-test-server.sh](scripts/start-test-server.sh). Pass `"buildId"` to test a build that isn't current. `/servers/launch` takes the same body and returns at once; poll the details.

**Allocate from the fleet** (fast; needs Intelligent Autoscaling and a Ready server in that region):
```bash
curl -sS -X POST "https://api.gameflow.gg/v1/fleets/$GAMEFLOW_GAME_ID/allocate" \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"region":"us-east","payload":"{\"lobbyId\":\"abc\"}"}'
# → {"allocation":{"host":"…","address":"…","port":7XXX,"serverName":"…","ports":[{"name":"default","port":7XXX,"protocol":"udp"}]}}
```
A 429 (`RESOURCE_EXHAUSTED`) means no Ready server is free: retry with backoff, raise the buffer, or fall back to starting one.

**Connecting:**
- Clients connect to **`host`** and the **external** `port` (or `ports[]` by name), never to `GAMEFLOW_DEFAULT_PORT`, which is the container port.
- For UDP/TCP, `host` equals `address` (an IP).
- For TLS games, `host` is a hostname such as `203-0-113-42.server.gameflow.gg`. Connect with TLS (`wss://host:port`). Your server listens in plaintext on `GAMEFLOW_DEFAULT_PORT` and the platform terminates TLS in front of it.

Inspect with `GET /v1/games/{gameId}/servers/{serverName}?region=…` (state, playerCount, connectedPlayers, host, ports), `/logs/history`, `/events`. Stop with `DELETE …/servers/{serverName}?region=…`. Full reference: [references/servers-api.md](references/servers-api.md).

## 5. Production wiring

- **Who calls allocate/start:** the customer's **backend**, with the key, after authenticating the player. The client asks the backend and gets back only `host:port`. For matchmade games GameFlow allocates for you; use the `gameflow-matchmaking` skill.
- **Region choice:** the client calls `GET /v1/ping/regions` (no auth), measures latency to each `endpoint`, and sends the best `name` to the backend, which passes it as `region`.
  - **Browser games:** the API's CORS blocks other origins, so the backend must fetch the region list and pass it to the page.
  - The region must be one of the game's configured regions.
- **Payload:** the backend passes match/lobby data as the `payload` string. The server reads it via the SDK, **validates every joining player against it** and rejects strangers. Matchmade payloads are snake_case (`match_id`, `teams[].players[].player_id`).
- **Analytics and ratings:** a server that calls `matches:start` / `matches:end` / `skill-rating/matches:report` needs `GAMEFLOW_API_KEY` as a game env var. See the `gameflow-matchmaking` and `gameflow-skill-rating` skills.
- **Ending:** call SDK Shutdown and exit. Don't keep finished servers idling. Use `DELETE …/servers/{serverName}?region=` only for servers you need to kill from outside.

## 6. Verification checklist

- [ ] SDK used only in the server target; no API key in any client code or client build config.
- [ ] The server listens on `0.0.0.0:<GAMEFLOW_DEFAULT_PORT>` (SDK port helper), with a local fallback.
- [ ] Ready is called after the listener is up, exactly once, and never ahead of real readiness.
- [ ] Every join calls connect/track and every leave calls disconnect/untrack; `SERVER_FULL` is handled; Max players > 0 in the game config.
- [ ] Payload is read via the SDK **and** a change listener; no `getenv("GAMEFLOW_PAYLOAD")` outside local simulation.
- [ ] Shutdown is called on match end and on SIGTERM (under 45 s), then the process exits.
- [ ] Local run works in local mode with the simulated env vars.
- [ ] The archive is `.zip`/`.tar`/`.tar.gz`/`.pck`; Linux binaries; a Dockerfile at the root if not using a managed template.
- [ ] The build reaches `success`; the user promoted it if a current build already existed.
- [ ] A test server reaches Ready, a client connects to `host:port`, and its player appears in `connectedPlayers`.
- [ ] The backend (not the client) calls allocate/start with a measured region.

## References

- [references/sdk-typescript.md](references/sdk-typescript.md), [sdk-unity.md](references/sdk-unity.md), [sdk-unreal.md](references/sdk-unreal.md), [sdk-godot.md](references/sdk-godot.md), [sdk-go.md](references/sdk-go.md), [sdk-rust.md](references/sdk-rust.md): install + lifecycle per language
- [references/build-packaging.md](references/build-packaging.md): archive contents per engine, custom Dockerfiles
- [references/upload-and-builds.md](references/upload-and-builds.md): CLI, GitHub Actions, REST single/multipart, polling
- [references/servers-api.md](references/servers-api.md): start, launch, allocate, list, details, logs, events, metrics, stop
- [references/env-and-payload.md](references/env-and-payload.md): env vars, payload shape, local simulation, trusting the payload
- [scripts/upload-build.sh](scripts/upload-build.sh), [scripts/start-test-server.sh](scripts/start-test-server.sh)
