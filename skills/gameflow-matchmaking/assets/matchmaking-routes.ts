/**
 * GameFlow matchmaking routes for a TRUSTED backend (Node 20+, Deno, Bun, Supabase Edge).
 *
 * Copy this file into your backend. It implements:
 *   POST   /matchmaking/join               body {region, gameMode?, attributes?} -> {ticketId, status:"searching"}
 *   GET    /matchmaking/status/:ticketId   long-poll -> {status:"searching"} | {status:"assigned", host, port, joinToken?}
 *   DELETE /matchmaking/:ticketId          -> 204
 *
 * Rules baked in:
 *   - playerId always comes from YOUR auth (passed in by the caller), never from the request body.
 *   - The GameFlow API key stays here. Never send it to clients.
 *   - API JSON is camelCase; base URL includes /v1.
 *
 * State: the default store is in-memory (one process). With several instances or a serverless
 * runtime, pass a shared TicketStore (Redis, Postgres...); see references/backend-examples.md.
 */

export interface TicketRecord {
  ticketId: string;
  playerId: string;
  gameMode: string;
  state: "searching" | "assigned" | "cancelled" | "failed";
  createdAt: number;
  lastSeen: number; // last time the client polled; used to cancel abandoned tickets
  failures: number; // consecutive status-call failures
  host?: string;
  port?: number;
  joinToken?: string;
}

export interface TicketStore {
  get(ticketId: string): Promise<TicketRecord | undefined>;
  getActiveByPlayer(playerId: string): Promise<TicketRecord | undefined>; // state === "searching"
  put(record: TicketRecord): Promise<void>;
  delete(ticketId: string): Promise<void>;
  list(): Promise<TicketRecord[]>;
}

export interface MatchmakingOptions {
  apiKey: string;
  gameId: string;
  /** Game modes clients may ask for. The first one is the default. Must equal Ticket Input modes. */
  allowedGameModes: string[];
  /** Region names your game is deployed in (names from GET /v1/ping/regions, e.g. "us-east"). */
  allowedRegions: string[];
  apiBase?: string; // default https://api.gameflow.gg/v1
  longPollSeconds?: number; // default 25 (keep <= 30)
  staleAfterMs?: number; // cancel searching tickets not polled for this long (default 60s)
  assignedTtlMs?: number; // forget assigned tickets after this long (default 10 min)
  /** Optional: return a signed join token with the assignment (verify it on the game server). */
  joinTokenSecret?: string;
  joinTokenTtlMs?: number; // default 2 min
  /** Optional: build or validate ticket attributes server-side. Throw HttpError(400) to reject. */
  buildAttributes?: (playerId: string, requested: unknown) => Promise<Record<string, string | number | boolean> | undefined>;
  store?: TicketStore;
  fetchImpl?: typeof fetch;
}

export class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export type StatusResult =
  | { ticketId: string; status: "searching" }
  | { ticketId: string; status: "assigned"; host: string; port: number; joinToken?: string };

export function memoryStore(): TicketStore {
  const tickets = new Map<string, TicketRecord>();
  return {
    async get(id) { return tickets.get(id); },
    async getActiveByPlayer(playerId) {
      for (const t of tickets.values()) if (t.playerId === playerId && t.state === "searching") return t;
      return undefined;
    },
    async put(r) { tickets.set(r.ticketId, { ...r }); },
    async delete(id) { tickets.delete(id); },
    async list() { return [...tickets.values()]; },
  };
}

export function createMatchmaking(opts: MatchmakingOptions) {
  const api = (opts.apiBase ?? "https://api.gameflow.gg/v1").replace(/\/$/, "");
  const longPoll = Math.min(Math.max(opts.longPollSeconds ?? 25, 1), 30);
  const staleAfter = opts.staleAfterMs ?? 60_000;
  const assignedTtl = opts.assignedTtlMs ?? 600_000;
  const store = opts.store ?? memoryStore();
  const doFetch = opts.fetchImpl ?? fetch;
  const inflightJoins = new Map<string, Promise<{ ticketId: string; status: "searching" }>>();
  if (!opts.apiKey) throw new Error("GAMEFLOW_API_KEY is not set");
  if (!opts.gameId) throw new Error("GAMEFLOW_GAME_ID is not set");

  async function gameflow(path: string, init: RequestInit & { timeoutMs?: number } = {}) {
    const res = await doFetch(`${api}${path}`, {
      ...init,
      headers: { "x-api-key": opts.apiKey, ...(init.body ? { "Content-Type": "application/json" } : {}) },
      signal: AbortSignal.timeout(init.timeoutMs ?? 10_000),
    });
    const text = await res.text();
    let body: any = {};
    try { body = text ? JSON.parse(text) : {}; } catch { body = { message: text }; }
    return { status: res.status, ok: res.ok, body };
  }

  async function join(playerId: string, input: { region?: unknown; gameMode?: unknown; attributes?: unknown }) {
    const gameMode = input.gameMode ?? opts.allowedGameModes[0];
    if (typeof gameMode !== "string" || !opts.allowedGameModes.includes(gameMode)) throw new HttpError(400, "unknown gameMode");
    if (typeof input.region !== "string" || !opts.allowedRegions.includes(input.region)) throw new HttpError(400, "unknown region");
    const region = input.region;

    // Idempotent: one searching ticket per player, even with concurrent requests.
    const pending = inflightJoins.get(playerId);
    if (pending) return pending;
    const p = (async () => {
      const existing = await store.getActiveByPlayer(playerId);
      if (existing && existing.gameMode === gameMode) {
        existing.lastSeen = Date.now();
        await store.put(existing);
        return { ticketId: existing.ticketId, status: "searching" as const };
      }
      if (existing) await cancel(playerId, existing.ticketId); // switching modes

      const attributes = opts.buildAttributes ? await opts.buildAttributes(playerId, input.attributes) : undefined;
      let res = await createTicket(playerId, gameMode, region, attributes);
      if (res.status === 429 || res.status >= 500) {
        await sleep(1000);
        res = await createTicket(playerId, gameMode, region, attributes);
      }
      if (!res.ok) {
        console.error("gameflow create ticket failed", res.status, res.body?.message);
        // 400 code 9 = no Live matchmaker for (gameId, gameMode): a config problem, not the player's.
        throw new HttpError(res.status === 400 && res.body?.code !== 9 ? 400 : 503, "matchmaking unavailable");
      }
      const now = Date.now();
      try {
        await store.put({ ticketId: res.body.ticketId, playerId, gameMode, state: "searching", createdAt: now, lastSeen: now, failures: 0 });
      } catch {
        // Could not record it (e.g. a concurrent join won): don't leave an orphan ticket in the queue.
        await gameflow(`/matchmaking/tickets/${encodeURIComponent(res.body.ticketId)}?playerId=${encodeURIComponent(playerId)}`, { method: "DELETE" }).catch(() => {});
        throw new HttpError(409, "join already in progress, retry");
      }
      return { ticketId: res.body.ticketId as string, status: "searching" as const };
    })();
    inflightJoins.set(playerId, p);
    try { return await p; } finally { inflightJoins.delete(playerId); }
  }

  function createTicket(playerId: string, gameMode: string, region: string, attributes?: Record<string, unknown>) {
    return gameflow("/matchmaking/tickets", {
      method: "POST",
      body: JSON.stringify({ playerId, gameId: opts.gameId, gameMode, preferredAz: region, ...(attributes ? { attributes } : {}) }),
    });
  }

  async function status(playerId: string, ticketId: string): Promise<StatusResult> {
    const rec = await ownedTicket(playerId, ticketId);
    if (rec.state === "assigned") return assigned(rec);
    if (rec.state !== "searching") throw new HttpError(410, `ticket ${rec.state}`);
    rec.lastSeen = Date.now();
    await store.put(rec);

    let res: { status: number; ok: boolean; body: any };
    try {
      res = await gameflow(`/matchmaking/tickets/${encodeURIComponent(ticketId)}/status?timeoutSeconds=${longPoll}`, {
        timeoutMs: (longPoll + 10) * 1000,
      });
    } catch {
      res = { status: 0, ok: false, body: {} };
    }
    const latest = await store.get(ticketId); // may have been cancelled meanwhile
    if (!latest) throw new HttpError(410, "ticket cancelled");
    latest.lastSeen = Date.now();
    if (latest.state !== "searching") {
      await store.put(latest);
      if (latest.state === "assigned") return assigned(latest);
      throw new HttpError(410, `ticket ${latest.state}`);
    }
    if (!res.ok) {
      latest.failures += 1;
      if (latest.failures >= 5) latest.state = "failed";
      await store.put(latest);
      console.error("gameflow ticket status failed", res.status, res.body?.message);
      throw new HttpError(latest.state === "failed" ? 410 : 502, "status unavailable, retry");
    }
    latest.failures = 0;
    if (res.body.status === "assigned" && typeof res.body.connection === "string") {
      const i = res.body.connection.lastIndexOf(":");
      latest.host = res.body.connection.slice(0, i);
      latest.port = Number(res.body.connection.slice(i + 1));
      latest.state = "assigned";
      if (opts.joinTokenSecret) latest.joinToken = await signJoinToken(playerId, ticketId);
      await store.put(latest);
      return assigned(latest);
    }
    // "pending" | "queued" | anything else: still searching
    await store.put(latest);
    return { ticketId, status: "searching" };
  }

  async function cancel(playerId: string, ticketId: string): Promise<void> {
    const rec = await ownedTicket(playerId, ticketId);
    if (rec.state === "searching") {
      rec.state = "cancelled";
      await store.put(rec);
      const res = await gameflow(`/matchmaking/tickets/${encodeURIComponent(ticketId)}?playerId=${encodeURIComponent(playerId)}`, {
        method: "DELETE",
      }).catch(() => ({ ok: false, status: 0, body: {} }));
      if (!res.ok && res.status !== 404) console.error("gameflow cancel failed", res.status, res.body?.message);
    }
    await store.delete(ticketId);
  }

  /** Call when the player's socket/session closes. */
  async function cancelPlayer(playerId: string): Promise<void> {
    const rec = await store.getActiveByPlayer(playerId);
    if (rec) await cancel(playerId, rec.ticketId);
  }

  /** Cancels abandoned searches and forgets old assignments. Run every ~15 s, or on each request. */
  async function sweep(): Promise<void> {
    const now = Date.now();
    for (const rec of await store.list()) {
      if (rec.state === "searching" && now - rec.lastSeen > staleAfter) await cancel(rec.playerId, rec.ticketId).catch(() => {});
      else if (rec.state !== "searching" && now - rec.createdAt > assignedTtl) await store.delete(rec.ticketId);
    }
  }

  async function ownedTicket(playerId: string, ticketId: string): Promise<TicketRecord> {
    const rec = await store.get(ticketId);
    if (!rec || rec.playerId !== playerId) throw new HttpError(404, "ticket not found");
    return rec;
  }

  function assigned(rec: TicketRecord): StatusResult {
    return { ticketId: rec.ticketId, status: "assigned", host: rec.host!, port: rec.port!, ...(rec.joinToken ? { joinToken: rec.joinToken } : {}) };
  }

  async function signJoinToken(playerId: string, ticketId: string): Promise<string> {
    const enc = new TextEncoder();
    const body = b64url(enc.encode(JSON.stringify({ p: playerId, t: ticketId, exp: Date.now() + (opts.joinTokenTtlMs ?? 120_000) })));
    const key = await crypto.subtle.importKey("raw", enc.encode(opts.joinTokenSecret!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
    return `${body}.${b64url(sig)}`;
  }

  /**
   * Web-standard router (Deno, Bun, Supabase Edge, Cloudflare). Returns null for paths it doesn't own.
   * `playerId` must come from your verified auth for this request.
   */
  async function handle(req: Request, playerId: string, basePath = "/matchmaking"): Promise<Response | null> {
    const path = new URL(req.url).pathname;
    const idx = path.indexOf(basePath);
    if (idx < 0) return null;
    const rest = path.slice(idx + basePath.length);
    try {
      if (req.method === "POST" && rest === "/join") return json(200, await join(playerId, await req.json().catch(() => ({}))));
      let m = rest.match(/^\/status\/([^/]+)$/);
      if (req.method === "GET" && m) return json(200, await status(playerId, decodeURIComponent(m[1]!)));
      m = rest.match(/^\/([^/]+)$/);
      if (req.method === "DELETE" && m) { await cancel(playerId, decodeURIComponent(m[1]!)); return new Response(null, { status: 204 }); }
      return null;
    } catch (err) {
      if (err instanceof HttpError) return json(err.status, { error: err.message });
      console.error(err);
      return json(500, { error: "internal error" });
    }
  }

  return { join, status, cancel, cancelPlayer, sweep, handle };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}
