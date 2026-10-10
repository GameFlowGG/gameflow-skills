#!/usr/bin/env sh
# Upload a server build archive to GameFlow over REST and wait for the image build.
# Prefer the CLI (`gameflow builds create`) when available; this is the no-CLI path.
#
# Usage: GAMEFLOW_API_KEY=gf_... sh upload-build.sh <gameId> <archive> [version]
#   archive: .zip, .tar, .tar.gz or .pck   (a bare .gz uploads but fails to build)
#   version: defaults to a timestamp; use a tag or commit SHA in CI
# Requires: curl, jq, dd, wc.  Prints the build id on stdout when the build succeeds.
set -eu

API="${GAMEFLOW_API_URL:-https://api.gameflow.gg/v1}"
SINGLE_MAX=$((100 * 1024 * 1024))   # above 100 MB, use multipart
POLL_SECONDS=10
POLL_MAX=180                         # 30 minutes

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$*" >&2; }

[ -n "${GAMEFLOW_API_KEY:-}" ] || die "GAMEFLOW_API_KEY is not set (create a key at https://app.gameflow.gg/settings#api)"
[ $# -ge 2 ] || die "usage: $0 <gameId> <archive> [version]"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

GAME_ID=$1
FILE=$2
VERSION=${3:-"v$(date +%Y%m%d%H%M%S)"}
[ -f "$FILE" ] || die "archive not found: $FILE"

NAME=$(basename "$FILE")
SIZE=$(wc -c < "$FILE" | tr -d ' ')
case "$NAME" in
  *.tar.gz|*.TAR.GZ) CTYPE="application/gzip" ;;
  *.zip|*.ZIP)       CTYPE="application/zip" ;;
  *.tar|*.TAR)       CTYPE="application/x-tar" ;;
  *.pck|*.PCK)       CTYPE="application/octet-stream" ;;
  *.gz|*.GZ)         die "bare .gz archives are accepted by the upload but cannot be built; repack as .tar.gz" ;;
  *)                 die "unsupported archive type: $NAME (use .zip, .tar, .tar.gz or .pck)" ;;
esac

# api METHOD PATH [JSON] -> prints body; exits with the API error on non-2xx.
api() {
  if [ $# -ge 3 ]; then
    out=$(curl -sS -w '\n%{http_code}' -X "$1" "$API$2" -H "x-api-key: $GAMEFLOW_API_KEY" \
      -H "Content-Type: application/json" -d "$3") || die "network error calling $1 $2"
  else
    out=$(curl -sS -w '\n%{http_code}' -X "$1" "$API$2" -H "x-api-key: $GAMEFLOW_API_KEY") \
      || die "network error calling $1 $2"
  fi
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  case "$code" in
    2*) printf '%s' "$body" ;;
    401) die "$1 $2 -> 401: key missing, mistyped, expired or revoked" ;;
    404) die "$1 $2 -> 404: $body (wrong gameId, or base URL missing /v1: $API)" ;;
    *)   die "$1 $2 -> HTTP $code: $body" ;;
  esac
}

log "Uploading $NAME ($SIZE bytes) to game $GAME_ID as version $VERSION"

if [ "$SIZE" -le "$SINGLE_MAX" ]; then
  # Single presigned PUT, then start-build (the upload alone does not build).
  req=$(jq -n --arg g "$GAME_ID" --arg v "$VERSION" --arg n "$NAME" --argjson s "$SIZE" \
    '{gameId:$g, version:$v, fileName:$n, fileSize:$s}')
  up=$(api POST /images/generate-upload-url "$req")
  url=$(printf '%s' "$up" | jq -r '.uploadUrl // empty')
  s3=$(printf '%s' "$up" | jq -r '.s3Path // empty')
  [ -n "$url" ] && [ -n "$s3" ] || die "unexpected generate-upload-url response: $up"
  pcode=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$url" -H "Content-Type: $CTYPE" --upload-file "$FILE") \
    || die "upload PUT failed (network)"
  [ "$pcode" = "200" ] || die "upload PUT returned HTTP $pcode (expired URL or Content-Type mismatch)"
  req=$(jq -n --arg g "$GAME_ID" --arg p "$s3" --arg v "$VERSION" '{gameId:$g, s3Path:$p, version:$v}')
  BUILD_ID=$(api POST /images/start-build "$req" | jq -r '.buildId // empty')
else
  # Multipart: create -> part-url + PUT per part (keep ETags) -> complete (starts the build).
  req=$(jq -n --arg g "$GAME_ID" --arg v "$VERSION" --arg n "$NAME" --argjson s "$SIZE" --arg c "$CTYPE" \
    '{gameId:$g, version:$v, fileName:$n, fileSize:$s, contentType:$c}')
  mp=$(api POST /images/multipart/create "$req")
  upload_id=$(printf '%s' "$mp" | jq -r '.uploadId // empty')
  s3=$(printf '%s' "$mp" | jq -r '.s3Path // empty')
  part_size=$(printf '%s' "$mp" | jq -r '.partSize // empty')   # int64: may be a JSON string
  [ -n "$upload_id" ] && [ -n "$s3" ] && [ -n "$part_size" ] || die "unexpected multipart/create response: $mp"
  parts_total=$(( (SIZE + part_size - 1) / part_size ))
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  parts_json="[]"
  n=1
  while [ "$n" -le "$parts_total" ]; do
    dd if="$FILE" of="$tmp/part" bs="$part_size" skip=$((n - 1)) count=1 2>/dev/null || die "could not read part $n"
    req=$(jq -n --arg p "$s3" --arg u "$upload_id" --argjson n "$n" '{s3Path:$p, uploadId:$u, partNumber:$n}')
    purl=$(api POST /images/multipart/part-url "$req" | jq -r '.uploadUrl // empty')
    [ -n "$purl" ] || die "no uploadUrl for part $n"
    etag=$(curl -sS -D - -o /dev/null -X PUT "$purl" --upload-file "$tmp/part" \
      | tr -d '\r' | awk 'tolower($1)=="etag:" {print $2}')
    [ -n "$etag" ] || die "part $n upload returned no ETag"
    parts_json=$(printf '%s' "$parts_json" | jq --argjson n "$n" --arg e "$etag" '. + [{partNumber:$n, etag:$e}]')
    log "  part $n/$parts_total uploaded"
    n=$((n + 1))
  done
  req=$(jq -n --arg g "$GAME_ID" --arg p "$s3" --arg u "$upload_id" --arg v "$VERSION" --argjson parts "$parts_json" \
    '{gameId:$g, s3Path:$p, uploadId:$u, version:$v, parts:$parts}')
  BUILD_ID=$(api POST /images/multipart/complete "$req" | jq -r '.buildId // empty')
fi

[ -n "$BUILD_ID" ] || die "no buildId returned; the build was not started"
log "Build $BUILD_ID started; polling every ${POLL_SECONDS}s"

i=0
while [ "$i" -lt "$POLL_MAX" ]; do
  st=$(api GET "/images/builds/$BUILD_ID")
  status=$(printf '%s' "$st" | jq -r '.status // empty')
  case "$status" in
    success)
      log "Build succeeded: $(printf '%s' "$st" | jq -r '.imageUri // empty')"
      log "If the game already has a current build, promote this one in the dashboard (Game -> Builds),"
      log "or test it first: POST /v1/games/$GAME_ID/servers {\"region\":\"...\",\"buildId\":\"$BUILD_ID\"}"
      printf '%s\n' "$BUILD_ID"
      exit 0 ;;
    failed)
      log "Build failed: $(printf '%s' "$st" | jq -r '.message // empty')"
      api GET "/images/builds/$BUILD_ID/logs" \
        | jq -r '.steps[]? | select(.error) | "--- \(.name)", (.logs[-40:][]?)' >&2 || true
      exit 1 ;;
    *) log "  status: ${status:-unknown}" ;;
  esac
  i=$((i + 1))
  sleep "$POLL_SECONDS"
done
die "build $BUILD_ID did not finish within $((POLL_SECONDS * POLL_MAX / 60)) minutes"
