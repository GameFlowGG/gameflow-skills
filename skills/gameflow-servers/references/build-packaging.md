# Packaging a server build

## How GameFlow turns an archive into an image

1. **Extract.** `.zip`, `.tar` and `.tar.gz` are extracted. A `.pck` is used as is, and the engine is forced to Godot. A bare `.gz` (not `.tar.gz`) fails with "unsupported artifact type".
2. **Your Dockerfile, if present.** A file named `Dockerfile` (any case) **at the archive root** is used verbatim, and the extracted archive is the Docker build context.
3. **Otherwise, the managed template** for the game's engine is rendered with the detected executable. `__MACOSX/` and dot-directories are skipped during detection.

**Platform facts that apply to every image:**
- **Ports:** the container must listen on `GAMEFLOW_DEFAULT_PORT`, the port configured in the game. `EXPOSE` is documentation only; the game config decides.
- **Args:** the platform passes the game's launch options plus per-launch `launchArgs` as container **args**, prefixed with `--`. With `ENTRYPOINT` they are appended; with only `CMD` they **replace** the command.
- **Stopping:** SIGTERM, then a force kill about 45 s later. Use exec-form `ENTRYPOINT`, or `exec` in wrapper scripts, so your process is PID 1 and receives the signal.
- **Logs:** write to stdout/stderr; that's what the logs API shows.
- **User:** the managed templates run as non-root **UID 1000**. Do the same in your own Dockerfile.
- **Architecture:** x86_64 Linux. Build Linux binaries and pin `--platform=linux/amd64` if you build locally on ARM.

## Managed templates: what the archive must contain

| Engine | Detection (first match, walking the tree) | Image and command |
|---|---|---|
| **Unity** | first file ending `.x86_64` or `.x86` | Ubuntu, files in `/opt/game`, UID 1000. Runs `/opt/game/<exe> -batchmode -nographics -logFile /dev/stdout [-- args]` |
| **Godot** | first `*.pck`, else first `*.x86_64`/`*.x86` | Ubuntu plus the official Godot `<engine version>-stable` Linux binary (the game's engine version; default `4.6`). Runs `godot --headless --main-pack /opt/game/<pck> --server [-- args]` |
| **Unreal** | first file under a path containing `Binaries/Linux` whose name contains `server` or ends with `-linux-shipping` (case-insensitive) | Ubuntu, files in the user's home dir. `chmod +x`, then `CMD ["<exe>"]`, with no args and no `ENTRYPOINT` |
| **Colyseus (Node)** | a `package.json` | `node:22` or `node:24`. Runs `npm ci` from `package*.json`, `COPY . .`, then `npx tsx src/index.ts`. Sets `PORT=2567` and `NODE_ENV=production`. |
| **Custom** | — | Needs your own Dockerfile |

### Unity
- Build target: **Dedicated Server**, platform **Linux** (x86_64). Zip the **contents** of the build folder:
  `MyGame.x86_64`, `MyGame_Data/`, `UnityPlayer.so`, plus `GameAssembly.so` for IL2CPP.
- Keep exactly one `.x86_64` in the archive. Detection takes the first match.
- Your server code must read `GAMEFLOW_DEFAULT_PORT` (the template passes no port flag).

### Godot
- Export a `.pck` (Export PCK/ZIP… → `.pck`) with the **same Godot version** as the game's engine version setting. A mismatch fails at load.
- Upload the `.pck` alone, or a zip containing one.
- The template passes `--server` and runs `--headless`. Detect server mode with `"--server" in OS.get_cmdline_args()` or `DisplayServer.get_name() == "headless"`.
- Read the port through the SDK (`gf.ports.default`).
- Requires the `addons/gameflow/` scripts in the export.

### Unreal: prefer your own Dockerfile
The managed template runs the binary with **no arguments**, so:
- Unreal listens on its default port 7777. The game's port must then be 7777.
- Setting launch options or `launchArgs` replaces the `CMD` and breaks startup.

**Archive:** the packaged `LinuxServer/` folder contents (`MyGameServer.sh`, `MyGame/Binaries/Linux/MyGameServer`, `MyGame/Content/Paks/…`, `Engine/…`). Strip `*.debug` / `*.sym` files so detection can't pick them.

## Writing your own Dockerfile (root of the archive)

```dockerfile
# Unreal (LinuxServer output next to this Dockerfile, plus entrypoint.sh)
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /home/ubuntu/server
COPY --chown=ubuntu:ubuntu . .
RUN chmod +x entrypoint.sh MyGame/Binaries/Linux/MyGameServer
USER ubuntu
EXPOSE 7777/udp
ENTRYPOINT ["./entrypoint.sh"]
```
```sh
#!/bin/sh
# entrypoint.sh: pass the platform port to Unreal; drop the leading "--" the platform adds before launch args.
set -eu
[ "${1:-}" = "--" ] && shift
exec ./MyGame/Binaries/Linux/MyGameServer MyGame -log -port="${GAMEFLOW_DEFAULT_PORT:-7777}" "$@"
```

```dockerfile
# Unity (Linux Dedicated Server build folder contents next to this Dockerfile)
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libglib2.0-0t64 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/game
COPY --chown=ubuntu:ubuntu . .
RUN chmod +x ./MyGame.x86_64
USER ubuntu
EXPOSE 7777/udp
ENTRYPOINT ["./MyGame.x86_64", "-batchmode", "-nographics", "-logFile", "/dev/stdout"]
```

```dockerfile
# Node / TypeScript (compiled to dist/; archive = project without node_modules)
FROM node:24-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY dist ./dist
USER node
EXPOSE 7777
ENTRYPOINT ["node", "dist/server.js"]
```

```dockerfile
# Go (static binary built in the image)
FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/server ./cmd/server
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
USER 65532
EXPOSE 7777/udp
ENTRYPOINT ["/server"]
```
The Go example uses distroless's built-in non-root user (65532). Any non-root UID works for custom images. Use UID 1000 to match the managed templates if you're unsure.

```dockerfile
# Rust (tokio or headless Bevy)
FROM rust:1.82 AS build
WORKDIR /src
COPY . .
RUN cargo build --release --bin server
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd -u 1000 -m game
COPY --from=build /src/target/release/server /usr/local/bin/server
USER 1000
EXPOSE 7777/udp
ENTRYPOINT ["/usr/local/bin/server"]
```

## Archive hygiene

- Put the `Dockerfile` or executable at the **root**: zip the folder's contents, not the folder.
  `cd build && zip -qr ../server.zip .` or `tar -czf ../server.tar.gz -C build .`
- Never include `node_modules/`, `.git/`, `Library/`, `Intermediate/`, `Saved/`, `.env` or secrets. Template `COPY . .` would bake them into the image, and a host `node_modules/` would overwrite the Linux one from `npm ci`.
- Keep Node archives' `package-lock.json`: the template runs `npm ci`, which fails without it.
- Test the image locally first:
  `docker build --platform linux/amd64 -t mygame-server . && docker run --rm -e GAMEFLOW_DEFAULT_PORT=7777 -p 7777:7777/udp mygame-server`.
  The SDK logs local mode, and the server must stay up and listen.
