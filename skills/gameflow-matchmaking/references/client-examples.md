# Client examples

Game clients **never** hold a GameFlow API key. They:
1. measure ping to the GameFlow regions,
2. call **your backend** (`/matchmaking/join`, `/status/:id`, `DELETE /:id`) with the player's own session token,
3. connect to `host:port`.

The backend contract matches [backend-examples.md](backend-examples.md):

| Call | Response |
|---|---|
| `POST {BACKEND}/matchmaking/join` `{"region":"us-east"}` | `200 {"ticketId","status":"searching"}` |
| `GET {BACKEND}/matchmaking/status/{ticketId}` (≤ ~35 s) | `200 {"status":"searching"}`, or `200 {"status":"assigned","host","port","joinToken"?}` |
| `DELETE {BACKEND}/matchmaking/{ticketId}` | `204` |
| Errors | `401` re-login · `410` ticket gone, offer "search again" · `409`/`429`/`5xx`/network: retry with backoff |

## Region selection (all engines)

- `GET https://api.gameflow.gg/v1/ping/regions` needs **no auth**. It returns `{"regions":[{"name":"us-east","endpoint":"https://…"}]}`.
- Send 4 HTTP GETs to each `endpoint`, **discard the first** (TLS/DNS warm-up), take the median of the rest, and pick the lowest. Treat errors and timeouts (~2 s) as unreachable.
- Cache the choice for the session and let players override it. Re-measure on launch, not mid-match.
- **Browsers:** the API host's CORS policy may block reading the region list from your game's origin. Serve the same JSON from your backend. Time the ping endpoints with `mode: "no-cors"`, which still measures the round trip.
- Only offer regions your backend allows (the game's deployed regions). Never hard-code `eu-west` or other guessed regions.

## Unity (C#)

```csharp
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using UnityEngine;
using UnityEngine.Networking;

public class Matchmaker : MonoBehaviour
{
    public string backendUrl = "https://api.mygame.com";   // YOUR backend, not api.gameflow.gg
    public Func<string> getSessionToken;                    // your auth, e.g. () => Auth.AccessToken
    public event Action<string, int, string> OnMatchFound;  // host, port, joinToken
    public event Action<string> OnStatus;

    [Serializable] class PingRegion { public string name; public string endpoint; }
    [Serializable] class PingRegions { public PingRegion[] regions; }
    [Serializable] class JoinBody { public string region; }
    [Serializable] class JoinResp { public string ticketId; public string status; }
    [Serializable] class StatusResp { public string status; public string host; public int port; public string joinToken; }

    string ticketId;
    bool searching;

    public IEnumerator PickRegion(Action<string> done)
    {
        using var req = UnityWebRequest.Get("https://api.gameflow.gg/v1/ping/regions");
        yield return req.SendWebRequest();
        if (req.result != UnityWebRequest.Result.Success) { done(null); yield break; }
        var list = JsonUtility.FromJson<PingRegions>(req.downloadHandler.text).regions;
        string best = null; long bestMs = long.MaxValue;
        foreach (var r in list)
        {
            var url = r.endpoint.StartsWith("http") ? r.endpoint : "https://" + r.endpoint;
            var samples = new List<long>();
            for (int i = 0; i < 4; i++)
            {
                using var p = UnityWebRequest.Get(url);
                p.timeout = 2;
                var sw = Stopwatch.StartNew();
                yield return p.SendWebRequest();
                if (p.result == UnityWebRequest.Result.Success && i > 0) samples.Add(sw.ElapsedMilliseconds);
            }
            if (samples.Count == 0) continue;
            var median = samples.OrderBy(x => x).ElementAt(samples.Count / 2);
            if (median < bestMs) { bestMs = median; best = r.name; }
        }
        done(best);
    }

    public IEnumerator FindMatch(string region)
    {
        searching = true;
        OnStatus?.Invoke("Searching…");
        using (var join = Send("POST", "/matchmaking/join", JsonUtility.ToJson(new JoinBody { region = region })))
        {
            yield return join.SendWebRequest();
            if (join.responseCode != 200) { OnStatus?.Invoke($"Could not join ({join.responseCode})"); searching = false; yield break; }
            ticketId = JsonUtility.FromJson<JoinResp>(join.downloadHandler.text).ticketId;
        }

        int failures = 0;
        while (searching)
        {
            using var poll = Send("GET", $"/matchmaking/status/{UnityWebRequest.EscapeURL(ticketId)}", null);
            poll.timeout = 45; // longer than the backend's long-poll
            yield return poll.SendWebRequest();
            if (!searching) yield break;                       // cancelled while waiting
            if (poll.responseCode == 200)
            {
                failures = 0;
                var s = JsonUtility.FromJson<StatusResp>(poll.downloadHandler.text);
                if (s.status == "assigned") { searching = false; OnMatchFound?.Invoke(s.host, s.port, s.joinToken); yield break; }
                continue;                                      // "searching": poll again right away
            }
            if (poll.responseCode == 410 || poll.responseCode == 401 || ++failures >= 5)
            {
                searching = false; OnStatus?.Invoke("Search failed. Try again."); yield break;
            }
            yield return new WaitForSeconds(Mathf.Min(Mathf.Pow(2, failures), 10));
        }
    }

    public IEnumerator Cancel()
    {
        if (!searching || ticketId == null) yield break;
        searching = false;
        using var del = Send("DELETE", $"/matchmaking/{UnityWebRequest.EscapeURL(ticketId)}", null);
        yield return del.SendWebRequest();   // 204, or 404/410 = already gone: all fine
        OnStatus?.Invoke("Cancelled");
    }

    void OnApplicationQuit()
    {
        if (searching && ticketId != null) Send("DELETE", $"/matchmaking/{UnityWebRequest.EscapeURL(ticketId)}", null).SendWebRequest(); // best effort; the backend sweep covers the rest
    }

    UnityWebRequest Send(string method, string path, string json)
    {
        var req = new UnityWebRequest(backendUrl + path, method) { downloadHandler = new DownloadHandlerBuffer() };
        if (json != null)
        {
            req.uploadHandler = new UploadHandlerRaw(System.Text.Encoding.UTF8.GetBytes(json));
            req.SetRequestHeader("Content-Type", "application/json");
        }
        req.SetRequestHeader("Authorization", "Bearer " + getSessionToken());
        return req;
    }
}
```

Usage: `StartCoroutine(mm.PickRegion(r => StartCoroutine(mm.FindMatch(r ?? "us-east"))));`. The fallback should be a region your backend allows. Then, in `OnMatchFound`, point your transport at `host:port` (e.g. Unity Transport / Netcode `SetConnectionData(host, (ushort)port)`) and send `joinToken` in your first message. Some transports want an IP: resolve the hostname first with `System.Net.Dns.GetHostAddresses(host)`.

## Godot 4 (GDScript)

```gdscript
extends Node
## Autoload "Matchmaker". Talks only to YOUR backend (plus the public ping endpoints).

signal match_found(host: String, port: int, join_token: String)
signal status_changed(text: String)

const PING_REGIONS_URL := "https://api.gameflow.gg/v1/ping/regions"
@export var backend_url := "https://api.mygame.com"
var session_token := ""   # set from your login flow
var ticket_id := ""
var searching := false

func _http(method: int, url: String, body = null, timeout := 10.0) -> Dictionary:
    var req := HTTPRequest.new()
    req.timeout = timeout
    add_child(req)
    var headers := ["Authorization: Bearer " + session_token, "Content-Type: application/json"]
    var payload := "" if body == null else JSON.stringify(body)
    var err := req.request(url, headers, method, payload)
    if err != OK:
        req.queue_free()
        return {"code": 0, "json": null}
    var res = await req.request_completed   # [result, code, headers, body]
    req.queue_free()
    var text: String = res[3].get_string_from_utf8()
    return {"code": res[1], "json": JSON.parse_string(text) if text != "" else null}

func pick_region() -> String:
    var res := await _http(HTTPClient.METHOD_GET, PING_REGIONS_URL)
    if res.code != 200 or res.json == null:
        return ""
    var best := ""
    var best_ms := INF
    for r in res.json["regions"]:
        var url: String = r["endpoint"] if r["endpoint"].begins_with("http") else "https://" + r["endpoint"]
        var samples: Array[int] = []
        for i in 4:
            var t0 := Time.get_ticks_msec()
            var p := await _http(HTTPClient.METHOD_GET, url, null, 2.0)
            if p.code > 0 and i > 0:
                samples.append(Time.get_ticks_msec() - t0)
        if samples.is_empty():
            continue
        samples.sort()
        var median := samples[samples.size() / 2]
        if median < best_ms:
            best_ms = median
            best = r["name"]
    return best

func find_match(region: String) -> void:
    searching = true
    status_changed.emit("Searching…")
    var join := await _http(HTTPClient.METHOD_POST, backend_url + "/matchmaking/join", {"region": region})
    if join.code != 200:
        searching = false
        status_changed.emit("Could not join (%d)" % join.code)
        return
    ticket_id = join.json["ticketId"]
    var failures := 0
    while searching:
        var s := await _http(HTTPClient.METHOD_GET, backend_url + "/matchmaking/status/" + ticket_id.uri_encode(), null, 45.0)
        if not searching:
            return
        if s.code == 200:
            failures = 0
            if s.json["status"] == "assigned":
                searching = false
                match_found.emit(s.json["host"], int(s.json["port"]), s.json.get("joinToken", ""))
                return
            continue
        failures += 1
        if s.code == 410 or s.code == 401 or failures >= 5:
            searching = false
            status_changed.emit("Search failed. Try again.")
            return
        await get_tree().create_timer(min(pow(2, failures), 10)).timeout

func cancel() -> void:
    if not searching or ticket_id == "":
        return
    searching = false
    await _http(HTTPClient.METHOD_DELETE, backend_url + "/matchmaking/" + ticket_id.uri_encode())
    status_changed.emit("Cancelled")

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST and searching:
        cancel()   # best effort; the backend sweep covers crashes
```

On `match_found`, connect with e.g. `ENetMultiplayerPeer.create_client(host, port)` (UDP), or `WebSocketMultiplayerPeer.create_client("wss://%s:%d" % [host, port])` for TLS games, then send `join_token` in your first RPC.

## Browser (TypeScript)

```ts
const BACKEND = "https://api.mygame.com";
type Status = { status: "searching" } | { status: "assigned"; host: string; port: number; joinToken?: string };

async function getRegions(): Promise<{ name: string; endpoint: string }[]> {
  try {
    const r = await fetch("https://api.gameflow.gg/v1/ping/regions");
    if (r.ok) return (await r.json()).regions;
  } catch { /* CORS or network: fall back to your backend */ }
  const r = await fetch(`${BACKEND}/matchmaking/regions`); // your backend re-serves GameFlow's list (see below)
  return (await r.json()).regions;
}

export async function pickRegion(): Promise<string | undefined> {
  const results = await Promise.all((await getRegions()).map(async ({ name, endpoint }) => {
    const url = endpoint.startsWith("http") ? endpoint : `https://${endpoint}`;
    const samples: number[] = [];
    for (let i = 0; i < 4; i++) {
      const t0 = performance.now();
      try {
        await fetch(url, { mode: "no-cors", cache: "no-store", signal: AbortSignal.timeout(2000) });
        if (i > 0) samples.push(performance.now() - t0);
      } catch { /* unreachable sample */ }
    }
    samples.sort((a, b) => a - b);
    return { name, ms: samples.length ? samples[Math.floor(samples.length / 2)]! : Infinity };
  }));
  results.sort((a, b) => a.ms - b.ms);
  return results[0]?.ms !== Infinity ? results[0]?.name : undefined;
}

export async function findMatch(region: string, token: string, signal: AbortSignal): Promise<{ host: string; port: number; joinToken?: string }> {
  const auth = { Authorization: `Bearer ${token}` };
  const join = await fetch(`${BACKEND}/matchmaking/join`, {
    method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: JSON.stringify({ region }), signal,
  });
  if (!join.ok) throw new Error(`join failed: ${join.status}`);
  const { ticketId } = await join.json();
  signal.addEventListener("abort", () => {
    void fetch(`${BACKEND}/matchmaking/${encodeURIComponent(ticketId)}`, { method: "DELETE", headers: auth, keepalive: true });
  });

  let failures = 0;
  while (!signal.aborted) {
    try {
      const res = await fetch(`${BACKEND}/matchmaking/status/${encodeURIComponent(ticketId)}`, {
        headers: auth, signal: AbortSignal.any([signal, AbortSignal.timeout(45_000)]),
      });
      if (res.status === 410 || res.status === 401) throw Object.assign(new Error(`search ended: ${res.status}`), { fatal: true });
      if (!res.ok) throw new Error(`status ${res.status}`);
      failures = 0;
      const s = (await res.json()) as Status;
      if (s.status === "assigned") return { host: s.host, port: s.port, joinToken: s.joinToken };
    } catch (err) {
      if (signal.aborted || (err as { fatal?: boolean }).fatal || ++failures >= 5) throw err;
      await new Promise((r) => setTimeout(r, Math.min(1000 * 2 ** failures, 10_000)));
    }
  }
  throw new Error("cancelled");
}

// UI: const ctl = new AbortController(); cancelButton.onclick = () => ctl.abort();
// window.addEventListener("pagehide", () => ctl.abort());
// const { host, port, joinToken } = await findMatch((await pickRegion()) ?? "us-east", token, ctl.signal);
// const ws = new WebSocket(`wss://${host}:${port}`);   // TLS games: host is a hostname with a valid cert
```

Backend helper for the region fallback (Express, cached, no key needed):

```ts
let cache: { at: number; body: unknown } | undefined;
app.get("/matchmaking/regions", async (_req, res) => {
  if (!cache || Date.now() - cache.at > 600_000) {
    const r = await fetch("https://api.gameflow.gg/v1/ping/regions");
    cache = { at: Date.now(), body: await r.json() };
  }
  res.json(cache.body);
});
```

## UX checklist

- [ ] Show elapsed search time and a Cancel button. Cancel calls DELETE, then returns to the menu.
- [ ] Disable "Find match" while searching. The backend join is idempotent anyway.
- [ ] On `410` or 5 failures in a row, show "Search failed. Try again." and start a **new** join on retry.
- [ ] If connecting to `host:port` fails or times out (~15 s), show "Match unavailable" and offer to search again. Don't reuse the old ticket.
- [ ] Browsers can't use raw UDP or TCP: browser games need a WebSocket/TLS game server (protocol TLS → `wss://host:port`).
