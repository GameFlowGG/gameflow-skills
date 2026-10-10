#!/usr/bin/env sh
# Start a standalone GameFlow test server, wait until it is Ready, and print where to connect.
# The API call blocks until the server is Ready (up to ~120 s).
#
# Usage: GAMEFLOW_API_KEY=gf_... sh start-test-server.sh <gameId> [region] [payload] [buildId]
#   region:  defaults to the game's first configured region
#   payload: opaque string handed to the server via the SDK (e.g. '{"match_id":"test-1"}')
#   buildId: test a build that is not current yet
# Stop it afterwards with:
#   curl -X DELETE "$API/games/<gameId>/servers/<serverName>?region=<region>" -H "x-api-key: $GAMEFLOW_API_KEY"
# Requires: curl, jq.
set -eu

API="${GAMEFLOW_API_URL:-https://api.gameflow.gg/v1}"

die() { echo "error: $*" >&2; exit 1; }

[ -n "${GAMEFLOW_API_KEY:-}" ] || die "GAMEFLOW_API_KEY is not set"
[ $# -ge 1 ] || die "usage: $0 <gameId> [region] [payload] [buildId]"
command -v jq >/dev/null 2>&1 || die "jq is required"

GAME_ID=$1
REGION=${2:-}
PAYLOAD=${3:-}
BUILD_ID=${4:-}

call() {
  # call METHOD PATH [JSON] [max-seconds]
  if [ -n "${3:-}" ]; then
    out=$(curl -sS -m "${4:-30}" -w '\n%{http_code}' -X "$1" "$API$2" -H "x-api-key: $GAMEFLOW_API_KEY" \
      -H "Content-Type: application/json" -d "$3") || die "network error or timeout calling $1 $2"
  else
    out=$(curl -sS -m "${4:-30}" -w '\n%{http_code}' -X "$1" "$API$2" -H "x-api-key: $GAMEFLOW_API_KEY") \
      || die "network error or timeout calling $1 $2"
  fi
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  case "$code" in
    2*) printf '%s' "$body" ;;
    401) die "401: key missing, mistyped, expired or revoked" ;;
    *) die "$1 $2 -> HTTP $code: $body" ;;
  esac
}

if [ -z "$REGION" ]; then
  # GET /v1/games/{id} is double-wrapped: {game:{game:{config:{...}}}}
  REGION=$(call GET "/games/$GAME_ID" | jq -r '(.game.game.config.regions // .game.config.regions // [])[0] // empty')
  [ -n "$REGION" ] || die "could not read the game's regions; pass a region (see GET /v1/regions/available)"
fi

BODY=$(jq -n --arg r "$REGION" --arg p "$PAYLOAD" --arg b "$BUILD_ID" \
  '{region:$r} + (if $p != "" then {payload:$p} else {} end) + (if $b != "" then {buildId:$b} else {} end)')

echo "Starting a server for game $GAME_ID in $REGION (this can take up to ~2 minutes)..." >&2
RESP=$(call POST "/games/$GAME_ID/servers" "$BODY" 180)

printf '%s' "$RESP" | jq '.server | {name, state, region, host, port, ports, buildId, playerCapacity}'
HOST=$(printf '%s' "$RESP" | jq -r '.server.host // .server.address // empty')
PORT=$(printf '%s' "$RESP" | jq -r '.server.port // empty')
NAME=$(printf '%s' "$RESP" | jq -r '.server.name // empty')
PROTO=$(printf '%s' "$RESP" | jq -r '.server.ports[0].protocol // empty')

echo "" >&2
echo "Connect clients to: $HOST:$PORT (${PROTO:-unknown protocol}; for tls use wss:// or another TLS client)" >&2
echo "Details: curl -sS \"$API/games/$GAME_ID/servers/$NAME?region=$REGION\" -H \"x-api-key: \$GAMEFLOW_API_KEY\"" >&2
echo "Logs:    curl -sS \"$API/games/$GAME_ID/servers/$NAME/logs/history?region=$REGION\" -H \"x-api-key: \$GAMEFLOW_API_KEY\"" >&2
echo "Stop:    curl -sS -X DELETE \"$API/games/$GAME_ID/servers/$NAME?region=$REGION\" -H \"x-api-key: \$GAMEFLOW_API_KEY\"" >&2
