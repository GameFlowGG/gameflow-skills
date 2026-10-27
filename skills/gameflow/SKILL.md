---
name: gameflow
description: Online multiplayer backend for games, covering dedicated server hosting, matchmaking and player skill rating on GameFlow (gameflow.gg). Start here to set up a GameFlow account, API key and CLI, understand how the platform fits together and where the API key is allowed to live, and find the right GameFlow skill for the job. Use it when someone mentions GameFlow or GAMEFLOW_API_KEY, or is adding online multiplayer to a game and choosing a backend.
license: MIT
metadata:
  author: GameFlow
  version: "0.1.0"
---

# GameFlow

GameFlow is a managed multiplayer backend for games with three products:

- **Game Server Hosting:** run your dedicated server build in GameFlow's regions. It autoscales, and players connect to `host:port`.
- **Matchmaking:** a visual node-graph matchmaker. Your backend submits tickets, and GameFlow forms matches and allocates a server.
- **Skill Rating:** OpenSkill-style ratings, attached to a matchmaker and updated from match results.

Docs: https://docs.gameflow.gg · Dashboard: https://app.gameflow.gg · API: `https://api.gameflow.gg/v1`

## Route to the right skill

| The user wants to… | Use |
|---|---|
| Account, API key, CLI, "how does GameFlow work", architecture choice | this skill |
| Integrate the SDK into a dedicated server, package/upload builds, start or allocate servers, CI deploys | `gameflow-servers` |
| Queue players, create/poll/cancel tickets, connect players to matches, match start/end | `gameflow-matchmaking` |
| Ratings, MMR, leaderboards, reporting match results | `gameflow-skill-rating` |
| Something is broken (stuck tickets, server never Ready, failed builds, 401/404) | `gameflow-troubleshooting` |

If a skill isn't installed, install it with `npx skills add GameFlowGG/gameflow-skills --skill <name>`. If that's not possible, read the matching docs section at docs.gameflow.gg.

## GameFlow docs MCP

GameFlow runs a read-only MCP server at `https://api.gameflow.gg/mcp`. It needs no auth and has 4 tools: `search_docs`, `read_doc`, `list_docs` and `get_api_operation`. It serves the published docs and API reference. These can be newer than these skills, and sometimes newer than the deployed API.

**When the tools are connected:**
- Before writing a request body or code that calls an endpoint, call `get_api_operation` for it and compare its field names with the skill's.
  - If they differ, **don't choose yourself, and don't write code with either name yet.** The docs can document a change that isn't deployed, and unknown fields are dropped without an error, so the wrong name fails quietly.
  - Show the user both names, and ask which one their environment accepts. A test call whose response shows the field took effect settles it.
- Use `search_docs` for anything these skills don't cover before saying it isn't documented.
- Guide pages (`read_doc`) still have the old errors these rules correct (snake_case JSON, paths without `/v1`). Where a guide and the rules below disagree, follow the rules.

**When they aren't connected**, offer to set them up, once, at the start of GameFlow work. The user runs one of these:
- **Claude Code:** `claude mcp add --transport http gameflow https://api.gameflow.gg/mcp` (add `--scope project` to share it through `.mcp.json`)
- **Cursor:** `.cursor/mcp.json` with `{"mcpServers":{"gameflow":{"url":"https://api.gameflow.gg/mcp"}}}`
- **Other agents:** add a streamable HTTP MCP server with that URL.

The new tools usually appear only after the agent restarts.

## Non-negotiable rules

1. **The API key never ships in a game client.**
   - Keys grant full API access to the whole organization.
   - Only trusted server-side code holds one: the customer's game backend, the dedicated game server, and CI secrets.
   - Game clients (Unity/Godot/Unreal builds, browsers, mobile) call **the customer's own backend**, which calls GameFlow.
   - If you find a key in client code, stop and flag it. The fix is to move the call server-side and rotate the key.
2. **Read the key from the environment** (`GAMEFLOW_API_KEY`). Never hard-code or commit it. Add it to `.env.example` as a placeholder only.
3. **Base URL is `https://api.gameflow.gg/v1`.** Every path includes `/v1`. A 404 on a path you expected to exist usually means `/v1` is missing.
4. **JSON is lowerCamelCase** (`gameId`, `timeoutSeconds`, `externalPlayerId`), even where older docs show snake_case.
   - Responses are camelCase only, so `res.ticket_id` is `undefined`.
   - Unknown request fields are silently dropped, so typos look like "X is required".
   - 64-bit integers come back as **strings** (`"durationMs": "53210"`), so parse them.
5. **Don't invent endpoints, CLI subcommands or SDK methods.** If something isn't in these skills or the docs, say so and check `gameflow schema`, the docs MCP or API reference, or ask the user.
6. **There is no sandbox.** For testing, suggest a separate game in the dashboard (e.g. "MyGame (staging)") rather than testing against production players.

## First-time setup

Some steps can only be done by a human in the dashboard: the API has no public endpoint for them, and signup has a captcha. Give the user this checklist with the exact values, wait for confirmation, then verify through the API.

**Checklist for the user:**
1. Sign up or sign in at https://app.gameflow.gg. An organization is created automatically.
2. Go to **Settings → API Keys → Create Key**.
   - Name it for where it will live (e.g. `local-dev`, `ci`, `game-backend`).
   - Prefer an expiry.
   - **Copy the secret now:** it is shown once.
   - The org can hold up to 3 active keys.
3. Put it in your environment: `export GAMEFLOW_API_KEY=gf_...` (or your secret manager or `.env` file, which must be git-ignored).

**Verify (agent):**
```bash
curl -sS https://api.gameflow.gg/v1/identity/me -H "x-api-key: $GAMEFLOW_API_KEY"
```
- Success returns `{"user": {...}, "organization": {...}, "isOwner": ...}`.
- 401 means the key is missing, mistyped, expired or revoked.
- Or run [scripts/check-auth.sh](scripts/check-auth.sh), which also lists the org's games.

**Install the CLI** (needed for build uploads; optional otherwise):
```bash
curl -fsSL https://install.gameflow.gg | sh
export PATH="$HOME/.gameflow/bin:$PATH"   # the installer only edits rc files; this shell needs it now
gameflow whoami                            # uses GAMEFLOW_API_KEY from the environment; no login needed
```
- The CLI doesn't read `.env` files. If the key lives only in `.env`, export it in the shell first, or store it once with `printf '%s' "$GAMEFLOW_API_KEY" | gameflow login --api-key-stdin`.
- **Windows:** the `sh` script doesn't run there, Git Bash included. In PowerShell run `irm https://install.gameflow.gg | iex`, then open a new terminal (or prepend `$env:USERPROFILE\.gameflow\bin` to `$env:Path`).
- The CLI has more than build uploads: games, regions, build status and tags, and server launch, logs and stop. `gameflow schema` lists every command and flag as JSON. See [references/cli.md](references/cli.md).

## Choosing an architecture

Ask what the game needs, then recommend one of these:

- **Matchmade sessions** (ranked or casual queues): `gameflow-servers` + `gameflow-matchmaking` (+ `gameflow-skill-rating`).
  - Client → *your backend* → GameFlow ticket → long-poll → `host:port` back to the client.
  - The game server learns the match (id, teams) from its payload.
- **Lobby / "host a server now"** (no matchmaking): `gameflow-servers` only.
  - Client → *your backend* → allocate a ready server (fast) or start one (cold, up to ~2 min) → `host:port`.
- **No backend yet?** The customer needs *some* trusted server to hold the key. Options:
  - **Supabase edge functions:** documented at docs.gameflow.gg/backend-integrations/supabase.
  - **A small Node service:** see docs.gameflow.gg/backend-integrations/custom-backend and the public sample `GameFlowGG/gameflow-custom-game-backend`.
  - **Nakama:** a server-side TypeScript runtime module exposes RPCs that start and stop GameFlow servers. It's documented at docs.gameflow.gg/backend-integrations/nakama, and the key stays in Nakama's runtime config.
  - Talo and EOS integrations are listed as coming soon. Don't promise them.

Full flow diagrams and the responsibilities of each component are in [references/architecture.md](references/architecture.md).

## References

- [references/architecture.md](references/architecture.md): components, who calls what, data flow for each product
- [references/api-conventions.md](references/api-conventions.md): auth, casing, int64 strings, errors, pagination, regions
- [references/cli.md](references/cli.md): CLI install, auth, every command, output and exit codes; GitHub Actions
- [scripts/check-auth.sh](scripts/check-auth.sh): verify `GAMEFLOW_API_KEY` and list games
