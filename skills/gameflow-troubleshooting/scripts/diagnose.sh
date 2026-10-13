#!/usr/bin/env sh
# Read-only GameFlow integration snapshot: key check, games, and for one game
# its config (ports, protocol, regions, offline, scaling), recent builds and servers.
# Usage: GAMEFLOW_API_KEY=gf_... sh diagnose.sh [gameId]
# Requires: curl. Uses jq for readable output when available.
# The key is passed to curl on stdin (-K -), so it never appears in output or in `ps`.
set -eu

API="${GAMEFLOW_API_URL:-https://api.gameflow.gg/v1}"

if [ -z "${GAMEFLOW_API_KEY:-}" ]; then
  echo "GAMEFLOW_API_KEY is not set. Create a key at https://app.gameflow.gg/settings#api" >&2
  exit 1
fi

case "$API" in
  */v1) ;;
  *) echo "warning: API base '$API' does not end in /v1; expect 404s" >&2 ;;
esac

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# get PATH -> prints body on 2xx; prints status + error body and returns 1 otherwise.
get() {
  out=$(printf 'header = "x-api-key: %s"\n' "$GAMEFLOW_API_KEY" |
    curl -sS -K - -w '\n%{http_code}' "$API$1") || { echo "  network error calling GET $1" >&2; return 1; }
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "  GET $1 -> HTTP $code: $body" >&2
    case "$code" in
      401) echo "  hint: key missing, mistyped, expired or revoked" >&2 ;;
      403) echo "  hint: role too low, or the game belongs to another organization" >&2 ;;
      404) echo "  hint: wrong id, or base URL missing /v1" >&2 ;;
    esac
    return 1
  fi
  printf '%s' "$body"
}

show() { # show JQ_FILTER (falls back to raw JSON without jq)
  if [ "$HAVE_JQ" = 1 ]; then jq "$1"; else cat; echo; fi
}

echo "== Identity"
if ! me=$(get /identity/me); then
  echo "Stopping: fix authentication first." >&2
  exit 1
fi
printf '%s' "$me" | show '{email: .user.email, role: .user.role, organization: .organization.name, autoscalingEnabled: .organization.autoscalingEnabled, isOwner}'

echo "== Regions available"
get /regions/available | show '.regions' || true

echo "== Games"
get "/games?pageSize=50" | show '[.games[]? | {id: .game.id, title: .game.title, engine: .game.engine, live, serversCount, playersCount}]' || true

GAME_ID="${1:-}"
if [ -z "$GAME_ID" ]; then
  echo "(pass a gameId to inspect one game's config, builds and servers)"
  exit 0
fi

echo "== Game $GAME_ID config"
get "/games/$GAME_ID" | show '.game.game | {title, engine, engineVersion, offline,
  port: .config.port, protocol: .config.protocol, additionalPorts: .config.additionalPorts,
  regions: .config.regions, maxPlayers: .config.maxPlayers, vcpu: .config.vcpu, memory: .config.memory,
  launchOptions: .config.launchOptions, envVarNames: ((.config.environmentVariables // {}) | keys),
  scalingStrategy: .fleetConfig.scalingStrategy, bufferSize: .fleetConfig.bufferSize,
  minReplicas: .fleetConfig.minReplicas, maxReplicas: .fleetConfig.maxReplicas}' || true

echo "== Recent builds"
get "/images/builds?gameId=$GAME_ID&pageSize=10" | show '{current: .currentBuild.buildId,
  builds: [.builds[]? | {buildId, status, isCurrent, createdAt, uploadSource}]}' || true

echo "== Servers"
get "/games/$GAME_ID/servers?limit=50&sort=latest" | show '[.servers[]? | {name, state, region, host, port,
  ports, buildId, playerCount, playerCapacity, historical}]' || true

echo "== Next steps"
echo "  Failed build:  GET $API/images/builds/<buildId>  then  .../logs"
echo "  Bad server:    GET $API/games/$GAME_ID/servers/<name>/events?region=<region>"
echo "                 GET $API/games/$GAME_ID/servers/<name>/logs/history"
