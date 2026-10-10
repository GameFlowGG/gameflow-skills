# TypeScript / Node SDK

Package: `@gameflow.gg/gameserver-sdk` (stable, 0.1.x). Node ≥ 18.17, zero dependencies, ESM and CJS. Release tags in `GameFlowGG/gameflow-gameserver-sdk` are named `typescript-v<version>`.

```bash
npm install @gameflow.gg/gameserver-sdk
```

## API (real names)

| Member | Notes |
|---|---|
| `GameFlow.connect(options?)` | Retries for up to 30 s on GameFlow; local mode off-platform. Options: `mode: 'auto'\|'sidecar'\|'local'`, `healthIntervalMs`, `connectTimeoutMs`, `requestTimeoutMs`, `logger` (`null` silences it), `onHealthDegraded` |
| `gf.ready()` | Starts the health heartbeat automatically |
| `gf.shutdown()` | Idempotent; afterwards calls throw `NotConnectedError` |
| `gf.players.connect(id)` / `gf.players.disconnect(id)` | `disconnect` resolves `false` for unknown ids |
| `gf.players.count()` / `list()` / `capacity()` | Synchronous |
| `gf.payload()` | `Promise<string \| undefined>` |
| `gf.onPayloadChange(cb)` | Returns an unsubscribe function |
| `gf.watch(cb)` / `gf.info()` | Server info (state, address, ports, labels, annotations) |
| `gf.ports.default`, `gf.ports.get(name)`, `gf.ports.tls` | `number \| undefined` |
| `gf.region`, `gf.buildId`, `gf.mode` | `mode` is `'sidecar'` or `'local'` |

Errors extend `GameFlowError` and carry `.code`:
- `ServerFullError`
- `PlayerAlreadyConnectedError`
- `PlayerTrackingDisabledError`
- `SidecarUnavailableError`
- `NotConnectedError`
- `RequestFailedError`

## Minimal lifecycle (WebSocket server with `ws`)

```ts
import { WebSocketServer, type WebSocket } from "ws";
import { GameFlow, ServerFullError, PlayerAlreadyConnectedError } from "@gameflow.gg/gameserver-sdk";

type MatchPayload = { match_id: string; teams: { team_index: number; players: { player_id: string }[] }[] };

const gf = await GameFlow.connect();
console.log(`[server] mode=${gf.mode} region=${gf.region ?? "-"}`);

// 1. Payload: read once, then follow changes (fleet servers receive it on allocation).
let match: MatchPayload | null = null;
const applyPayload = (raw: string | undefined) => {
  match = raw ? (JSON.parse(raw) as MatchPayload) : null;
  if (match) console.log(`[server] assigned match ${match.match_id}`);
};
applyPayload(await gf.payload());
gf.onPayloadChange(applyPayload);

const allowed = (playerId: string) =>
  !!match?.teams.some((t) => t.players.some((p) => p.player_id === playerId));

// 2. Listen on the platform port (container port), all interfaces.
const port = gf.ports.default ?? 7777;
const wss = new WebSocketServer({ host: "0.0.0.0", port });
const sockets = new Set<WebSocket>();

wss.on("connection", async (ws, req) => {
  // Replace with your own token verification; never trust a bare client-sent id.
  const playerId = new URL(req.url ?? "/", "http://x").searchParams.get("playerId") ?? "";
  if (!allowed(playerId)) return ws.close(4003, "not in this match");

  try {
    await gf.players.connect(playerId);                 // 3. track join
  } catch (err) {
    if (err instanceof PlayerAlreadyConnectedError) { /* reconnect: keep going */ }
    else return ws.close(4000, err instanceof ServerFullError ? "server full" : "cannot join");
  }
  sockets.add(ws);
  ws.on("close", () => {
    sockets.delete(ws);
    gf.players.disconnect(playerId).catch((e) => console.error("[server]", e)); // 3. track leave
  });
});

wss.on("listening", () => {
  void gf.ready();                                       // 4. ready only once listening
  console.log(`[server] listening on :${port}`);
});

// 5. Shut down at match end and on SIGTERM (force-killed ~45 s after SIGTERM).
let stopping = false;
export async function endMatch(reason: string) {
  if (stopping) return;
  stopping = true;
  console.log(`[server] stopping: ${reason}`);
  for (const ws of sockets) ws.close(1001, "server shutting down");
  wss.close();
  await gf.shutdown();
  process.exit(0);
}
process.on("SIGTERM", () => void endMatch("SIGTERM"));
process.on("SIGINT", () => void endMatch("SIGINT"));
```

**Notes:**
- For a **TLS** game, keep this plaintext `ws` server on `gf.ports.default`. The platform terminates TLS, so browsers connect with `wss://<host>:<port>`.
- For matchmade games, call `matches:start` / `matches:end` from here with `GAMEFLOW_API_KEY` from the game's env vars (see the `gameflow-matchmaking` skill), then `endMatch()`.

## Colyseus

- **Managed Colyseus template:** keep the entry at `src/index.ts` and ship `package.json` + `package-lock.json`. Make `tsx` a dependency, because the template runs `npx tsx src/index.ts`.
- **Port:** the template sets `PORT=2567`. Read the port as `gf.ports.default ?? Number(process.env.PORT ?? 2567)`, and set the game's port to the one you listen on.
- **Where the calls go:** do the `connect` / `ready` dance in `index.ts` around `listen()`. In each `Room`, put `gf.players.connect(client.sessionId)` in `onJoin` and `gf.players.disconnect(client.sessionId)` in `onLeave`.

## Local mode

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 \
GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"team_index":0,"players":[{"player_id":"alice"}]}]}' \
node dist/server.js
```

**What local mode does:**
- The SDK logs one line saying it is in local mode. Lifecycle calls are no-ops.
- Player tracking runs in memory and throws `ServerFullError` past `GAMEFLOW_MAX_PLAYERS`.
- `payload()` returns `GAMEFLOW_PAYLOAD`.
- Force a mode with `GameFlow.connect({ mode: 'local' })` or `GAMEFLOW_SDK_MODE=local`.

Packaging (Dockerfile with `USER node`/UID 1000, no `node_modules` in the archive): see build-packaging.md.
