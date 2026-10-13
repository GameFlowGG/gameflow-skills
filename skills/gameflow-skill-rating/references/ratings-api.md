# Ratings API

Base `https://api.gameflow.gg/v1`, header `x-api-key`. Call these from server-side code only.

| Endpoint | Min role |
|---|---|
| `player-rating:resolve`, GET player, `players:batchGet`, `leaderboard`, GET `matches` | Viewer |
| PUT player (upsert), POST `matches` (record) | Engineer |

## Common rules

- **`modelId`:** get it from `skillModelId` in a `player-rating:resolve` or `matches:report` response, and cache it. There is no public "list models" endpoint.
  - The model must belong to your org. Otherwise you get 404 `skill model not found`.
- **`gameId` is required** on every `/models/{modelId}/...` endpoint. Without it you get 400 `game_id is required`.
  - Ratings are stored per **(model, season, game, player)**, so a read without the right game finds nothing.
  - Two game modes that use the same model in the same game share one ladder.
- **`seasonId`** is optional and defaults to the model's **active** season.
  - A `seasonId` that belongs to another model returns 404 `season not found`.
  - With no active season you get 400 `model has no active season`.
- **Unknown players** are not 404s. GET, batchGet and resolve return the model's **default** rating: `mu` = initial μ (default 25), `sigma` = initial σ (default 8.333333), `ordinal` = μ − 3σ (about 0), `matchesCount` 0, `displayName` `""`, `createdAt`/`updatedAt` `null`. Tell "never played" apart by `matchesCount === 0`.
- **Types:** `mu`, `sigma`, `ordinal` are doubles and `matchesCount` is an int32, all plain JSON numbers. These endpoints have no int64 fields. Timestamps are RFC 3339 strings.

### The rating object (`StoredPlayerRatingV1`)

```json
{ "externalPlayerId": "p1", "displayName": "Ana", "mu": 27.63, "sigma": 8.07,
  "ordinal": 3.42, "matchesCount": 1, "seasonId": "cm9y…",
  "createdAt": "2026-10-08T12:00:00Z", "updatedAt": "2026-10-08T12:00:00Z" }
```

`ordinal` = `mu − 3·sigma`, computed server-side. Show it as the player's rating, scaled or bucketed into tiers however you like. Use μ (or μ/σ together) for skill math.

## Resolve by game and mode (no model id)

`POST /v1/skill-rating/player-rating:resolve`

```bash
curl -sS -X POST https://api.gameflow.gg/v1/skill-rating/player-rating:resolve \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"gameId":"<gameId>","gameMode":"ranked","externalPlayerId":"p1"}'
```

```json
{ "found": true, "skillModelId": "cm9x…", "rating": { "externalPlayerId": "p1", "mu": 25, "sigma": 8.333333, "ordinal": 0.000001, "matchesCount": 0, "seasonId": "cm9y…", "displayName": "", "createdAt": null, "updatedAt": null } }
```

- **`found: false`** (with `skillModelId: ""` and `rating: null`) means no live matchmaker for the game handles `gameMode`, or the one that does has no Skill Rating Model node with a model selected.
  - That is a valid unrated (FIFO) setup, not an error. Hide the rank UI.
- **Always the active season.** There is no `seasonId` parameter.
- Errors: 400 if any field is empty, 403/404 for a game outside your org.

## Get one player

`GET /v1/skill-rating/models/{modelId}/players/{externalPlayerId}?gameId=<gameId>[&seasonId=]` → `{ "rating": {…} }`

URL-encode `externalPlayerId` if it can contain `/`, `?` or `#`.

## Batch get (lobbies, parties, scoreboards)

`POST /v1/skill-rating/models/{modelId}/players:batchGet`

```ts
const { ratings } = await gameflow<{ ratings: Rating[] }>(
  `/skill-rating/models/${modelId}/players:batchGet`,
  { method: "POST", body: JSON.stringify({ gameId, externalPlayerIds: ["p1", "p2", "p3"] }) },
);
// one entry per requested id, in request order; unknown players get the default rating
```

- `seasonId` is optional in the body.
- No maximum batch size is documented (unverified). Keep batches to a lobby's worth of players.

## Leaderboard

`GET /v1/skill-rating/models/{modelId}/leaderboard?gameId=<gameId>&limit=50[&cursor=][&seasonId=]` → `{ "entries": [rating…], "nextCursor": "50" }`

- **Order and content:** sorted by `ordinal`, highest first. Only players with a stored rating appear (at least one reported match, or an upsert).
- **`limit`:** defaults to 50, maximum 200 (larger values are clamped).
- **Paging:** pass `nextCursor` back as `cursor` to get the next page. `""` means the last page. Treat the cursor as opaque.
  - It is currently an offset, so ranks can shift between pages while matches are reported.
- **Rank numbers:** compute them on your side as `pageStart + index + 1`.
- **Caching:** serve leaderboards from your backend with a short cache (e.g. 30–60 s). Don't fan out per client request.

```ts
async function* leaderboard(modelId: string, gameId: string) {
  let cursor = "";
  do {
    const q = new URLSearchParams({ gameId, limit: "200", ...(cursor ? { cursor } : {}) });
    const page = await gameflow<{ entries: Rating[]; nextCursor: string }>(
      `/skill-rating/models/${modelId}/leaderboard?${q}`);
    yield* page.entries;
    cursor = page.nextCursor;
  } while (cursor);
}
```

## Upsert (seed, migrate, correct)

`PUT /v1/skill-rating/models/{modelId}/players/{externalPlayerId}` (Engineer)

```bash
curl -sS -X PUT "https://api.gameflow.gg/v1/skill-rating/models/$MODEL_ID/players/p1" \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"gameId":"<gameId>","mu":30.5,"sigma":4.2,"displayName":"Ana"}'
```

- **Behaviour:** creates or overwrites `mu`/`sigma` for (model, season, game, player) and derives `ordinal`. Returns `{ "rating": {…} }`.
- **Optional fields:**
  - `displayName`: when omitted, any stored name is kept.
  - `seasonId`: defaults to the active season.
- **`matchesCount`:** left unchanged; 0 for a new row.
- **No range validation.** Send `sigma > 0` and finite numbers. A σ ≤ 0 makes ticket creation fail for that player on skill-matched queues.
- **Paused models** reject it with 400 `skill model … is paused`.
- **Use it for:**
  - **Seeding** players imported from a previous rating system. Map onto μ ≈ 25 scale and keep σ high (≈ 6–8.33) unless you're confident.
  - **Admin corrections.**
  - **Soft-reset carry-over** into a new season: write a shrunk μ with a raised σ, passing the new season's id or leaving it to default to the active season.
- **Not for match results.** Use `matches:report`, which reads, computes and writes atomically. A read-compute-PUT loop on your side races with concurrent matches.

## Record a pre-computed match (advanced)

`POST /v1/skill-rating/models/{modelId}/matches` (Engineer)

```json
{ "gameId": "<gameId>", "externalMatchId": "m-1", "ranks": [0, 1],
  "participants": [
    { "externalPlayerId": "p1", "team": 0, "displayName": "Ana", "muBefore": 25, "sigmaBefore": 8.33, "muAfter": 27.6, "sigmaAfter": 8.07 },
    { "externalPlayerId": "p2", "team": 1, "muBefore": 25, "sigmaBefore": 8.33, "muAfter": 22.4, "sigmaAfter": 8.07 } ] }
```

- **What it does:** stores the match and upserts each participant's rating to `muAfter`/`sigmaAfter` (incrementing `matchesCount`), atomically. **GameFlow computes nothing**: you supply the after-values.
- **Response:** `{ "match": MatchRecord }`.
- **Not idempotent either.**
- **When to use it:** only for importing historical matches with known outcomes. For live matches always use `matches:report`.

## List matches (history and dedupe)

`GET /v1/skill-rating/models/{modelId}/matches?gameId=<gameId>[&externalPlayerId=][&seasonId=][&limit=][&cursor=]` → `{ "matches": [...], "nextCursor": "" }`

```json
{ "id": "cma0…", "skillModelId": "cm9x…", "seasonId": "cm9y…", "externalMatchId": "m-1",
  "ranks": [0, 1], "recordedAt": "2026-10-08T12:00:00Z",
  "participants": [ { "externalPlayerId": "p1", "team": 0, "displayName": "Ana",
    "muBefore": 25, "sigmaBefore": 8.333333, "muAfter": 27.63, "sigmaAfter": 8.07 } ] }
```

- **Order:** newest first (`recordedAt`). `limit` defaults to 50, maximum 200.
- **Filtering by `externalPlayerId`:** only the newest 500 matches of the model/game/season are scanned, and `nextCursor` is always `""`. Deep per-player history is not available that way.
- **Uses:** a per-player match history (rating change = `muAfter − muBefore`), and the duplicate check before retrying an ambiguous `matches:report` (see [report-match-result.md](report-match-result.md#retries-and-idempotency)).
