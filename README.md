# gameflow-skills

Official [GameFlow](https://gameflow.gg) skills for AI coding agents. With these installed, your agent can:
- deploy dedicated game servers
- set up matchmaking and skill rating
- fix server issues

They work in Claude Code, Cursor, Codex, OpenCode, GitHub Copilot, Gemini CLI and [other agents that support skills](https://skills.sh).

## Install

```bash
npx skills add GameFlowGG/gameflow-skills
```

Install one skill only:

```bash
npx skills add GameFlowGG/gameflow-skills --skill gameflow-servers
```

List what's available without installing:

```bash
npx skills add GameFlowGG/gameflow-skills --list
```

## Connect the GameFlow docs MCP (recommended)

The skills work alone, but with the docs MCP server your agent can also search the docs and look up any API endpoint's exact request and response. The server is read-only and needs no API key.

**Claude Code:**
```bash
claude mcp add --transport http gameflow https://api.gameflow.gg/mcp
```
Add `--scope project` to save it to `.mcp.json` and share it with your team.

**Cursor:** add to `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global):
```json
{ "mcpServers": { "gameflow": { "url": "https://api.gameflow.gg/mcp" } } }
```

**Other agents:** add a streamable HTTP MCP server named `gameflow` with the URL `https://api.gameflow.gg/mcp`.

Restart the agent afterwards. The tools are `search_docs`, `read_doc`, `list_docs` and `get_api_operation`.

## Skills

| Skill | Use it to |
|---|---|
| [`gameflow`](skills/gameflow) | Start here: account, API key, CLI, architecture, and routing to the other skills |
| [`gameflow-servers`](skills/gameflow-servers) | Integrate the Game Server SDK (Unity, Unreal, Godot, Node, Go, Rust), package and upload builds, start or allocate servers, deploy from CI |
| [`gameflow-matchmaking`](skills/gameflow-matchmaking) | Design a matchmaker, create, poll and cancel tickets from your backend, connect players, record match start and end |
| [`gameflow-skill-rating`](skills/gameflow-skill-rating) | Attach a skill model, report match results, read ratings and leaderboards |
| [`gameflow-troubleshooting`](skills/gameflow-troubleshooting) | Diagnose auth errors, failed builds, servers that never become Ready, stuck tickets, and connection problems |

## What you need

- A GameFlow account: https://app.gameflow.gg
- An API key from **Settings → API Keys**, exported as `GAMEFLOW_API_KEY`. Keep it server-side: never put it in a game client.

Some setup steps only exist in the dashboard today: creating a game, creating and publishing a matchmaker, and creating a skill model. For these, the skills hand you a short checklist and then verify the result through the API.

## Example prompts

- "Add GameFlow hosting to my Godot dedicated server and deploy it."
- "Set up 2v2 ranked matchmaking with GameFlow. My backend is Supabase."
- "Report match results to GameFlow skill rating from my Unity server."
- "My GameFlow tickets stay pending forever. Why?"

## Docs

- Docs: https://docs.gameflow.gg
- API reference: https://docs.gameflow.gg/api/gameflow-api
- Game Server SDKs: https://github.com/GameFlowGG/gameflow-gameserver-sdk

## Contributing

Each skill lives in `skills/<name>/`:
- `SKILL.md` holds the instructions and the `name` / `description` frontmatter.
- `references/` holds detail that's loaded on demand.
- `scripts/` holds helper scripts.

Keep `SKILL.md` under 500 lines, and run the validator before opening a PR:

```bash
node scripts/validate-skills.mjs
```

## License

[MIT](LICENSE)
