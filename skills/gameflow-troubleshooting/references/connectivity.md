# Connectivity: why players can't reach the server

Players connect **directly** to the dedicated server at a `host` and `port` that GameFlow returns. Most "can't connect" bugs are one of: wrong port, wrong host, wrong protocol, or a server not listening where GameFlow routes traffic.

## The two ports

| Port | Who uses it | Where it comes from |
|---|---|---|
| **Container port** | The game server process listens on it | `GAMEFLOW_DEFAULT_PORT` (and `GAMEFLOW_<NAME>_PORT`), equal to the game's configured port (7777 if none) |
| **Public port** | Players connect to it | `port` / `ports[]` in the allocate, start or server-details response, or the `:port` in a ticket's `connection` |

They are usually **different numbers**: GameFlow publishes each server on its own public port and forwards it to the container port. So:

- The server must listen on `GAMEFLOW_DEFAULT_PORT` (read it via the SDK, e.g. `gf.ports.default`), not a hard-coded value that differs from the game config.
- The client must connect to the **returned** port, never the configured 7777.
- Listen on all interfaces (`0.0.0.0`), not `127.0.0.1`/`localhost`, or forwarded traffic never arrives.

Additional ports: a port labeled `voice chat` becomes `GAMEFLOW_VOICE_CHAT_PORT` inside the server; clients find its public number in `ports[]` by `name`.

## Protocol must match on all three sides

| Game config protocol | Server listens with | Client connects with | Notes |
|---|---|---|---|
| `UDP` (default) | UDP socket (ENet, Unity Transport, Godot ENet, Mirror KCP, ...) | UDP to `host:port` | A TCP/WebSocket client never connects |
| `TCP` | TCP socket / plain WebSocket (`ws://`) | TCP to `host:port` | |
| `TLS` | **Plain** TCP / `ws://` on `GAMEFLOW_DEFAULT_PORT` | TLS / `wss://` to `host:port` | GameFlow terminates TLS in a sidecar and forwards plaintext. Don't terminate TLS in your server |

Mismatches look like silent timeouts. Compare `config.protocol` from `GET /v1/games/{gameId}` with your networking library's transport, and `ports[].protocol` in the allocation.

An empty or unknown protocol in the game config is treated as UDP.

## host vs address

- `address` is the server's IP.
- `host` is what clients should use. For UDP/TCP it equals the IP. For TLS it is a hostname like `203-0-113-42.server.gameflow.gg`, matching the wildcard certificate.
- Connecting with TLS to the **IP** fails certificate validation. Browsers then refuse the `wss://` connection, usually with a generic error. Always use `host`.
- Browser games served over `https://` can't open `ws://` (mixed content): set the game protocol to TLS and use `wss://host:port`.

## Matchmaking `connection`

The ticket status returns `connection: "host:port"`. Split on the **last** `:`. The backend forwards it to the client; the client connects with the game's protocol. If the TLS host is needed, it is already in `connection`.

## Firewalls and networks (inferred)

- Corporate, school and some mobile networks block outbound UDP on high ports. If TCP/TLS works and UDP doesn't from the same machine, it's the network.
- Test from a second network (phone hotspot) before blaming the server.
- `nc -vzu <host> <port>` can't prove UDP reachability (UDP has no handshake); use your game client or a small UDP echo test against your server.

## Local testing vs deployed

| | Local (your machine) | Deployed on GameFlow |
|---|---|---|
| SDK mode | `local` (auto-detected): `ready()`, health, shutdown are no-ops | Connected to the platform; fails hard with `SIDECAR_UNAVAILABLE` if it can't reach it |
| Port | Whatever you set: `GAMEFLOW_DEFAULT_PORT=7777 node server.js` | Injected; public port differs |
| Payload | `GAMEFLOW_PAYLOAD='{"match_id":"t1"}'` env var simulates it | Annotation read by the SDK; arrives on allocation (env var is empty) |
| Max players | `GAMEFLOW_MAX_PLAYERS=8` simulates capacity | From `config.maxPlayers` |
| TLS | None; use `ws://localhost` | Sidecar TLS on `host` |

"Works locally, fails deployed" checklist:
1. Linux build? (Windows/macOS binaries fail the build or crash.)
2. Listening on `0.0.0.0:$GAMEFLOW_DEFAULT_PORT`?
3. `ready()` called after listening? (Server must reach `Ready`; check `state` in server details.)
4. Client uses the returned `host` and public `port`, not `localhost:7777`?
5. Protocol in the game config equals the transport you use?
6. `GAMEFLOW_SDK_MODE=local` not left in the game's environment variables?

## Regions and ping

- Servers run only in regions listed in the game's `config.regions` and available on the platform: `GET /v1/regions/available` (auth), currently `us-east` and `eu-central`.
- Clients measure latency with `GET /v1/ping/regions` (no auth, safe from clients), which returns `[{name, endpoint}]`, then send the best region to your backend.
- The docs also list ping hosts for regions where servers are not available (e.g. US West, AP Southeast). A client that picks one of those and sends it as `preferredAz` or `region` gets `region "..." is not configured for game ...` on start/allocate, or tickets that never get a server *(inferred)*. Intersect the ping results with the game's `config.regions`.
- High ping with a correct region usually means the client is far from all available regions; matchmaking region rules then trade wait time for latency.
