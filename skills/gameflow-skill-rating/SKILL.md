---
name: gameflow-skill-rating
description: Add GameFlow skill rating (OpenSkill-based, TrueSkill-like MMR/ELO alternative) to a game. Covers the dashboard checklist for creating a rating model and attaching it to a matchmaker, reporting match results from the dedicated server or backend (POST /v1/skill-rating/matches:report, ranks, teams, retries and the fact that reports are NOT idempotent), reading player ratings and ranks (player-rating:resolve, ordinal, batchGet for lobbies), leaderboards with cursor pagination, seasons, and seeding or migrating existing ratings. Use when the user mentions skill rating, MMR, ELO, OpenSkill, TrueSkill, rank, ranked mode, leaderboard, report match result, player rating, mu/sigma, balanced or skill-based matchmaking, or seasons on GameFlow.
license: MIT
metadata:
  author: GameFlow
  version: "0.1.0"
---

# GameFlow Skill Rating

GameFlow stores and computes player ratings for you. Each player has **μ (mu)**, the skill estimate, and **σ (sigma)**, the uncertainty. GameFlow derives **ordinal = μ − 3σ** for display and leaderboards. You create a model in the dashboard and attach it to a matchmaker. After each match you report who won, and GameFlow updates every player's rating.

Account setup, API keys, base URL and JSON conventions are covered in the `gameflow` skill. Queues and tickets are covered in `gameflow-matchmaking`, and the server SDK and payload in `gameflow-servers`. This skill doesn't repeat them.

Skill Rating is labelled **Alpha** in the docs. Field names below were checked against the API code (develop, 2026-10).

## Rules

1. **The API key never ships in a game client.** Every call here is made by the dedicated game server or by the customer's backend. Clients that show a rank or leaderboard ask the customer's backend, which calls GameFlow.
2. **Only trusted code reports results.** If the client reports, any player can award themselves wins.
3. **`matches:report` is not idempotent.** Each successful call applies the rating update again, and `externalMatchId` is stored but not deduplicated. Read [the retry policy](references/report-match-result.md#retries-and-idempotency) before you add retries.
4. **JSON is camelCase** (`externalPlayerId`, `muAfter`, `skillModelId`). Older docs show snake_case response fields, which are wrong. The one exception is the matchmaking **payload** the game server receives, which is snake_case (`player_id`, `match_id`).

## 0. Prerequisites

- An API key in `GAMEFLOW_API_KEY` (see the `gameflow` skill). Reads need any role. **Writes** (report, upsert, record) need the key creator to have at least the **Engineer** role, or they fail with 403 `insufficient permissions`.
- A game (`gameId`).
- For `matches:report` and `player-rating:resolve`: a **published (Live) matchmaker** for that game whose **Ticket Input** node handles your `gameMode`, plus a **Skill Rating Model** node in the same flow with a model selected. The model is resolved from that matchmaker, so you never send a model id. If several live matchmakers handle the same mode, the most recently updated one wins.

## 1. Dashboard checklist (human)

There are no public endpoints for creating models, attaching them or managing seasons. Give the user these steps and wait for confirmation:

1. **Rating Models → Create Rating Model** (https://app.gameflow.gg/rating-models):
   - **Mode name**, e.g. `Ranked 2v2`.
   - **Rating engine**: fixed to "GF Engine" (`builtin_openskill`).
   - **Match format**: Teams, Free-for-all or Battle Royale.
   - **Number of teams** and **Players per team**. These and the format are **locked after creation**.
   - **Teams can be uneven**, **Scored by** (Win/loss, Final placement, Numeric score), and **Supports parties** with **Max party size**.
   - Click **Create & Go Live**. This also creates the active "Season 1".
2. Optional: on the model's **Configuration** tab, tune μ/σ/β, rating volatility and Limit Sigma. Defaults are 25 / 8.333333 / 0.5×σ, Medium and on. See [models-and-seasons.md](references/models-and-seasons.md).
3. Open the matchmaker for `(game, gameMode)` and add a **Skill Rating Model** node. Select the model and wire it as Ticket Input → Skill Rating Model → **Skill Rule** → Team Composition → Output.
   - Without a Skill Rule, ratings are still tracked, but matching is FIFO.
   - Team Composition must match the model's team shape.
   - Set the Skill Rule's fairness rule. It starts at `none`.
4. **Publish** the matchmaker.

**Verify (agent).** A key with any role works:

```bash
curl -sS -X POST https://api.gameflow.gg/v1/skill-rating/player-rating:resolve \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"gameId":"<gameId>","gameMode":"ranked","externalPlayerId":"probe-player"}'
```

- `"found": true` with a `skillModelId` means the setup is correct. **Save `skillModelId`**: the leaderboard, batch and history endpoints need it.
- `"found": false` means no live matchmaker handles that `gameMode`, or it has no Skill Rating Model node with a model selected. Check the mode string (exact match after trimming) and that the matchmaker was published.

## 2. Report results

**Who calls it:**
- **The dedicated game server**, at match end, with the key in its environment.
- **Or the customer's backend**, if the backend decides the outcome or you don't want the key on game servers. The server sends the result to the backend over your own authenticated channel.
- **Never the client.**

Report before calling SDK Shutdown, and await the response.

```http
POST /v1/skill-rating/matches:report
{ "gameId": "...", "gameMode": "ranked", "externalMatchId": "your-id",
  "matchId": "<match_id from the payload>",
  "teams": [ {"players":[{"externalPlayerId":"p1","displayName":"Ana"}]},
             {"players":[{"externalPlayerId":"p2","displayName":"Beto"}]} ],
  "ranks": [0, 1] }
```

- **Ranks** are parallel to `teams`. **Lower is better**: 0 (or 1) is the winner, and only the order matters. **Ties share a rank**, e.g. `[0, 0]` for a draw. For free-for-all or battle royale, use one team per player (or squad) and their placement as the rank.
- **Mapping from the payload:** the game server reads the snake_case payload with the SDK's payload getter, not getenv.
  - Each `teams[i].players[j].player_id` becomes `externalPlayerId`.
  - Keep teams in payload order and build `ranks` in the same order.
  - `player_id` is the `playerId` your backend put on the ticket, so ratings line up with what matchmaking reads.
- **`matchId`:** send the payload's `match_id`. It links the result to match analytics. It's optional, and ratings are recorded identically without it.
- **`gameId`** is not in the payload. Give the server its own game id, e.g. as a game env var.
- **`displayName`** (optional) is stored on the rating when non-empty and is shown on leaderboards.
- **Validation:** at least 2 teams, one rank per team, no empty team, and every `externalPlayerId` non-empty.
  - **Not checked:** duplicate players across teams, and whether the team shape matches the model. Ensure each player appears once.
- **Response:** `{skillModelId, seasonId, matchId, ratings:[{externalPlayerId, displayName, team, muBefore, sigmaBefore, muAfter, sigmaAfter, ordinalAfter}]}`. The response `matchId` is the **rating record's id**, not the GameFlow match id you sent.

**Retries:**
- **An error response with the `{code, message}` body means nothing was written.** Every failure in the handler happens before the single atomic write. Retry 429/5xx with backoff; never retry 4xx unchanged.
- **No response** (timeout or dropped connection) is ambiguous: the match may already be recorded. Before re-sending, list the model's matches for one of the players and look for your `externalMatchId`.
- Always send a unique `externalMatchId`.

Full examples (curl, TypeScript backend, C# Unity server) and the dedupe check are in [references/report-match-result.md](references/report-match-result.md).

## 3. Read ratings (backend only, then serve to clients)

| Need | Call |
|---|---|
| A player's rank by game and mode, no model id | `POST /v1/skill-rating/player-rating:resolve` `{gameId, gameMode, externalPlayerId}` → `{found, skillModelId, rating}` |
| One player by model | `GET /v1/skill-rating/models/{modelId}/players/{externalPlayerId}?gameId=&seasonId=` → `{rating}` |
| A lobby or party at once | `POST /v1/skill-rating/models/{modelId}/players:batchGet` `{gameId, externalPlayerIds, seasonId?}` → `{ratings}`, in request order |
| Leaderboard | `GET /v1/skill-rating/models/{modelId}/leaderboard?gameId=&limit=&cursor=&seasonId=` → `{entries, nextCursor}` |
| Match history | `GET /v1/skill-rating/models/{modelId}/matches?gameId=&externalPlayerId=&limit=&cursor=&seasonId=` |

- **`gameId` is required** on every by-model endpoint (400 `game_id is required`). Ratings are stored per (model, season, **game**, player).
  - Two game modes that share a model in the same game share one ladder.
  - The same model used by two games keeps two separate ladders.
- **Display `ordinal`** (μ − 3σ), not μ. A new player's ordinal is about 0 and climbs as σ shrinks.
  - A player never rated gets the model's defaults: μ 25, σ 8.333333, `matchesCount` 0, null timestamps.
  - Unknown players come back with these defaults, not 404.
- **Leaderboard:** sorted by ordinal, highest first. Only players with a stored rating appear.
  - `limit` defaults to 50 (max 200).
  - Pass `nextCursor` back as `cursor` until it is `""`.
- **Seasons:** reads default to the model's **active** season. Pass `seasonId` (from earlier responses) to read a past season.
  - Seasons are started and ended only in the dashboard (model page → seasons). Starting a new season resets the ladder.

Details and examples: [references/ratings-api.md](references/ratings-api.md).

## 4. Seed or migrate existing ratings

`PUT /v1/skill-rating/models/{modelId}/players/{externalPlayerId}` with `{gameId, mu, sigma, displayName?, seasonId?}` upserts a stored rating and derives `ordinal`. It needs the Engineer role.

- **Use it for:**
  - importing ratings from a previous system before launch
  - an admin correction
  - carrying players into a new season with a soft reset
- **Don't use it** to apply match results. That is what `matches:report` does: it reads the current ratings, computes and stores them in one transaction.
- **Mapping other systems:** map to OpenSkill scale (μ around 25, σ above 0, typically ≤ 8.33). Use a higher σ for players you're less sure about.
- **No server-side range check**, so validate `sigma > 0` yourself. A stored σ ≤ 0 breaks ticket creation for that player.
- `matchesCount` is not changed.

## 5. Verify and troubleshoot

**Checklist:**
- [ ] `player-rating:resolve` returns `found: true` for the exact `gameMode` string tickets use.
- [ ] The report comes from server-side code; no key in client builds.
- [ ] `externalPlayerId` equals the ticket `playerId` / payload `player_id` for every player.
- [ ] `ranks.length === teams.length` and lower = better.
- [ ] A unique `externalMatchId` per match, and the dedupe check before retrying ambiguous failures.
- [ ] After a test match, `muAfter`/`sigmaAfter` changed and the leaderboard (with `gameId`) shows the players.
- [ ] Test in a separate staging game: there is no sandbox.

| Symptom | Cause / fix |
|---|---|
| 400 `no skill model is configured for game X mode Y; select a skill model on the Ticket Input node…` | No live matchmaker handles that mode, or it has no Skill Rating Model node with a model selected. The message mentions Ticket Input, but the model is now chosen on the **Skill Rating Model** node. Fix the mode string, or add the node and publish. |
| 400 `ranks must have one entry per team` / `at least two teams are required` / `team N has no players` | Fix the request shape. |
| 400 `game_id is required` on a by-model endpoint | Add the `gameId` query param or body field. |
| 400 `skill model … is paused; resume it to record ratings` | The model is paused in the dashboard. Reads still work. |
| 400 `model has no active season` | The season was ended without starting a new one. Start a season in the dashboard. |
| 403 `insufficient permissions` | The key's creator is a Viewer. Writes need Engineer. |
| 403 `user not authorized to access game` | The game belongs to another org, or the `gameId` is wrong. |
| 404 `skill model not found` / `season not found` | Wrong `modelId`, a model from another org, or a season of a different model. |
| Ratings never change / ladder empty | Reports aren't sent, or are sent with a different `gameMode`/`gameId` than the reads use. |
| Ratings move twice for one match | A retry re-sent a report that had already succeeded. Add the dedupe check. |

## References

- [references/report-match-result.md](references/report-match-result.md): full report examples, validation, the retry and dedupe policy
- [references/ratings-api.md](references/ratings-api.md): resolve, get, batchGet, leaderboard, upsert, record and list matches
- [references/models-and-seasons.md](references/models-and-seasons.md): model fields, engines and algorithms, defaults, ordinal, how matchmaking uses ratings, seasons
