# Matchmaker design

A matchmaker is a node graph built in the dashboard (**Matchmaking → Create matchmaker**) for one game. Tickets enter at **Ticket Input**, flow left to right, and become matches at **Output**. There is no public API to create or publish matchmakers: give the user a checklist, then verify with a test ticket.

Rules the editor enforces:
- Exactly one Ticket Input and at least one Output, connected by a path.
- Every node must be complete. Draft → **Publish** → **Live**. Paused and draft matchmakers don't match, and tickets for their mode are rejected.
- Keep **one Live matchmaker per (game, game mode)**.

## Nodes

| Node | Settings | What it does |
|---|---|---|
| **Ticket Input** | Game mode (string, default `default`); custom attributes (name + type String/Number/Boolean) | Entry point. The **game mode routes tickets**: the backend's `gameMode` must equal it exactly. Custom attributes define the allowed keys and types of the ticket's `attributes` object. |
| **Team Composition** | Teams 2–8; min and max players per team 1–64 | The shape of a match. 1v1 = 2 teams × 1. 5v5 = 2 teams × 5. |
| **Bucket by Field** | Field; Source (String, Number, Tag); Strategy (Exact match, Numeric width + Width, Ranges + boundaries) | Partitions tickets: only tickets in the same bucket can match. Use it for region (`preferred_az`), platform, a custom attribute, or a rating band. |
| **Split** | 1–6 conditional branches + a catch-all; each branch: field, operator, value | Routes tickets down different paths (each path ends in its own Output). String/Boolean fields: `is` / `is not`. Number fields: `= ≠ > ≥ < ≤`. The first matching branch wins. |
| **Skill Rule** | Fairness rule `none`, `rating_delta` (`maxRatingDelta`), `win_prob` (`winProbMin`–`winProbMax`), `draw_prob` (`minDrawProb`); Max Skill Delta 0–5000 | Only allows matches whose ratings are close enough. Its presence makes the queue "rated": the backend then resolves each ticket's rating server-side. |
| **Skill Rating Model** (the Skill Model node; the skill model is attached here, **not** on Ticket Input) | A skill model (create it first; see the `gameflow-skill-rating` skill) | Binds the queue to a model. Its output connects to the Skill Rule. Tickets then carry the player's **stored** rating, and `skill-rating/matches:report` finds the model from this node. Team Composition must match the model's team shape. |
| **Expansion Rule** | Based on: Ticket Age; max expansion seconds 1–3600; skill-delta growth per second 0–1000 | Widens the skill window as tickets wait. It has no effect without a Skill Rule. |
| **Output** | none | Finalizes the match. GameFlow then provisions a server and assigns all tickets. |

Fields a node can read:
- **System fields** on every ticket: `player_id`, `game_id`, `game_mode`, `preferred_az`, `mu`, `sigma`, `rating_bucket`.
- **Your custom attributes.** For Bucket and Split, Number attributes use source Number. String **and Boolean** attributes use source String, and a Boolean compares as the strings `"true"`/`"false"`.
- **Tags** (`tags` on the ticket) with Bucket Source = Tag.

## Recipes

Give the user the matching recipe as a checklist. Replace the mode names with theirs.

### Casual FIFO (2v2)
```
Ticket Input (mode: casual-2v2) → Team Composition (teams 2, min 2, max 2) → Output
```
- Players match in arrival order. Ratings are ignored. Send no `mu`, `sigma` or `ratingBucket`.
- Add `Bucket by Field (preferred_az, String, Exact)` after Ticket Input if latency matters.

### 1v1 ranked
```
Ticket Input (mode: ranked-1v1)
  → Bucket by Field (field preferred_az, source String, strategy Exact match)
  → Skill Rule (fairness win_prob 0.4–0.6, Max Skill Delta 100) ◀── Skill Rating Model (your 1v1 model)
  → Expansion Rule (Ticket Age, 60 s, growth 5/s)
  → Team Composition (teams 2, min 1, max 1)
  → Output
```
- Create the skill model first (2 teams × 1 player).
- Tickets need **no** `mu`/`sigma`: they are resolved from stored ratings, and new players get the model's initial rating.
- The server reports results with `skill-rating/matches:report`.

### 5v5 with skill and region
```
Ticket Input (mode: ranked-5v5)
  → Bucket by Field (preferred_az, String, Exact)
  → Skill Rule (rating_delta, maxRatingDelta 100, Max Skill Delta 300) ◀── Skill Rating Model (2 × 5 model)
  → Expansion Rule (Ticket Age, 120 s, growth 5/s)
  → Team Composition (teams 2, min 5, max 5)
  → Output
```
- `rating_delta` rejects lopsided groups rather than rebalancing them. A tight value means fewer matches form.
- The built-in **Ranked 5v5** sample buckets on `rating_bucket`. That field is client-claimed and unverified, so either drop that bucket or have the backend compute `ratingBucket` itself.

### Free-for-all
Team Composition needs at least 2 teams, so an FFA of up to 8 players is **N teams × 1 player**:
```
Ticket Input (mode: ffa-6) → Bucket by Field (preferred_az) → Team Composition (teams 6, min 1, max 1) → Output
```
- For more than 8 players, use 2–8 teams with several players each and ignore teams on the server. Whether that fits the game is the user's call.
- `team_index` in the payload is then just a seat group.

### Several modes in one matchmaker
```
Ticket Input → Split (branch 0: game_mode is "ranked" ; catch-all) → [Team Composition → Output] per branch
```
- Split can route on `game_mode`, but routing to a matchmaker starts at the Ticket Input mode. Separate Live matchmakers per mode are simpler and are what the docs recommend.
- Splitting on a custom attribute (e.g. `crossplay is "false"`) is the common use.

## Custom attributes: ticket → server

1. Declare each attribute on **Ticket Input**, e.g. `character: String`, `level: Number`, `crossplay: Boolean`. Then publish again.
2. The backend sends `"attributes": {"character": "mage", "level": 12, "crossplay": true}` on the ticket.
   - Undeclared keys → 400 `unknown attribute`. Wrong type → 400 `attribute "level" must be a number`.
   - Omitted keys are allowed.
3. Bucket and Split nodes can match on them (see the source rules above).
4. The game server receives them **per player** in the payload, with types preserved: `teams[].players[].attributes` (absent when the ticket had none).

Validate or construct attributes in the backend. A client that picks its own `character` is fine. A client that claims `level: 99` is not: look it up yourself.

## Verify a design

1. Publish, then create one ticket per seat (e.g. 2 for a 1v1) with distinct `playerId`s and the same `preferredAz`.
2. Long-poll each ticket's status. All of them should return the same `connection`.
3. Cancel leftovers with `DELETE …?playerId=…`.
4. Watch the queue count on the matchmaker's dashboard page while testing.
