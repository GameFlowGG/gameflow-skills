# GameFlow CLI and CI

## Install

**macOS / Linux:**
```bash
curl -fsSL https://install.gameflow.gg | sh
export PATH="$HOME/.gameflow/bin:$PATH"
gameflow --version
```
The installer puts the binary in `~/.gameflow/bin` and appends a PATH line to `~/.zshrc`, `~/.bashrc` or `~/.bash_profile`. **The current shell isn't updated**, so `curl … | sh && gameflow login …` fails unless you export PATH first, as shown above.

**Windows:** download `gameflow-windows-<arch>` from https://github.com/GameFlowGG/gameflow-cli-releases/releases and put it on PATH. Or use WSL with the Linux steps.

## Commands

These are the documented commands. For anything else, run `gameflow --help` rather than guessing flags.

| Command | What it does |
|---|---|
| `gameflow login --api-key <key>` | Stores the key locally for later commands |
| `gameflow whoami` | Shows the authenticated user and organization |
| `gameflow logout` | Removes the stored key |
| `gameflow builds create --game-id <gameId> --file <archive> --version <version>` | Uploads a server build archive and starts the image build; prints the build id |

The CLI talks to `https://api.gameflow.gg/v1` by default.

## GitHub Actions

**Install and authenticate only:**
```yaml
- uses: GameFlowGG/gameflow-setup-action@v1
  with:
    api-key: ${{ secrets.GAMEFLOW_API_KEY }}
```

**Full deploy (install, login, upload the build, output the build id):**
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
- `version` must be unique per game. Reusing one fails, so use tags or `${{ github.sha }}`.
- The actions' `version` / `cli-version` inputs are reserved: the latest CLI is always installed.

## Other CI systems

Run the same three steps: install, export PATH, then `gameflow login --api-key "$GAMEFLOW_API_KEY"` and `gameflow builds create …`. Or call the REST upload flow directly (see the `gameflow-servers` skill).
