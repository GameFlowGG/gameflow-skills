# Unity SDK

UPM package `gg.gameflow.gameserver` (beta, 0.1.0).
- **Requirements:** Unity 2022.3+, **Api Compatibility Level = .NET Standard 2.1**.
- **Structure:** a pure C# core (`namespace GameFlow`) plus a thin Unity layer (`namespace GameFlow.Unity`).

## Install

Window → Package Manager → **+** → *Add package from git URL*:
```
https://github.com/GameFlowGG/gameflow-gameserver-sdk.git?path=/sdk/unity/Packages/gg.gameflow.gameserver#sdk/unity/v0.1.0
```
Or add it to `Packages/manifest.json`:
```json
"gg.gameflow.gameserver": "https://github.com/GameFlowGG/gameflow-gameserver-sdk.git?path=/sdk/unity/Packages/gg.gameflow.gameserver#sdk/unity/v0.1.0"
```
Some SDK docs show the org as `gameflow-gg`. The canonical repo is `GameFlowGG/gameflow-gameserver-sdk`.

## API (real names)

| Member | Notes |
|---|---|
| `new GameFlowClient(new GameFlowOptions { … })` | Options: `Mode` (`GameFlowMode.Sidecar`/`Local`, null = auto), `ConnectTimeoutMs`, `RequestTimeoutMs`, `HealthIntervalMs`, `Logger`, `Dispatcher`, `OnHealthDegraded` |
| `GameFlowRunner.Create()` → `runner.Dispatcher`, `runner.Bind(gf)` | A MonoBehaviour that delivers callbacks on the main thread and sends a clean shutdown on quit |
| `await gf.Start()` | Connects with retries, or local mode. Call once. |
| `await gf.Ready()` | Health heartbeat starts automatically |
| `await gf.Shutdown()` | Idempotent after a successful `Start()` |
| `await gf.Players.Connect(id)` / `await gf.Players.Disconnect(id)` | `Disconnect` returns `bool` (false = wasn't tracked) |
| `gf.Players.Count` / `List` / `Capacity` / `TrackingEnabled` | Synchronous |
| `await gf.Payload()` | `string`, or `null` when none |
| `gf.OnPayloadChange(Action<string>)` | Returns an `IDisposable` |
| `gf.Watch(Action<ServerInfo>)`, `await gf.Info()` | Server info |
| `GameFlowEnv.DefaultPort`, `Port(name)`, `TlsDefaultPort`, `Region`, `BuildId` | Static; `null` when absent |
| `gf.Mode` | `GameFlowMode` |

Exceptions derive from `GameFlowException` (`.Code`):
- `ServerFullException` (`.Capacity`)
- `PlayerAlreadyConnectedException`
- `PlayerTrackingDisabledException`
- `SidecarUnavailableException`
- `NotConnectedException`
- `RequestFailedException`

**Never** block on the returned `Task` with `.Wait()` or `.Result`; always `await` it.

## Minimal lifecycle (server bootstrap)

```csharp
using System.Linq;
using System.Threading.Tasks;
using GameFlow;
using GameFlow.Unity;
using UnityEngine;

public sealed class GameFlowServer : MonoBehaviour
{
    [System.Serializable] class PayloadPlayer { public string player_id; public int slot_index; }
    [System.Serializable] class PayloadTeam { public int team_index; public PayloadPlayer[] players; }
    [System.Serializable] class MatchPayload { public string match_id; public string game_mode; public PayloadTeam[] teams; }

    GameFlowClient _gf;
    MatchPayload _match;

    async void Start()
    {
#if !UNITY_SERVER
        if (!Application.isBatchMode) return;   // only run in the dedicated server build
#endif
        var runner = GameFlowRunner.Create();
        _gf = new GameFlowClient(new GameFlowOptions { Logger = new UnityDebugLogger(), Dispatcher = runner.Dispatcher });
        runner.Bind(_gf);

        try
        {
            await _gf.Start();

            ApplyPayload(await _gf.Payload());          // may be null on fleet servers
            _gf.OnPayloadChange(ApplyPayload);          // arrives on allocation

            ushort port = (ushort)(GameFlowEnv.DefaultPort ?? 7777);
            StartTransport(port);                       // e.g. set your NGO/Mirror/FishNet transport port, then start the server

            await _gf.Ready();                          // only once the transport is listening
            Debug.Log($"[server] ready on :{port} mode={_gf.Mode}");
        }
        catch (GameFlowException e)
        {
            Debug.LogError($"[gameflow] startup failed: {e.Code} {e.Message}");
            Application.Quit(1);
        }
    }

    void ApplyPayload(string raw)
    {
        _match = string.IsNullOrEmpty(raw) ? null : JsonUtility.FromJson<MatchPayload>(raw);
        if (_match != null) Debug.Log($"[server] match {_match.match_id}");
    }

    bool IsExpected(string playerId) =>
        _match?.teams != null && _match.teams.Any(t => t.players != null && t.players.Any(p => p.player_id == playerId));

    // Call from your netcode after the player has authenticated (verify a backend-issued token).
    public async Task<bool> OnPlayerAuthenticated(string playerId)
    {
        if (!IsExpected(playerId)) return false;               // reject players not in the payload
        try { await _gf.Players.Connect(playerId); }
        catch (PlayerAlreadyConnectedException) { /* reconnect */ }
        catch (ServerFullException) { return false; }
        return true;
    }

    public async Task OnPlayerLeft(string playerId) => await _gf.Players.Disconnect(playerId);

    public async Task EndMatch()
    {
        await _gf.Shutdown();
        Application.Quit(0);
    }

    void StartTransport(ushort port) { /* your netcode: bind 0.0.0.0:port and start listening */ }
}
```

**Notes:**
- **Port:** set your transport's listen port from `GameFlowEnv.DefaultPort`. Examples: Unity Transport's `SetConnectionData("0.0.0.0", port)`, Mirror's `KcpTransport.Port`, FishNet's `Tugboat.SetPort`. The managed template passes no port flag.
- **Shutdown on stop:** the runner sends a clean shutdown when the process quits, including SIGTERM on GameFlow. Still call `EndMatch()` yourself at the end of a match.

## Build

- Target: **Dedicated Server** + **Linux** (x86_64; Mono or IL2CPP).
- Zip the build folder contents (`MyGame.x86_64`, `MyGame_Data/`, `UnityPlayer.so`, …) for the managed Unity template, or add your own Dockerfile (see build-packaging.md).

## Local mode

Run the server build, or Play in the Editor, off GameFlow: the SDK logs local mode, lifecycle calls succeed immediately, and players are tracked in memory.

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"team_index":0,"players":[{"player_id":"alice"}]}]}' \
  ./Build/MyGame.x86_64 -batchmode -nographics -logFile /dev/stdout
```

Force a mode with `GameFlowOptions.Mode = GameFlowMode.Local`, or `GAMEFLOW_SDK_MODE=local`.
