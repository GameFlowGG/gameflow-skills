# Uploading builds and polling them

You upload an archive. GameFlow builds an image from it (using your root `Dockerfile` or the engine template) and records a build with a `buildId`.

Pick one route:

| Route | Use when |
|---|---|
| `gameflow builds create` (CLI) | Local machine or any CI. Handles single and multipart. |
| `GameFlowGG/gameflow-deploy-action@v1` | GitHub Actions |
| REST (below, or `scripts/upload-build.sh`) | No CLI available (e.g. Windows CI without the binary), custom tooling |

## CLI

```bash
curl -fsSL https://install.gameflow.gg | sh
export PATH="$HOME/.gameflow/bin:$PATH"          # the installer only edits rc files
gameflow login --api-key "$GAMEFLOW_API_KEY"
gameflow builds create --game-id "$GAMEFLOW_GAME_ID" --file ./dist/server.zip --version "v1.4.0-$(git rev-parse --short HEAD)"
```

**Notes:**
- `builds create` prints the build id.
- No other subcommands or flags are documented. Run `gameflow --help` rather than guessing.
- Use a unique `--version` per upload, e.g. a tag or commit SHA. A duplicate is not rejected (the build id gets a random prefix), but it makes builds hard to tell apart.

## GitHub Actions

```yaml
name: Deploy server
on:
  push:
    tags: ["v*"]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # … build your Linux server into ./dist/server/ …
      - run: cd dist/server && zip -qr ../server.zip .
      - id: gameflow
        uses: GameFlowGG/gameflow-deploy-action@v1
        with:
          api-key: ${{ secrets.GAMEFLOW_API_KEY }}
          game-id: ${{ vars.GAMEFLOW_GAME_ID }}
          file: ./dist/server.zip
          version: ${{ github.ref_name }}
      - run: echo "build ${{ steps.gameflow.outputs.build-id }}"
```

**Notes:**
- The key is a repository **secret**. The game id can be a plain **variable**.
- Zip the build folder's **contents**, so that the `Dockerfile` or executable sits at the archive root.
- Install-and-login only: `GameFlowGG/gameflow-setup-action@v1` with `api-key`.

## REST

All calls use `x-api-key: $GAMEFLOW_API_KEY`, `Content-Type: application/json` and camelCase bodies.
- **Accepted extensions:** `.zip`, `.tar`, `.tar.gz`, `.gz`, `.pck`. A bare `.gz` is accepted by the upload but cannot be extracted by the builder, so use `.tar.gz`.
- **Presigned URLs** expire after 15 minutes.

### ≤ 100 MB: single PUT, then start the build

1. `POST /v1/images/generate-upload-url` with `{gameId, version, fileSize, fileName}`. It returns `{uploadUrl, s3Path, expiresIn}`.
2. `PUT <uploadUrl>` with the raw bytes. The URL is signed with a content type, so send the matching `Content-Type` header:

   | Extension | `Content-Type` |
   |---|---|
   | `.zip` | `application/zip` |
   | `.tar` | `application/x-tar` |
   | `.tar.gz` | `application/gzip` |
   | `.pck` | `application/octet-stream` |

3. `POST /v1/images/start-build` with `{gameId, s3Path, version}`. It returns `{buildId, s3Path}`. **Required**: an upload alone builds nothing.

**Don't** use `POST /v1/images/confirm-upload`: it only registers the upload.

```bash
API=https://api.gameflow.gg/v1
FILE=dist/server.zip; NAME=$(basename "$FILE"); SIZE=$(wc -c < "$FILE" | tr -d ' '); VER="v$(date +%s)"
UP=$(curl -fsS -X POST "$API/images/generate-upload-url" -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d "$(jq -n --arg g "$GAMEFLOW_GAME_ID" --arg v "$VER" --arg n "$NAME" --argjson s "$SIZE" '{gameId:$g,version:$v,fileName:$n,fileSize:$s}')")
curl -fsS -X PUT "$(echo "$UP" | jq -r .uploadUrl)" -H "Content-Type: application/zip" --upload-file "$FILE"
BUILD_ID=$(curl -fsS -X POST "$API/images/start-build" -H "x-api-key: $GAMEFLOW_API_KEY" -H "Content-Type: application/json" \
  -d "$(jq -n --arg g "$GAMEFLOW_GAME_ID" --arg p "$(echo "$UP" | jq -r .s3Path)" --arg v "$VER" '{gameId:$g,s3Path:$p,version:$v}')" | jq -r .buildId)
```

### > 100 MB: multipart (complete starts the build)

1. `POST /v1/images/multipart/create` with `{gameId, version, fileSize, fileName, contentType}`. It returns `{uploadId, s3Path, partSize, expiresIn}`. Split the file into `partSize`-byte chunks; only the last one may be smaller.
2. For each part `n` (starting at 1):
   - Call `POST /v1/images/multipart/part-url` with `{s3Path, uploadId, partNumber: n}`. It returns `{uploadUrl}`.
   - `PUT` the chunk to that URL.
   - **Save the `ETag` response header exactly as returned, quotes included.** Request each part URL right before uploading, because they expire.
3. `POST /v1/images/multipart/complete` with `{gameId, s3Path, uploadId, version, parts: [{partNumber, etag}]}`. It returns `{s3Path, buildId}`.
   - With `gameId` set, this already started the build. **Don't call start-build again.**

The upload ceiling is 10 GB. A browser `fetch` can't read `ETag` unless the bucket's CORS exposes it; from Node or curl it is always readable.

**TypeScript (Node 18+, `fetch`):**
```ts
import { open, stat } from "node:fs/promises";
import { basename } from "node:path";

const API = "https://api.gameflow.gg/v1";
const KEY = process.env.GAMEFLOW_API_KEY!;
const gameId = process.env.GAMEFLOW_GAME_ID!;

async function api<T>(path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "x-api-key": KEY, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`GameFlow ${res.status} ${path}: ${text}`);
  return (text ? JSON.parse(text) : {}) as T;
}

export async function uploadMultipart(file: string, version: string): Promise<string> {
  const fileSize = (await stat(file)).size;
  const fileName = basename(file);
  const { uploadId, s3Path, partSize } = await api<{ uploadId: string; s3Path: string; partSize: string | number }>(
    "/images/multipart/create",
    { gameId, version, fileSize, fileName, contentType: "application/zip" },
  );
  const size = Number(partSize); // int64 → may arrive as a string
  const fh = await open(file, "r");
  const parts: { partNumber: number; etag: string }[] = [];
  try {
    for (let partNumber = 1, offset = 0; offset < fileSize; partNumber++, offset += size) {
      const length = Math.min(size, fileSize - offset);
      const buf = Buffer.alloc(length);
      await fh.read(buf, 0, length, offset);
      const { uploadUrl } = await api<{ uploadUrl: string }>("/images/multipart/part-url", { s3Path, uploadId, partNumber });
      const put = await fetch(uploadUrl, { method: "PUT", body: buf });
      const etag = put.headers.get("etag");
      if (!put.ok || !etag) throw new Error(`part ${partNumber} failed: HTTP ${put.status}`);
      parts.push({ partNumber, etag });
    }
  } finally {
    await fh.close();
  }
  const { buildId } = await api<{ buildId: string }>("/images/multipart/complete", { gameId, s3Path, uploadId, version, parts });
  return buildId;
}
```

## Poll the build

`GET /v1/images/builds/{buildId}` returns `{status, message, imageUri}`.
- `status` is one of `queued`, `running`, `success` or `failed`.
- Poll every ~10 s. Builds take minutes; stop after ~30 min.
- On `failed`, print `message` and `GET /v1/images/builds/{buildId}/logs`. The logs are `{steps:[{name, completed, error, logs:[…]}]}`, and the step with `error: true` holds the cause.

```ts
export async function waitForBuild(buildId: string): Promise<string> {
  for (let i = 0; i < 180; i++) {
    const b = await api<{ status: string; message: string; imageUri: string }>(`/images/builds/${buildId}`);
    if (b.status === "success") return b.imageUri;
    if (b.status === "failed") {
      const logs = await api<{ steps?: { name: string; error: boolean; logs: string[] }[] }>(`/images/builds/${buildId}/logs`);
      const bad = logs.steps?.find((s) => s.error);
      throw new Error(`build failed: ${b.message}\n${bad ? `${bad.name}:\n${bad.logs.slice(-40).join("\n")}` : ""}`);
    }
    await new Promise((r) => setTimeout(r, 10_000));
  }
  throw new Error("build still not finished after 30 min");
}
```

**Common failures:**
- "executable not found": the archive is missing the engine binary, or it's nested where the template doesn't look. See build-packaging.md.
- "unsupported artifact type": a bare `.gz` or another extension.
- `npm ci` errors: missing `package-lock.json`.
- Docker errors in your own Dockerfile.

## After success: which build runs?

- **New builds are not flagged current automatically.**
  - If the game has **no** current build, servers and fleets use the latest successful build.
  - If a current build exists, the user must **promote** the new one in the dashboard (Game → Builds). Promoting rolls the autoscaled fleet. Promote and rollback are dashboard-only.
- To try a build before promoting it, start a test server with `"buildId": "<id>"` (see servers-api.md).

## Other build endpoints

| Call | Notes |
|---|---|
| `GET /v1/images/builds?gameId=&pageSize=&pageToken=` | `{builds:[{buildId, status, isCurrent, isPrevious, createdAt, tags, originalFileSize, dockerImageSize, …}], nextPageToken, currentBuild}`. Sizes are int64 strings. |
| `POST /v1/images/builds/{buildId}/tags` | Body `{gameId, tags:["stable"]}`. Replaces the build's tags. |
| `DELETE /v1/images/builds/{buildId}?gameId=` | Fails (`FAILED_PRECONDITION`) for the current build. |
