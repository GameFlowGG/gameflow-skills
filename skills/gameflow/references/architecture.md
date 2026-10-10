# GameFlow architecture: who calls what

## Components

| Component | Owned by | Holds API key? | Talks to |
|---|---|---|---|
| Game client (Unity/Godot/Unreal/web) | Customer | **Never** | Customer backend (HTTP); game server (`host:port`); GameFlow ping endpoints (no auth) |
| Customer backend (Node service, Supabase edge function, etc.) | Customer | Yes | GameFlow API |
| Dedicated game server (your server build, running on GameFlow) | Customer code, GameFlow runtime | Yes, if it reports results or analytics (inject it as a game env var / secret) | GameFlow SDK (local runtime); GameFlow API |
| GameFlow API `https://api.gameflow.gg/v1` | GameFlow | — | — |
| GameFlow dashboard `https://app.gameflow.gg` | GameFlow | — (uses the user's session) | — |

## Matchmade session flow

```
client ──(1) "find match" + player auth──▶ customer backend
customer backend ──(2) POST /v1/matchmaking/tickets──▶ GameFlow
customer backend ──(3) GET  /v1/matchmaking/tickets/{id}/status?timeoutSeconds=30 (loop)──▶ GameFlow
        GameFlow forms a match, allocates a game server, writes the payload (match_id, teams)
customer backend ◀── status "assigned", connection "host:port"
client ◀──(4) host:port── customer backend
client ──(5) connect──▶ game server
game server: SDK Ready → reads payload → validates joining players → POST matches:start
game server: … match …  → POST matches:end → POST skill-rating/matches:report → SDK Shutdown
```

**Where to look:**
- Matchmaking setup and the ticket loop: `gameflow-matchmaking`.
- Server-side SDK, payload and lifecycle calls: `gameflow-servers`.
- Rating updates: `gameflow-skill-rating`.

## Lobby / on-demand flow (no matchmaking)

```
client ──"host a game"──▶ customer backend
customer backend ── POST /v1/fleets/{gameId}/allocate {region, payload} ──▶ GameFlow   (claims an already-Ready server; needs Intelligent Autoscaling)
      or        ── POST /v1/games/{gameId}/servers   {region, payload} ──▶ GameFlow   (cold start; blocks up to ~120 s)
customer backend ◀── host + port (+ named ports)
client ── connect ──▶ game server
```

## Regions

- `GET /v1/ping/regions` needs **no auth** and returns `{"regions":[{name, endpoint}]}`.
  - **Native clients** (Unity/Godot/Unreal) may call it directly, measure latency to each `endpoint`, and send the best `name` to the backend.
  - **Browser games** can't: the API's CORS allows only GameFlow's own dashboard origin. Have your backend fetch the list and pass it to the browser.
- The backend passes that region as `preferredAz` on tickets, or as `region` on allocate/start.
- `GET /v1/regions/available` (auth) lists the regions the deployment can run servers in. Don't assume more than it returns.

## Dashboard-only setup (no public API)

These can't be done through the public API today. Give the user a checklist and verify the result through the API.

| Task | Where | Verify with |
|---|---|---|
| Sign up / create org | app.gameflow.gg | `GET /v1/identity/me` |
| Create API key | Settings → API Keys | `GET /v1/identity/me` with the key |
| Create a game (engine, ports, protocol, regions, env vars, CPU/memory, max players, autoscaling) | Games → Create Game | `GET /v1/games`, `GET /v1/games/{gameId}` |
| Promote / roll back a build | Game → Builds | `GET /v1/images/builds?gameId=…` |
| Create + **publish** a matchmaker for `(gameId, gameMode)` | Matchmakers | Creating a ticket for that queue no longer fails with "no published matchmaker" |
| Create a skill model, add a **Skill Model** node to the matchmaker that selects it, and re-publish | Skill Rating / Matchmakers | `POST /v1/skill-rating/player-rating:resolve` returns `found: true` and a `skillModelId` |
