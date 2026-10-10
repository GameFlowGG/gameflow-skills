# Godot SDK (GDScript addon)

Godot 4.4+, pure GDScript, beta. Source: `GameFlowGG/gameflow-gameserver-sdk`, folder `sdk/godot/addons/gameflow/`, release tag `godot-v0.1.2`. The GitHub release attaches `gameflow-godot-sdk-<version>.zip`.

## Install

1. Copy `addons/gameflow/` into your project's `addons/` folder, either from the release zip or from the tag:
   ```bash
   git clone --depth 1 --branch godot-v0.1.2 https://github.com/GameFlowGG/gameflow-gameserver-sdk.git /tmp/gf-sdk
   cp -r /tmp/gf-sdk/sdk/godot/addons/gameflow ./addons/
   ```
2. Enabling the plugin is optional: the classes are global `class_name` scripts (`GameFlow`, `GameFlowResult`, `GameFlowPlayers`, `GameFlowPorts`, `GameFlowServerInfo`, `GameFlowLogger`).

## API (real names)

GDScript has no exceptions, so every fallible call returns a `GameFlowResult`:
- `ok`, `code`, `message`, and `value`.
- `capacity`, set on `SERVER_FULL`.

| Member | Notes |
|---|---|
| `var gf := GameFlow.new()` | `RefCounted`; create **one** per process (an autoload is the natural home) |
| `await gf.start(options := {})` | Connects with retries, or falls back to local mode. Call once. Options: `mode`, `health_interval_ms`, `connect_timeout_ms`, `request_timeout_ms`, `logger` |
| `await gf.ready()` | Health heartbeat starts automatically |
| `await gf.shutdown()` | Idempotent |
| `await gf.players.track(id)` / `await gf.players.untrack(id)` | Named track/untrack because `connect` collides with Godot signals |
| `gf.players.count()` / `list()` / `capacity()` / `tracking_enabled()` | Synchronous; `capacity()` is `-1` when unlimited (local) |
| `await gf.payload()` | `res.value` is a `String` or `null` |
| `gf.on_payload_change(callable)` | The callable gets `String` or `null`; returns an unsubscribe `Callable` |
| `gf.watch(callable)` / `await gf.info()` | `GameFlowServerInfo` |
| `gf.ports.default`, `gf.ports.by_name(n)`, `gf.ports.tls` | `int` or `null` |
| `gf.mode`, `gf.region`, `gf.build_id` | Strings (`""` when absent) |
| `signal health_degraded` | Fired once on sustained heartbeat failure |

Codes: `GameFlowResult.SIDECAR_UNAVAILABLE`, `PLAYER_ALREADY_CONNECTED`, `SERVER_FULL`, `PLAYER_TRACKING_DISABLED`, `NOT_CONNECTED`, `REQUEST_FAILED`.

## Minimal lifecycle (ENet server autoload)

```gdscript
# res://server/game_server.gd — add as an autoload, run only in the server build.
extends Node

var gf := GameFlow.new()
var match_data = null          # parsed payload (Dictionary) or null
var peer_to_player := {}       # peer id -> player id

func _ready() -> void:
	if not ("--server" in OS.get_cmdline_args() or DisplayServer.get_name() == "headless"):
		return  # client build: do nothing
	var res: GameFlowResult = await gf.start()
	if not res.ok:
		push_error("gameflow start failed: %s (%s)" % [res.message, res.code])
		get_tree().quit(1)
		return

	# Payload: read once, then follow changes (fleet servers get it on allocation).
	var p: GameFlowResult = await gf.payload()
	_apply_payload(p.value if p.ok else null)
	gf.on_payload_change(_apply_payload)

	var port: int = gf.ports.default if gf.ports.default != null else 7777
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, 16)
	if err != OK:
		push_error("listen failed on %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = enet
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	await gf.ready()  # only after the server accepts connections
	print("listening on :%d (mode=%s)" % [port, gf.mode])

func _apply_payload(raw: Variant) -> void:
	match_data = JSON.parse_string(raw) if raw != null else null

func _is_expected(player_id: String) -> bool:
	if match_data == null:
		return false
	for team in match_data.get("teams", []):
		for p in team.get("players", []):
			if p.get("player_id") == player_id:
				return true
	return false

# Clients call this right after connecting. Verify a token from your backend here.
@rpc("any_peer", "reliable")
func authenticate(player_id: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not _is_expected(player_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return
	var res: GameFlowResult = await gf.players.track(player_id)
	if not res.ok and res.code != GameFlowResult.PLAYER_ALREADY_CONNECTED:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)  # SERVER_FULL etc.
		return
	peer_to_player[peer_id] = player_id

func _on_peer_disconnected(peer_id: int) -> void:
	if peer_to_player.has(peer_id):
		gf.players.untrack(peer_to_player[peer_id])
		peer_to_player.erase(peer_id)

func end_match() -> void:
	await gf.shutdown()
	get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		end_match()
```

**Notes:**
- **Port:** the managed Godot template runs `godot --headless --main-pack <pck> --server`. Your code must pick the port from `gf.ports.default`; there is no port flag.
- **Launch args:** extra launch options arrive after `--`, in `OS.get_cmdline_user_args()`.
- **SIGTERM:** Godot does not surface SIGTERM to scripts on every platform. Always call `end_match()` yourself when the match ends; don't rely on the stop signal alone.
- **Engine version:** set the game's engine version to the exact Godot version you export with.

## Local mode

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"team_index":0,"players":[{"player_id":"alice"}]}]}' \
  godot --headless --path . --server
```

- This mirrors the template's flags. Off GameFlow the SDK enters local mode by itself.
- Force local mode with `gf.start({"mode": "local"})` or `GAMEFLOW_SDK_MODE=local`.
