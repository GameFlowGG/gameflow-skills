# Go SDK

Module `github.com/GameFlowGG/gameflow-gameserver-sdk/sdk/go` (beta, Go 1.23+, standard library only).
- Release tags are path-prefixed: `sdk/go/v0.1.0`.
- Import it as `gameflow`.

```bash
go get github.com/GameFlowGG/gameflow-gameserver-sdk/sdk/go@v0.1.0
```

## API (real names)

| Call | Notes |
|---|---|
| `gameflow.Connect(ctx, opts...)` | Retries on GameFlow; local mode off-platform. Options: `WithMode(gameflow.ModeSidecar\|ModeLocal)`, `WithHealthInterval`, `WithConnectTimeout`, `WithRequestTimeout`, `WithLogger`, `WithSlogLogger`, `WithSilent()`, `WithOnHealthDegraded(func())` |
| `gf.Ready(ctx)` | Starts the health heartbeat automatically |
| `gf.Shutdown(ctx)` | Idempotent |
| `gf.Players().Connect(ctx, id) error` | |
| `gf.Players().Disconnect(ctx, id) (bool, error)` | `false` = wasn't tracked |
| `gf.Players().Count()` / `List()` / `Capacity()` / `TrackingEnabled()` | Synchronous |
| `gf.Payload(ctx) (payload string, present bool, err error)` | |
| `gf.OnPayloadChange(func(payload string, present bool)) (*Subscription, error)` | Call `sub.Unsubscribe()` when done |
| `gf.Watch(func(ServerInfo))`, `gf.Info(ctx)` | |
| `gf.Ports().Default() (uint16, bool)`, `gf.Ports().Get(name)`, `gf.Ports().TLS()` | |
| `gf.Region() (string, bool)`, `gf.BuildID() (string, bool)`, `gf.Mode()` | |

**Errors:**
- Branch with `gameflow.CodeOf(err)` (`gameflow.CodeServerFull`, `CodePlayerAlreadyConnected`, `CodePlayerTrackingDisabled`, …).
- Or with `errors.Is(err, gameflow.ErrServerFull)` / `ErrNotConnected` / ….

## Minimal lifecycle (UDP server)

```go
package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"os/signal"
	"strconv"
	"sync"
	"syscall"

	gameflow "github.com/GameFlowGG/gameflow-gameserver-sdk/sdk/go"
)

type matchPayload struct {
	MatchID string `json:"match_id"`
	Teams   []struct {
		TeamIndex int `json:"team_index"`
		Players   []struct {
			PlayerID string `json:"player_id"`
		} `json:"players"`
	} `json:"teams"`
}

var (
	mu       sync.RWMutex
	expected = map[string]bool{}
)

func applyPayload(raw string, present bool) {
	next := map[string]bool{}
	if present {
		var m matchPayload
		if err := json.Unmarshal([]byte(raw), &m); err != nil {
			log.Printf("bad payload: %v", err)
		}
		for _, t := range m.Teams {
			for _, p := range t.Players {
				next[p.PlayerID] = true
			}
		}
		log.Printf("assigned match %s", m.MatchID)
	}
	mu.Lock()
	expected = next
	mu.Unlock()
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	gf, err := gameflow.Connect(ctx)
	if err != nil {
		log.Fatalf("gameflow connect: %v", err)
	}

	// Payload: read once, then follow changes (fleet servers receive it on allocation).
	if p, ok, err := gf.Payload(ctx); err == nil {
		applyPayload(p, ok)
	}
	sub, err := gf.OnPayloadChange(applyPayload)
	if err == nil {
		defer sub.Unsubscribe()
	}

	port := uint16(7777)
	if p, ok := gf.Ports().Default(); ok {
		port = p
	}
	conn, err := net.ListenPacket("udp", "0.0.0.0:"+strconv.Itoa(int(port)))
	if err != nil {
		log.Fatalf("listen :%d: %v", port, err)
	}
	if err := gf.Ready(ctx); err != nil { // only once listening
		log.Fatalf("gameflow ready: %v", err)
	}
	log.Printf("listening on :%d (mode=%s)", port, gf.Mode())

	go serve(ctx, conn, gf)
	<-ctx.Done() // SIGTERM from the platform (or call stop() when the match ends)

	conn.Close()
	if err := gf.Shutdown(context.Background()); err != nil { // well within the ~45 s budget
		log.Printf("gameflow shutdown: %v", err)
	}
}

// onPlayerJoin is called by your protocol after the player authenticated (verify a backend token).
func onPlayerJoin(ctx context.Context, gf *gameflow.GameFlow, playerID string) bool {
	mu.RLock()
	ok := expected[playerID]
	mu.RUnlock()
	if !ok {
		return false // not in this match's payload
	}
	if err := gf.Players().Connect(ctx, playerID); err != nil {
		switch gameflow.CodeOf(err) {
		case gameflow.CodePlayerAlreadyConnected:
			return true // reconnect
		default: // CodeServerFull etc.
			log.Printf("reject %s: %v", playerID, err)
			return false
		}
	}
	return true
}

func onPlayerLeave(gf *gameflow.GameFlow, playerID string) {
	if _, err := gf.Players().Disconnect(context.Background(), playerID); err != nil {
		log.Printf("disconnect %s: %v", playerID, err)
	}
}

func serve(ctx context.Context, conn net.PacketConn, gf *gameflow.GameFlow) {
	// your game protocol: call onPlayerJoin / onPlayerLeave as sessions start and end
	_ = ctx
	_ = conn
	_ = gf
}
```

**Notes:**
- When the match ends, call `stop()` (or cancel the context) so the same shutdown path runs.
- A Go server needs its own Dockerfile at the archive root (see build-packaging.md).

## Local mode

```bash
GAMEFLOW_DEFAULT_PORT=7777 GAMEFLOW_MAX_PLAYERS=4 GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"team_index":0,"players":[{"player_id":"alice"}]}]}' \
  go run ./cmd/server
```

- Off GameFlow the SDK logs local mode, lifecycle calls are no-ops, and players are tracked in memory.
- Force a mode with `gameflow.WithMode(gameflow.ModeLocal)` or `GAMEFLOW_SDK_MODE=local`.
