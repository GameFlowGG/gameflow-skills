# Rust SDK

Crate `gameflow-gameserver-sdk` (beta, 0.1.x):
- The library is imported as **`gameflow`**.
- Async, built on tokio + reqwest. MSRV 1.82.
- Release tags are named `rust-v<version>`.

```toml
[dependencies]
gameflow-gameserver-sdk = "0.1"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "net", "signal"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

## API (real names)

| Item | Notes |
|---|---|
| `GameFlow::connect().await?` / `GameFlow::connect_with(ConnectOptions::new().mode(ModeOption::Local)).await?` | `ConnectOptions`: `.mode()`, `.health_interval()`, `.connect_timeout()`, `.request_timeout()`, `.logger()`, `.silent()`, `.on_health_degraded()` |
| `gf.ready().await?` | Starts the health heartbeat automatically |
| `gf.shutdown().await?` | Idempotent |
| `gf.players().connect(id).await?` / `gf.players().disconnect(id).await? -> bool` | |
| `gf.players().count()` / `list()` / `capacity() -> i64` / `tracking_enabled()` | Synchronous; capacity `-1` = unlimited (local) |
| `gf.payload().await? -> Option<String>` | |
| `gf.on_payload_change(\|p: Option<String>\| …)? -> Subscription` | **Dropping the `Subscription` unsubscribes.** Keep it alive or call `.detach()`. |
| `gf.watch(…)?`, `gf.info().await?` | `ServerInfo` |
| `gf.ports().default() -> Option<u16>`, `gf.ports().get(name)`, `gf.ports().tls()` | |
| `gf.region()`, `gf.build_id()` → `Option<String>`, `gf.mode()` | |

`GameFlow` is `Clone`, so share it across tasks. Errors are `GameFlowError`; match on `err.code()`:
- `ErrorCode::ServerFull`
- `ErrorCode::PlayerAlreadyConnected`
- `ErrorCode::PlayerTrackingDisabled`
- `ErrorCode::NotConnected`
- …

The SDK logs through `tracing` (target `gameflow`).

## Minimal lifecycle (tokio TCP)

```rust
use std::collections::HashSet;
use std::sync::{Arc, RwLock};

use gameflow::{ErrorCode, GameFlow};
use serde::Deserialize;
use tokio::net::TcpListener;

#[derive(Deserialize)]
struct Player { player_id: String }
#[derive(Deserialize)]
struct Team { players: Vec<Player> }
#[derive(Deserialize)]
struct MatchPayload { match_id: String, teams: Vec<Team> }

type Expected = Arc<RwLock<HashSet<String>>>;

fn apply_payload(expected: &Expected, raw: Option<String>) {
    let mut set = HashSet::new();
    if let Some(m) = raw.as_deref().and_then(|s| serde_json::from_str::<MatchPayload>(s).ok()) {
        println!("[server] assigned match {}", m.match_id);
        set.extend(m.teams.into_iter().flat_map(|t| t.players).map(|p| p.player_id));
    }
    *expected.write().unwrap() = set;
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let gf = GameFlow::connect().await?;

    // Payload: read once, then follow changes (fleet servers receive it on allocation).
    let expected: Expected = Arc::new(RwLock::new(HashSet::new()));
    apply_payload(&expected, gf.payload().await?);
    let exp = expected.clone();
    let _payload_sub = gf.on_payload_change(move |p| apply_payload(&exp, p))?; // keep alive

    let port = gf.ports().default().unwrap_or(7777);
    let listener = TcpListener::bind(("0.0.0.0", port)).await?; // all interfaces, not 127.0.0.1
    gf.ready().await?; // only once listening
    println!("[server] listening on :{port} (mode={})", gf.mode());

    tokio::select! {
        _ = accept_loop(listener, gf.clone(), expected.clone()) => {}
        _ = shutdown_signal() => println!("[server] stop signal"),
    }
    gf.shutdown().await?; // also call this when the match ends; force-kill ~45 s after SIGTERM
    Ok(())
}

async fn accept_loop(listener: TcpListener, gf: GameFlow, expected: Expected) {
    while let Ok((socket, _)) = listener.accept().await {
        let (gf, expected) = (gf.clone(), expected.clone());
        tokio::spawn(async move {
            // Read the player's id/token from `socket` with your protocol and verify the token.
            let player_id = String::from("alice");
            if !expected.read().unwrap().contains(&player_id) {
                return; // not in this match: drop the connection
            }
            match gf.players().connect(&player_id).await {
                Ok(()) => {}
                Err(e) if e.code() == ErrorCode::PlayerAlreadyConnected => {}
                Err(e) => { eprintln!("reject {player_id}: {e}"); return; }
            }
            // … run the session on `socket` …
            drop(socket);
            let _ = gf.players().disconnect(&player_id).await;
        });
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut term = signal(SignalKind::terminate()).expect("SIGTERM handler");
        tokio::select! { _ = term.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
    }
    #[cfg(not(unix))]
    { let _ = tokio::signal::ctrl_c().await; }
}
```

The SDK's own `tokio-tcp` example binds `127.0.0.1`, which is unreachable inside a container. Bind `0.0.0.0` as above.

## Bevy

- There is no published Bevy crate. Copy `sdk/rust/examples/bevy-server/src/gameflow_plugin.rs` from the SDK repo into your project; it compiles against your Bevy version.
- Its extra dependencies are `bevy`, `tokio` (rt, rt-multi-thread) and `crossbeam-channel`.
- **What it gives you:**
  - `GameFlowPlugin`, which runs its own tokio runtime.
  - A `GameFlowClient` resource with `ready()`, `connect_player(id)`, `disconnect_player(id)`, `shutdown()`, `player_count()`, `default_port()`, `handle()`.
  - Messages such as `PlayerConnected`, `PlayerConnectFailed` and `PayloadChanged`.
  - Observable events such as `GameFlowConnected`, `GameFlowReady` and `GameFlowShutdown`.
- **Readiness:** the default config auto-calls `ready()` on connect. Use `GameFlowPlugin::default().manual_ready()` and call `client.ready()` once your network socket is bound.
- **Shutdown:** exit the app on `GameFlowShutdown`, as the example does.

## Local mode

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"players":[{"player_id":"alice"}]}]}' \
  cargo run --bin server
```

- Off GameFlow the SDK logs local mode, lifecycle calls are simulated, and players are tracked in memory.
- `GAMEFLOW_SDK_MODE=local|sidecar` forces a mode.
- A Rust server needs its own Dockerfile (see build-packaging.md).
