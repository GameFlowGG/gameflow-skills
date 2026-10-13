# Backend examples (the 3 routes)

Both examples use [../assets/matchmaking-routes.ts](../assets/matchmaking-routes.ts). Copy that file into the project and don't re-implement it. It handles allowlists, idempotent join, long-poll mapping, cancel with 404-as-success, stale-ticket sweep and optional join tokens.

Environment (server-side only, never in a client build):

```bash
# .env (git-ignored) / secret manager
GAMEFLOW_API_KEY=gf_...            # Engineer role or higher
GAMEFLOW_GAME_ID=...               # from GET /v1/games -> games[].game.id
MATCH_JOIN_SECRET=...              # optional, random 32+ bytes, also set as a game env var for the server
```

Add `GAMEFLOW_API_KEY=` and `GAMEFLOW_GAME_ID=` to `.env.example` as placeholders only.

## Node + Express

```bash
npm i express && npm i -D typescript @types/express @types/node tsx
```

```ts
// src/server.ts  (Node 20+, run with: npx tsx src/server.ts)
import express, { type Request, type Response } from "express";
import { createMatchmaking, HttpError } from "./matchmaking-routes.js";

const mm = createMatchmaking({
  apiKey: process.env.GAMEFLOW_API_KEY ?? "",
  gameId: process.env.GAMEFLOW_GAME_ID ?? "",
  allowedGameModes: ["ranked-1v1"],            // must equal the Ticket Input game mode(s)
  allowedRegions: ["us-east", "eu-central"],   // regions your game is deployed in; names from GET /v1/ping/regions
  joinTokenSecret: process.env.MATCH_JOIN_SECRET,
  // buildAttributes: async (playerId, requested) => ({ character: pickAllowedCharacter(requested) }),
});
setInterval(() => void mm.sweep(), 15_000).unref();

/**
 * Replace with YOUR auth: verify a session cookie / JWT / Steam ticket and return the player's id.
 * Never trust a playerId sent in the body or query.
 */
async function authenticatePlayer(req: Request): Promise<string | null> {
  if (process.env.NODE_ENV !== "production") {
    const devId = req.header("x-dev-player-id"); // local testing only
    if (devId) return devId;
  }
  return null; // e.g. return (await verifyJwt(req.header("authorization")))?.sub ?? null;
}

const app = express();
app.use(express.json());

type Handler = (playerId: string, req: Request) => Promise<unknown>;
const route = (fn: Handler) => async (req: Request, res: Response) => {
  const playerId = await authenticatePlayer(req);
  if (!playerId) return res.status(401).json({ error: "unauthenticated" });
  try {
    const out = await fn(playerId, req);
    return out === undefined ? res.status(204).end() : res.json(out);
  } catch (err) {
    if (err instanceof HttpError) return res.status(err.status).json({ error: err.message });
    console.error(err);
    return res.status(500).json({ error: "internal error" });
  }
};

app.post("/matchmaking/join", route((playerId, req) =>
  mm.join(playerId, { region: req.body?.region, gameMode: req.body?.gameMode, attributes: req.body?.attributes })));

app.get("/matchmaking/status/:ticketId", route((playerId, req) => mm.status(playerId, req.params.ticketId!)));

app.delete("/matchmaking/:ticketId", route(async (playerId, req) => {
  await mm.cancel(playerId, req.params.ticketId!);
  return undefined;
}));

const server = app.listen(Number(process.env.PORT ?? 3000), () => console.log("backend up"));
server.requestTimeout = 0;      // allow 25 s long-polls
server.headersTimeout = 65_000;
server.keepAliveTimeout = 61_000;
```

Wiring notes:
- **Disconnect:** if clients also hold a WebSocket to you, call `await mm.cancelPlayer(playerId)` in its `close` handler. Without one, the sweep cancels any search that has not been polled for 60 s.
- **Timeouts:** each status call can take up to `longPollSeconds` (25) plus a few seconds. Proxies in front of you (nginx `proxy_read_timeout`, load balancer idle timeout) must allow at least 40 s.
- **In-memory state:** the default store lives in this process. Restarts lose the `playerId → ticket` map: orphaned tickets stay in GameFlow's queue until matched, so keep restarts rare or use a shared store. With **more than one instance**, implement `TicketStore` on Redis or Postgres (the Supabase example below shows a Postgres store) or route each player to one instance.
- **Smoke test locally:**
  ```bash
  curl -sS -X POST localhost:3000/matchmaking/join -H 'x-dev-player-id: p1' -H 'Content-Type: application/json' -d '{"region":"us-east"}'
  curl -sS localhost:3000/matchmaking/status/<ticketId> -H 'x-dev-player-id: p1' --max-time 40
  curl -sS -X DELETE localhost:3000/matchmaking/<ticketId> -H 'x-dev-player-id: p1' -i
  ```

## Supabase edge function (Deno)

Edge functions are stateless between invocations, so tickets live in Postgres. Players authenticate with Supabase Auth, and `playerId` is `auth.users.id`.

**1. Table** (migration):

```sql
create table public.matchmaking_tickets (
  ticket_id  text primary key,
  player_id  text   not null,
  game_mode  text   not null,
  state      text   not null,          -- searching | assigned | cancelled | failed
  created_at bigint not null,          -- epoch ms
  last_seen  bigint not null,
  failures   int    not null default 0,
  host text, port int, join_token text
);
create unique index matchmaking_one_search_per_player
  on public.matchmaking_tickets (player_id) where state = 'searching';
alter table public.matchmaking_tickets enable row level security; -- no policies: only the service role touches it
```

**2. Files:** copy the asset to `supabase/functions/_shared/matchmaking-routes.ts`, then create:

```ts
// supabase/functions/matchmaking/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { createMatchmaking, type TicketRecord, type TicketStore } from "../_shared/matchmaking-routes.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const toRow = (r: TicketRecord) => ({
  ticket_id: r.ticketId, player_id: r.playerId, game_mode: r.gameMode, state: r.state,
  created_at: r.createdAt, last_seen: r.lastSeen, failures: r.failures,
  host: r.host ?? null, port: r.port ?? null, join_token: r.joinToken ?? null,
});
// deno-lint-ignore no-explicit-any
const fromRow = (x: any): TicketRecord => ({
  ticketId: x.ticket_id, playerId: x.player_id, gameMode: x.game_mode, state: x.state,
  createdAt: Number(x.created_at), lastSeen: Number(x.last_seen), failures: x.failures,
  host: x.host ?? undefined, port: x.port ?? undefined, joinToken: x.join_token ?? undefined,
});

const store: TicketStore = {
  async get(id) {
    const { data } = await admin.from("matchmaking_tickets").select("*").eq("ticket_id", id).maybeSingle();
    return data ? fromRow(data) : undefined;
  },
  async getActiveByPlayer(playerId) {
    const { data } = await admin.from("matchmaking_tickets").select("*")
      .eq("player_id", playerId).eq("state", "searching").maybeSingle();
    return data ? fromRow(data) : undefined;
  },
  async put(r) {
    const { error } = await admin.from("matchmaking_tickets").upsert(toRow(r));
    if (error) throw new Error(error.message);
  },
  async delete(id) {
    await admin.from("matchmaking_tickets").delete().eq("ticket_id", id);
  },
  async list() {
    const { data } = await admin.from("matchmaking_tickets").select("*").limit(1000);
    return (data ?? []).map(fromRow);
  },
};

const mm = createMatchmaking({
  apiKey: Deno.env.get("GAMEFLOW_API_KEY") ?? "",
  gameId: Deno.env.get("GAMEFLOW_GAME_ID") ?? "",
  allowedGameModes: ["ranked-1v1"],
  allowedRegions: ["us-east", "eu-central"],
  joinTokenSecret: Deno.env.get("MATCH_JOIN_SECRET"),
  store,
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return new Response(JSON.stringify({ error: "unauthenticated" }), { status: 401, headers: cors });

  if (req.method === "POST") mm.sweep().catch(console.error); // no timers in edge functions: sweep opportunistically

  const res = (await mm.handle(req, user.id)) ?? new Response("not found", { status: 404 });
  for (const [k, v] of Object.entries(cors)) res.headers.set(k, v);
  return res;
});
```

**3. Deploy:**

```bash
supabase secrets set GAMEFLOW_API_KEY=gf_... GAMEFLOW_GAME_ID=... MATCH_JOIN_SECRET=...
supabase functions deploy matchmaking
# local: supabase functions serve --env-file supabase/functions/.env.local
```

Clients call `https://<project>.supabase.co/functions/v1/matchmaking/join` (then `/status/<id>` and `DELETE /<id>`) with `Authorization: Bearer <user access token>`. Never send the GameFlow key, and never the service role key.

Notes:
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected into edge functions automatically.
- A 25 s long-poll fits inside the edge function wall-clock limit. Check your plan's limit if you raise `longPollSeconds`.
- The partial unique index stops two concurrent joins from creating two searching rows. The module cancels the losing request's GameFlow ticket and returns 409. The client retries join, which then returns the existing ticket.
- For many tickets, replace the opportunistic sweep with a `pg_cron` job that calls the function on a timer.
