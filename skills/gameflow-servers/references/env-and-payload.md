# Environment variables and the launch payload

## Variables the platform sets on the game-server container

| Variable | Meaning | Read it with |
|---|---|---|
| `GAMEFLOW_DEFAULT_PORT` | The game's configured port (the **container** port). Listen on it. | SDK port helper (`gf.ports.default`, `GameFlowEnv.DefaultPort`, …) |
| `GAMEFLOW_<NAME>_PORT` | Additional named ports. The name is trimmed, uppercased, spaces → `_` (`voice chat` → `GAMEFLOW_VOICE_CHAT_PORT`) | `gf.ports.get("voice chat")` etc. |
| `GAMEFLOW_REGION` | Region id, e.g. `us-east` | `gf.region` |
| `GAMEFLOW_BUILD_ID` | Build id of the running image. Treat it as optional: it can be absent on some fleet servers. | `gf.buildId` |
| Your own variables | Everything in the game config's environment variables (e.g. `GAMEFLOW_API_KEY`, `LOG_LEVEL`) | normal `getenv` |

**Notes:**
- **TLS ports:** for TLS games, `GAMEFLOW_TLS_DEFAULT_PORT` / `GAMEFLOW_TLS_<NAME>_PORT` are the TLS listener ports of the platform's TLS sidecar. In the current platform code they are set on the sidecar, not on your container.
  - Your server keeps listening in **plaintext** on `GAMEFLOW_DEFAULT_PORT`. The sidecar terminates TLS and proxies to it.
  - The SDKs expose `ports.tls` helpers; expect them to be empty in your container and don't depend on them.
- **External vs container port:** players never connect to `GAMEFLOW_DEFAULT_PORT`. They connect to the `host` and external `port`/`ports[]` returned by allocate, start, details or a matchmaking assignment.
- **Launch options and args:**
  - The game's launch options plus any `launchArgs` from the start call are passed as container args, prefixed by a literal `--`.
  - With a managed template (Unity, Godot, Node) they are appended after the template's entrypoint flags, e.g. Godot sees them in `OS.get_cmdline_user_args()`.
  - With your own Dockerfile, use `ENTRYPOINT` (not only `CMD`), because args **replace** `CMD`.

## Variables the SDK reads (local development only)

| Variable | Effect |
|---|---|
| `GAMEFLOW_SDK_MODE` | `local` or `sidecar` forces the mode. An explicit option in code wins over it, and both win over auto-detection. |
| `GAMEFLOW_MAX_PLAYERS` | Local player capacity. Unset = unlimited, `0` = tracking disabled (mirrors "Max players = 0" in production). |
| `GAMEFLOW_PAYLOAD` | Simulated launch payload. **Local mode only.** In production the payload is an annotation on the server object, and `getenv` returns nothing. |

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 \
GAMEFLOW_PAYLOAD='{"match_id":"local-1","game_mode":"duel","team_count":2,"teams":[{"team_index":0,"players":[{"player_id":"alice","ticket_id":"t1","slot_index":0}]},{"team_index":1,"players":[{"player_id":"bob","ticket_id":"t2","slot_index":0}]}]}' \
node dist/server.js
```

## The payload

- **What it is:** an opaque string. GameFlow does not parse it.
- **Where it comes from:**
  - **Manual start/allocate:** exactly the `payload` string your backend sent to `POST /v1/games/{gameId}/servers`, `/servers/launch` or `/fleets/{gameId}/allocate`. Use JSON and pick your own casing.
  - **Matchmaking:** GameFlow writes it when the match is formed. It is **snake_case** (unlike the REST API):

```json
{
  "match_id": "m_01J…",
  "game_mode": "ranked",
  "team_count": 2,
  "teams": [
    { "team_index": 0, "players": [
      { "player_id": "alice", "ticket_id": "tkt_…", "slot_index": 0, "attributes": { "character": "mage" } }
    ]},
    { "team_index": 1, "players": [
      { "player_id": "bob", "ticket_id": "tkt_…", "slot_index": 0 }
    ]}
  ]
}
```
`attributes` is present only when the ticket sent attributes declared on the matchmaker's Ticket Input node. `match_id` is what `matches:start` / `matches:end` and `skill-rating/matches:report` (`matchId`) expect.

### Read it correctly

- **Fleet servers become Ready empty.** Allocation writes the payload later, so:
  1. Read it once after connect (it may be empty).
  2. **Subscribe to the payload-change event** and (re)configure the match when it arrives.
- **Standalone servers** started with a payload usually have it at connect, but subscribe anyway.

| SDK | Read | Change event |
|---|---|---|
| TypeScript | `await gf.payload()` → `string \| undefined` | `gf.onPayloadChange(cb)` |
| Unity | `await gf.Payload()` → `string` or `null` | `gf.OnPayloadChange(Action<string>)` |
| Unreal | `GF->GetPayload(FGfPayloadResult)` | `OnPayloadChanged` (dynamic multicast) |
| Godot | `(await gf.payload()).value` | `gf.on_payload_change(callable)` |
| Go | `gf.Payload(ctx)` → `(payload, present, err)` | `gf.OnPayloadChange(func(string, bool))` |
| Rust | `gf.payload().await?` → `Option<String>` | `gf.on_payload_change(\|Option<String>\| …)?` (keep the `Subscription`) |

### Trust the payload, not the client

The client only knows `host:port`, and anyone can connect to it. Before accepting a player:

1. Get the player's identity from **your** auth (a session token your backend issued, verified by the server). Never trust a player id the client merely claims.
2. Check that the id is listed in the payload (`teams[].players[].player_id` for matchmade games, or whatever your backend put there).
3. Reject everyone else, and anyone who joins before the payload has arrived on a fleet server.
4. Use the payload's team and slot assignment rather than client-chosen teams.

```ts
type MatchPayload = {
  match_id: string;
  game_mode: string;
  team_count: number;
  teams: { team_index: number; players: { player_id: string; ticket_id: string; slot_index: number; attributes?: Record<string, unknown> }[] }[];
};

let match: MatchPayload | null = null;
const parse = (raw: string | undefined) => { match = raw ? (JSON.parse(raw) as MatchPayload) : null; };
parse(await gf.payload());
gf.onPayloadChange(parse);

function expectedPlayer(playerId: string) {
  if (!match) return null;
  for (const team of match.teams) {
    const p = team.players.find((x) => x.player_id === playerId);
    if (p) return { team: team.team_index, slot: p.slot_index };
  }
  return null;
}
```

## Secrets on the server

- Only add `GAMEFLOW_API_KEY` to the game's environment variables if the server itself calls the API (match start/end, skill reports). Otherwise leave it out.
- Never log it, and never forward it to clients.
