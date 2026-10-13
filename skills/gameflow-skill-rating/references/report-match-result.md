# Reporting a match result

`POST https://api.gameflow.gg/v1/skill-rating/matches:report`

- **Auth:** `x-api-key`, with at least the **Engineer** role.
- **Callers:** the dedicated game server or the customer's backend. Never a game client.

## What happens on a call

1. Validates the request shape and checks the key's org owns `gameId`.
2. Resolves the skill model for `(gameId, gameMode)`:
   - It takes the live (published) matchmaker whose Ticket Input node handles the mode.
   - Then it reads the model selected on that matchmaker's **Skill Rating Model** node. If several match, the most recently updated matchmaker wins.
3. Rejects the call if the model is paused, then picks the model's **active** season.
4. Loads each player's current rating in that season and game. A player without one uses the model's initial μ/σ.
5. Computes new ratings, using the model's algorithm (default `plackett_luce`), β, volatility and Limit Sigma.
6. **In one database transaction**, inserts a match record and upserts every player's rating. Each player's `matchesCount` goes up by 1.
7. Best-effort and after the commit, it patches match analytics when `matchId` was sent. A failure here never fails the call.

## Request

| Field | Type | Required | Notes |
|---|---|---|---|
| `gameId` | string | yes | Your GameFlow game id. It is not in the payload, so configure it on the server (e.g. a game env var). |
| `gameMode` | string | yes | Must equal the mode on the matchmaker's Ticket Input node (trimmed, case-sensitive). The payload has it as `game_mode`. |
| `teams` | `[{players:[{externalPlayerId, displayName?}]}]` | yes | At least 2 teams, each with at least 1 player. |
| `ranks` | `int[]` | yes | One per team, same order. **Lower = better.** Equal values = tie. |
| `externalMatchId` | string | no, but always send it | Your own unique id for the match. Stored on the record and returned by the list-matches call; this is how you deduplicate. **Not** enforced unique. |
| `matchId` | string | no | GameFlow's `match_id` from the server payload. Links the result to match analytics (wait time, predictions, outcome). Without it ratings are identical; the analytics row just stays "formed". |

`displayName` is stored on the player's rating when non-empty. An empty value leaves any stored name unchanged.

### Validation (server-side)

| Rule | Error (HTTP 400, `code` 3) |
|---|---|
| `gameId` empty | `game_id is required` |
| `gameMode` empty | `game_mode is required` |
| Fewer than 2 teams | `at least two teams are required` |
| `ranks.length != teams.length` | `ranks must have one entry per team` |
| A team with no players | `team N has no players` |
| A player with an empty id | `player external_player_id is required` |

**Not validated:**
- A player appearing twice, in the same team or across teams. The result is undefined: one write overwrites the other. Deduplicate before sending.
- Team count or size against the model's declared shape.
- Rank values. Any integers work; only their order matters.

Unknown JSON fields are silently ignored, so a misspelled optional field (e.g. `matchID`) is simply lost.

### Other errors

| HTTP / `code` | Message | Written? |
|---|---|---|
| 400 / 9 | `no skill model is configured for game … mode …; select a skill model on the Ticket Input node of the live matchmaker and publish` | No. The text predates the Skill Rating Model node: add or select that node and publish. |
| 400 / 9 | `skill model <id> is paused; resume it to record ratings` | No |
| 400 / 9 | `model has no active season` | No |
| 401 / 16 | missing or invalid key | No |
| 403 / 7 | `insufficient permissions` (role) / `user not authorized to access game` | No |
| 404 / 5 | `game not found` | No |
| 503 / 14 | `resolve skill model: …` / `matchmaking service unavailable…` | No: retry |
| 504 / 4 | `skill rating compute timed out` | No: retry |
| 500 / 13 | compute failure, or `record match: …` (transaction rolled back) | No: retry |

## Response

```json
{
  "skillModelId": "cm9x…",
  "seasonId": "cm9y…",
  "matchId": "cma0…",
  "ratings": [
    { "externalPlayerId": "p1", "displayName": "Ana", "team": 0,
      "muBefore": 25, "sigmaBefore": 8.333333,
      "muAfter": 27.63, "sigmaAfter": 8.07, "ordinalAfter": 3.42 },
    { "externalPlayerId": "p2", "displayName": "Beto", "team": 1,
      "muBefore": 25, "sigmaBefore": 8.333333,
      "muAfter": 22.37, "sigmaAfter": 8.07, "ordinalAfter": -1.84 }
  ]
}
```

- **`matchId`** in the response is the rating ledger's record id. It is **not** the GameFlow `match_id` you sent.
- **`team`** is the 0-based index into your `teams` array.
- **All numbers are JSON numbers** (doubles and int32). No field here is an int64-as-string.
- The values above are illustrative.

## Retries and idempotency

**`matches:report` is NOT idempotent.**
- `externalMatchId` has no unique constraint.
- Every call that succeeds inserts a new match record and applies the rating update again, on top of the already-updated ratings.
- Unlike `matches:start` / `matches:end`, there is no `alreadyRecorded` flag.

**What is safe:**
- **Any error response with a JSON `{code, message}` body means nothing was written.** Every failure path in the handler returns before the single atomic write.
  - Retry 429 and 5xx with exponential backoff and jitter.
  - Never retry 4xx unchanged.
- **No response** is ambiguous: a client timeout, a dropped connection, or a proxy 502/504 without the JSON envelope. The match may already be recorded. Before re-sending, check:

```ts
// skillModelId: cached from player-rating:resolve or a previous report response
async function alreadyReported(gameId: string, skillModelId: string, anyPlayerId: string, externalMatchId: string) {
  const q = new URLSearchParams({ gameId, externalPlayerId: anyPlayerId, limit: "50" });
  const { matches } = await gameflow<{ matches: { externalMatchId?: string }[] }>(
    `/skill-rating/models/${skillModelId}/matches?${q}`);
  return matches.some((m) => m.externalMatchId === externalMatchId);
}
```

**Practical policy:**
- **Unique id:** generate one `externalMatchId` per match (e.g. the payload `match_id`, or a UUID) and reuse it on every attempt.
- **HTTP timeout:** set it generously (≥ 15 s). The server allows the rating computation up to 8 s.
- **Queue on the backend:** if the backend reports on the server's behalf, put the report in a durable queue and deduplicate on `externalMatchId` before calling GameFlow.
- **On the game server:** await the report before SDK Shutdown. If it can't be delivered, hand the payload to your backend rather than dropping it.

## Examples

### curl

```bash
curl -sS -X POST https://api.gameflow.gg/v1/skill-rating/matches:report \
  -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "gameId": "<gameId>",
    "gameMode": "ranked",
    "externalMatchId": "m-2026-10-08-0001",
    "matchId": "<match_id from the payload>",
    "teams": [
      {"players": [{"externalPlayerId": "p1", "displayName": "Ana"}, {"externalPlayerId": "p3"}]},
      {"players": [{"externalPlayerId": "p2", "displayName": "Beto"}, {"externalPlayerId": "p4"}]}
    ],
    "ranks": [0, 1]
  }'
```

### TypeScript (backend or Node game server)

Build the report from the matchmaking payload. Uses the `gameflow()` helper from the `gameflow` skill's api-conventions reference.

```ts
type Payload = {
  match_id: string; game_mode: string;
  teams: { team_index: number; players: { player_id: string }[] }[];
};

// placementByTeamIndex: your game's result, e.g. {0: 0, 1: 1} = team 0 won.
// For a draw give both the same value.
export async function reportResult(
  gameId: string, payload: Payload, placementByTeamIndex: Record<number, number>,
  names: Record<string, string> = {},
) {
  const teams = payload.teams.map((t) => ({
    players: t.players.map((p) => ({
      externalPlayerId: p.player_id,                       // snake_case payload -> camelCase API
      ...(names[p.player_id] ? { displayName: names[p.player_id] } : {}),
    })),
  }));
  const ranks = payload.teams.map((t) => placementByTeamIndex[t.team_index]);

  return gameflow<{
    skillModelId: string; seasonId: string; matchId: string;
    ratings: { externalPlayerId: string; team: number; muAfter: number; sigmaAfter: number; ordinalAfter: number }[];
  }>("/skill-rating/matches:report", {
    method: "POST",
    body: JSON.stringify({
      gameId,
      gameMode: payload.game_mode,
      externalMatchId: payload.match_id,   // or your own unique id; reuse it on retries
      matchId: payload.match_id,
      teams,
      ranks,
    }),
  });
}
```

On a Node game server, the payload comes from `await gf.payload()` (or `gf.onPayloadChange`) of `@gameflow.gg/gameserver-sdk`. Never use `process.env.GAMEFLOW_PAYLOAD`, which is only a local-mode simulation.

### C# (Unity dedicated server build)

Only in a **Dedicated Server** build that runs on GameFlow. The key comes from the server's environment (a game env var), never from the client build. Use `#if UNITY_SERVER` so the code cannot ship to players.

```csharp
#if UNITY_SERVER
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;               // com.unity.nuget.newtonsoft-json

public static class SkillRatingReporter
{
    static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };

    // payloadJson: await gf.Payload() from the GameFlow Unity SDK (GameFlowClient)
    // placementByTeamIndex: lower = better; equal = draw
    public static async Task<string> Report(string payloadJson, Dictionary<int, int> placementByTeamIndex)
    {
        var p = JsonConvert.DeserializeObject<Payload>(payloadJson);
        var teams = new List<object>();
        var ranks = new List<int>();
        foreach (var t in p.teams)
        {
            var players = new List<object>();
            foreach (var pl in t.players) players.Add(new { externalPlayerId = pl.player_id });
            teams.Add(new { players });
            ranks.Add(placementByTeamIndex[t.team_index]);
        }
        var body = JsonConvert.SerializeObject(new {
            gameId = Environment.GetEnvironmentVariable("GAMEFLOW_GAME_ID"),
            gameMode = p.game_mode,
            externalMatchId = p.match_id,
            matchId = p.match_id,
            teams, ranks
        });

        var req = new HttpRequestMessage(HttpMethod.Post,
            "https://api.gameflow.gg/v1/skill-rating/matches:report")
        { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        req.Headers.Add("x-api-key", Environment.GetEnvironmentVariable("GAMEFLOW_API_KEY"));

        // A non-2xx response with a {code,message} body means nothing was written; retry 429/5xx only.
        // A timeout is ambiguous: check list-matches for externalMatchId before re-sending.
        var res = await Http.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode) throw new Exception($"report failed {(int)res.StatusCode}: {text}");
        return text;
    }

    class Payload { public string match_id; public string game_mode; public List<Team> teams; }
    class Team { public int team_index; public List<Player> players; }
    class Player { public string player_id; }
}
#endif
```

`GAMEFLOW_GAME_ID` and `GAMEFLOW_API_KEY` are example names for env vars **you** add in the game's config. The platform does not inject them. If you would rather not give game servers a key, post the same body to your backend and let it call GameFlow.
