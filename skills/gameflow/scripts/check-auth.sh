#!/usr/bin/env sh
# Verify GAMEFLOW_API_KEY works and list the organization's games.
# Usage: GAMEFLOW_API_KEY=gf_... sh check-auth.sh
# Requires: curl. Uses jq for pretty output when available.
set -eu

API="${GAMEFLOW_API_URL:-https://api.gameflow.gg/v1}"

if [ -z "${GAMEFLOW_API_KEY:-}" ]; then
  echo "GAMEFLOW_API_KEY is not set. Create a key at https://app.gameflow.gg/settings#api" >&2
  exit 1
fi

call() {
  # Prints body; exits non-zero with the API error on failure.
  out=$(curl -sS -w '\n%{http_code}' -H "x-api-key: $GAMEFLOW_API_KEY" "$API$1")
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "GET $1 -> HTTP $code: $body" >&2
    [ "$code" = "401" ] && echo "Key missing, mistyped, expired or revoked." >&2
    [ "$code" = "404" ] && echo "Check the base URL includes /v1 (current: $API)." >&2
    exit 1
  fi
  printf '%s' "$body"
}

pretty() { if command -v jq >/dev/null 2>&1; then jq "$@"; else cat; fi; }

echo "== Identity"
call /identity/me | pretty '{user: .user.email, organization: .organization.name, organizationId: .organization.id, isOwner}'

echo "== Games"
call "/games?pageSize=50" | pretty '[.games[]? | {id: .game.id, title: .game.title, engine: .game.engine, live, serversCount}]'
