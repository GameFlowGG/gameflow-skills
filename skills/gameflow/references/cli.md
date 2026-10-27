# GameFlow CLI and CI

## Install

**macOS / Linux:**
```bash
curl -fsSL https://install.gameflow.gg | sh
export PATH="$HOME/.gameflow/bin:$PATH"
gameflow version
```
The installer puts the binary in `~/.gameflow/bin` and appends a PATH line to `~/.zshrc`, `~/.bashrc` or `~/.bash_profile`. **The current shell isn't updated**, so `curl … | sh && gameflow login …` fails unless you export PATH first, as shown above.

**Windows:** download `gameflow-windows-<arch>` from https://github.com/GameFlowGG/gameflow-cli-releases/releases and put it on PATH. Or use WSL with the Linux steps. The install script exits on Windows, Git Bash included.

## Discover commands with `gameflow schema`

`gameflow schema` prints every command, flag, environment variable and exit code as JSON. **Run it before using a command or flag that isn't listed below**, rather than guessing or parsing `--help`.

## Authentication

**On a dev machine, run `gameflow login`.** It opens the browser, the user approves, and the CLI stores a session that renews itself. Don't ask the user to create an API key or set an environment variable for this. Check it with `gameflow whoami`.

**In CI, scripts and headless shells, use an API key** (the second option). Set `GAMEFLOW_API_KEY` and there is no `login` step.

The CLI uses the first credential it finds:
1. `GAMEFLOW_TOKEN`: a short-lived token that GameFlow's in-app terminal sets. Don't set it yourself.
2. `GAMEFLOW_API_KEY` from the environment. **It wins over a stored login**, so a stale value silently overrides `gameflow login`.
3. The session stored by `gameflow login` in `~/.gameflow/config.yaml`.
4. A key stored by `gameflow login --api-key-stdin`.

To store a key instead of using the browser (no browser available), pipe it so it stays out of shell history and the process list:
```bash
printf '%s' "$GAMEFLOW_API_KEY" | gameflow login --api-key-stdin
gameflow whoami
```

`GAMEFLOW_API_URL` overrides the base URL, which defaults to `https://api.gameflow.gg/v1`. If calls hit the wrong environment, check that variable in the shell profile first.

## Output and exit codes

- Commands print JSON on stdout, errors included: `{"code":"unauthenticated","error":"…"}`. Add `--pretty` to indent it. The exception is `servers logs` (see below).
- `--debug` logs the underlying HTTP calls to stderr. A progress bar also goes to stderr, only when it's a terminal.
- **Exit codes:** `2` usage or invalid argument, `3` unauthenticated or permission denied, `4` not found, `5` network, `6` build failed, `7` timeout, `1` anything else.

## Commands

| Command | What it does |
|---|---|
| `gameflow whoami` | Shows the authenticated user and organization |
| `gameflow login` | Signs in through the browser and stores a session in `~/.gameflow/config.yaml` |
| `gameflow login --api-key-stdin` (or `--api-key <key>`) | Stores an API key instead, for headless machines |
| `gameflow logout` | Revokes the browser session and removes stored credentials. It has no effect on `GAMEFLOW_API_KEY` |
| `gameflow games list [--page N] [--page-size N]` | Lists the organization's games, with their ids |
| `gameflow games get --game-id <id>` | Shows one game |
| `gameflow games create --title <t> --engine <e> --port <p> [--protocol UDP\|TCP] [--vcpu 500m] [--memory 512Mi] [--region <r>…] [--engine-version <v>] [--description <d>] [--tag <t>…]` | Creates a game. `--engine` is `Unity`, `Unreal`, `Godot`, `Colyseus` or `Custom`; `--region` defaults to `us-east` |
| `gameflow matchmakers create --game-id <id> --name <n> [--description <d>]` | Creates a matchmaker record. Its flow is set up in the dashboard |
| `gameflow models create --name <n> --match-format <f> [--scored-by <s>] [--rating-algorithm <a>] [--number-of-teams N] [--players-per-team N] [--status <s>]` | Creates a skill rating model. `--match-format` is `MATCH_FORMAT_TEAMS`, `MATCH_FORMAT_FFA` or `MATCH_FORMAT_BATTLE_ROYALE`; it goes live unless `--status SKILL_MODEL_STATUS_DRAFT` |
| `gameflow regions list` | Lists the available regions |
| `gameflow builds create --game-id <id> --file <archive> --version <v>` | Uploads a build and **waits for the image build to finish** (see below) |
| `gameflow builds list --game-id <id> [--page-size N] [--page-token T]` | Lists a game's builds |
| `gameflow builds status --build-id <id>` | Shows one build's status and message |
| `gameflow builds tag --game-id <id> --build-id <id> --tag <t>…` | **Replaces** a build's tags (repeat `--tag`) |
| `gameflow servers list --game-id <id> [--search S] [--sort latest\|oldest\|name\|status] [--limit N]` | Lists servers |
| `gameflow servers launch --game-id <id> --region <r> [--payload '<json>']` | Starts a server and returns at once, before it's Ready |
| `gameflow servers logs --game-id <id> --region <r> --server-name <n> --tail 200` | Prints a server's logs |
| `gameflow servers stop --game-id <id> --region <r> --server-name <n> [--dry-run]` | Stops a server |
| `gameflow version` | Shows the CLI version |

**`builds create`:**
- It handles both single and multipart uploads, then polls until the build is `success` or `failed`.
- It prints `{buildId, s3Path, status, message, imageUri, tags}`. A failed build exits with code `6`. Its `message` and `GET /v1/images/builds/{buildId}/logs` say why.
- `--no-wait` returns right after the build starts. `--timeout 30m` caps the wait (exit `7`), but the build keeps running: check it with `builds status` instead of uploading again. `--tag stable` tags the build in the same step.
- Give each upload its own `--version`, e.g. a tag or commit SHA. A duplicate isn't rejected (the build id gets a prefix), but it makes builds hard to tell apart.
- It doesn't make the build current. Promoting is dashboard-only (see the `gameflow-servers` skill). Tags are labels only.

**`servers`:**
- `launch` is the start call without the wait. It doesn't allocate from the fleet; fleet allocation is API-only (see the `gameflow-servers` skill). It prints the server's `name`, `state`, `address` and `port`. Poll `servers list --search <name>` until `state` is `Ready`.
- `logs` **streams raw text forever by default.** In scripts and agent runs, always pass `--tail N` or `--no-follow`. These print one JSON object per line, `{"message":"…"}`, not a single JSON document.
- Run `stop` with `--dry-run` first to check you have the right server.

## GitHub Actions

**Install and authenticate only:**
```yaml
- uses: GameFlowGG/gameflow-setup-action@v1
  with:
    api-key: ${{ secrets.GAMEFLOW_API_KEY }}
```

**Full deploy (install, upload, wait for the build, output the build id):**
```yaml
- name: Deploy server build to GameFlow
  id: gameflow
  uses: GameFlowGG/gameflow-deploy-action@v1
  with:
    api-key: ${{ secrets.GAMEFLOW_API_KEY }}
    game-id: ${{ vars.GAMEFLOW_GAME_ID }}
    file: ./dist/server.zip
    version: ${{ github.ref_name }}
- run: echo "Build ${{ steps.gameflow.outputs.build-id }}"
```

**Notes:**
- Store the key as a repository or environment **secret** named `GAMEFLOW_API_KEY`, ideally a dedicated `ci` key with an expiry.
- The game id is not secret. A repository **variable** is fine.
- Use a unique `version` per upload, e.g. tags or `${{ github.sha }}`. Duplicates are accepted but hard to tell apart.
- The actions' `version` / `cli-version` inputs are reserved: the latest CLI is always installed.

## Other CI systems

Install the CLI, export PATH, set `GAMEFLOW_API_KEY` from the CI secret store, then run `gameflow builds create …`. No `login` step is needed. Or call the REST upload flow directly (see the `gameflow-servers` skill).
