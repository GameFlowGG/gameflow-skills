# Models, engines and seasons

Models and seasons are managed **only in the dashboard**: Rating Models, at https://app.gameflow.gg/rating-models. The API endpoints for creating, updating or listing models and seasons are internal and not part of the public API. Agents should give the user a checklist and verify the result with `player-rating:resolve`.

## The skill model

A model is org-scoped: it has no game id. Ratings inside it are still kept per game.

| Field (API name) | Default | Set where | Effect on scoring |
|---|---|---|---|
| `name` | n/a | Create form, "Mode name" | Label only |
| `ratingEngine` | `builtin_openskill` | Fixed ("GF Engine") | Tier label. `tuned` / `ai_trained` are future tiers, not available. |
| `ratingAlgorithm` | `plackett_luce` | Not editable in the create form. The matchmaker's Skill Rating Model node shows it read-only as "Algorithm". | The OpenSkill model used to compute updates |
| `matchFormat` | n/a | Create form: Teams / Free-for-all / Battle Royale | Descriptive; not enforced on reports |
| `numberOfTeams`, `playersPerTeam`, `teamsCanBeUneven` | 2, 1, false | Create form (locked afterwards) | Used by the matchmaker editor to check Team Composition; **not** enforced by `matches:report` |
| `scoredBy` | `WIN_LOSS` | Create form: Win/loss, Final placement, Numeric score | Descriptive. You always express the result as `ranks` (lower = better). For numeric scores, convert them to ranks yourself (highest score → rank 0). |
| `supportsParties`, `maxPartySize` | false, 1 | Create form | Descriptive |
| `status` | `LIVE` | Model page (pause/resume) | `PAUSED` rejects report, upsert and record (400). Reads keep working. |
| `initialMu` | 25 | Configuration → Mu μ | Starting μ for players with no rating. Not retroactive. |
| `initialSigma` | 8.333333 | Configuration → Sigma σ | Starting σ. Also scales β and τ (below). Keep it near μ/3. |
| `beta` | 0.5 | Configuration → Beta (× sigma) | Effective β = `beta × initialSigma` (≈ 4.17 by default). Lower = bigger moves per result. |
| `ratingVolatility` | `MEDIUM` | Configuration → Rating volatility | τ = `initialSigma / 100` × 0.5 (Low) / 1 (Medium) / 2 (High): how much σ grows back each match. |
| `limitSigma` | true | Configuration → Limit Sigma | Prevents σ from increasing after a match |
| `settlingSpeed`, `teamCreditSharing` | `FAST`, `EVEN` | Configuration | **Saved but not applied** to scoring yet |

Changes to β, volatility and Limit Sigma apply from the next reported match. Changes to μ/σ only affect players who have no rating yet.

### Rating algorithms

The compute engine accepts these OpenSkill models:
- `plackett_luce` (default)
- `bradley_terry_full`
- `bradley_terry_part`
- `thurstone_mosteller_full`
- `thurstone_mosteller_part`

A customer cannot currently choose one from the dashboard's model form (unverified whether any UI exposes it), so in practice every model uses **Plackett–Luce**. That model handles any number of teams and ties, which covers 1v1, team and free-for-all/battle-royale modes.

Separately, the matchmaker's Team Configuration / Skill Rule fairness setting also uses an algorithm name to *predict* match balance. That one does not change how ratings are updated.

## μ, σ and ordinal

- **μ:** the skill estimate. **σ:** the uncertainty, which shrinks as a player plays.
- **`ordinal = μ − 3σ`**, computed exactly that way server-side. It is the conservative rating (true skill is about 99.7% likely to be above it).
  - The leaderboard sorts by it, and it is what to display.
  - A new player is about 0 (25 − 3 × 8.333333) and climbs as σ shrinks, even at 50% win rate.
  - A display rating is any transform of ordinal you like (e.g. `max(0, round(ordinal * 40 + 1000))`). Keep the transform on your side.
- For tiers or divisions, bucket on ordinal and consider requiring a minimum `matchesCount` (placement matches).

## How matchmaking uses ratings

This happens when the backend creates a ticket (`POST /v1/matchmaking/tickets`). See the `gameflow-matchmaking` skill.

| The queue's published flow has… | Rating the ticket enters with |
|---|---|
| A **Skill Rule** and a **Skill Rating Model** node | The player's **stored** rating from that model (active season, this game). Unknown players get the model's initial μ/σ. **Ticket `mu`/`sigma` are ignored**, so clients can't claim a skill. |
| A **Skill Rule** but **no** Skill Rating Model node | The ticket's `mu`/`sigma` as sent (`sigma` must be > 0, else 400). There is no stored rating, and `matches:report` fails for this mode. |
| **No Skill Rule** (FIFO), with or without a model | None: matching is first-come-first-served. Ticket `mu`/`sigma` are ignored. If a model node is present, `matches:report` still works and ratings are still tracked. |

So for a normal ranked queue, **don't send `mu`/`sigma` on tickets.** The ticket `playerId` must be the same id you later report as `externalPlayerId`. Matchmaking reads the rating with it, and the server payload's `player_id` carries it.

Ratings change only when a result is reported, so matchmaking quality depends on every finished match being reported once.

## Seasons

- **Creation:** creating a model creates an active **"Season 1"**.
- **Scope:** every stored rating and match record belongs to one season. Reports always write to the **active** season.
- **Starting a new season** (dashboard: model page → seasons → New season name → Start) ends the previous active season.
  - Effectively a **ladder reset**: every player starts again from the model's initial μ/σ.
  - Old seasons stay readable.
- **Ending the active season without starting a new one** makes reports and active-season reads fail with 400 `model has no active season`. Always start the next season instead.
- **Reading old seasons:** pass `seasonId` to GET player, batchGet, leaderboard or list matches.
  - Season ids appear as `seasonId` in report responses and on every rating object. There is no public list-seasons endpoint, so store season ids when you see them change.
  - `player-rating:resolve` always uses the active season.
- **Soft reset** (carry some skill over): after starting the new season, upsert each returning player with e.g. `mu = 25 + (oldMu − 25) * 0.5` and `sigma = max(oldSigma, 6)`. See [ratings-api.md](ratings-api.md#upsert-seed-migrate-correct). This is a pattern, not a built-in feature.

## Scope summary

| Key | Meaning |
|---|---|
| Model | Org-scoped configuration. One model can back several matchmakers and games. |
| Model + game | A separate ladder per game |
| Game modes | Modes of the same game whose matchmakers select the same model share one ladder. Use separate models for separate ranked ladders. |
| Season | Each season is a fresh ladder inside the model |
