//
//  AdvanceServer.swift
//  SageOS
//
//  In-app HTTP control surface so the researcher on a Mac (same Wi-Fi) can
//  advance scenes, start/end sessions, and *monitor* the live gaze state from
//  a browser tab on their laptop, while the participant wears the headset
//  and clicks Spline buttons inside the immersive scene.
//
//  Endpoints:
//    GET  /         — control + monitoring dashboard
//    GET  /state    — JSON snapshot (scene, samples, latest yaw/pitch, trail)
//    POST /advance  — calls AppModel.advance(), 204 No Content
//    POST /start    — calls AppModel.startNewSession()
//    POST /end      — calls AppModel.endSession()
//
//  Advertised via Bonjour as `_sageos._tcp.` on port 9876. Once the headset
//  is running, open `http://<headset-ip>:9876` from your Mac browser; the IP
//  is printed to the Xcode console.
//
//  Resilience: this server *must* survive the AVP being taken off the head.
//  Off-head → app suspends → NWListener gets cancelled by the OS. When the
//  next participant puts the headset on, the app resumes and we need the
//  listener back. We handle that two ways:
//    1. stateUpdateHandler auto-restarts on .failed/.cancelled (unless the
//       caller explicitly called stop()).
//    2. AppModel runs a watchdog Task that calls start() every few seconds;
//       start() is idempotent, so it's a no-op when healthy and a restart
//       when not.
//
//  Concurrency: the class is NOT MainActor-isolated. NWListener callbacks
//  are `@Sendable`, and Swift 6 would error on capturing a MainActor `self`
//  inside them. All listener queues are pinned to `.main`; we use
//  `MainActor.assumeIsolated` to call MainActor-typed callbacks back into
//  `AppModel`. State that needs SwiftUI observation lives in `AppModel`,
//  updated via the `on…` callbacks.
//

import Darwin
import Foundation
import Network

final class AdvanceServer: @unchecked Sendable {

    var onAdvance: @MainActor () -> Void = {}
    var onStartSession: @MainActor () -> Void = {}
    var onEndSession: @MainActor () -> Void = {}
    var stateProvider: @MainActor () -> StateSnapshot = { .empty }
    var onURLChange: @MainActor (String?) -> Void = { _ in }
    var onRunningChange: @MainActor (Bool) -> Void = { _ in }

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 9876
    /// True when the listener has reached `.ready` at least once since the
    /// last `start()`. Used by `start()` to no-op when healthy.
    private var isReady = false
    /// True if `stop()` was the cause of the last shutdown. We use this to
    /// decide whether `.cancelled`/`.failed` should auto-restart.
    private var stopRequested = false

    struct StateSnapshot: Codable, Sendable {
        var scene: String
        var index: Int
        var total: Int
        var gate: String
        var samples: Int
        var recording: Bool
        var sessionsRecorded: Int
        /// Latest head-pose yaw in radians (0 = forward, +right). 0 if no data.
        var yaw: Float
        /// Latest head-pose pitch in radians (+up). 0 if no data.
        var pitch: Float
        /// Milliseconds since the most recent gaze sample arrived. -1 if none.
        /// Lets the browser show "fresh" vs "stale" vs "dead" status without
        /// guessing from sample count alone.
        var lastSampleAgoMs: Int
        /// ARKit world-tracking provider's reported state ("running",
        /// "paused", "not-started", etc.).
        var providerState: String
        /// Recent (yaw, pitch) samples for the live trail canvas. Newest last.
        /// Capped to keep the JSON payload small.
        var trail: [TrailPoint]

        static let empty = StateSnapshot(
            scene: "—", index: 0, total: 0, gate: "—",
            samples: 0, recording: false, sessionsRecorded: 0,
            yaw: 0, pitch: 0, lastSampleAgoMs: -1,
            providerState: "not-started", trail: []
        )
    }

    /// Compact representation so the trail JSON doesn't blow up: ~60 points
    /// at ~12 bytes each = under 1 KB per /state response.
    struct TrailPoint: Codable, Sendable {
        var y: Float  // yaw radians
        var p: Float  // pitch radians
    }

    /// Idempotent. Returns immediately if a listener is already ready;
    /// otherwise tears down any stale listener and binds a fresh one.
    /// Safe to call repeatedly from a watchdog.
    func start() {
        stopRequested = false
        if let l = listener, isReady, case .ready = l.state {
            return
        }
        // Tear down anything stale before re-binding.
        listener?.cancel()
        listener = nil
        isReady = false

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        do {
            let l = try NWListener(using: params, on: port)
            l.service = NWListener.Service(name: "SageOS",
                                           type: "_sageos._tcp",
                                           domain: nil,
                                           txtRecord: nil)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                self?.applyState(state)
            }
            l.start(queue: .main)
            listener = l
        } catch {
            print("[AdvanceServer] could not bind port \(port): \(error)")
            // Schedule a retry: maybe a stale socket holding the port.
            scheduleRestart(after: 2)
        }
    }

    func stop() {
        stopRequested = true
        listener?.cancel()
        listener = nil
        isReady = false
        MainActor.assumeIsolated { onRunningChange(false) }
    }

    private func scheduleRestart(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.stopRequested else { return }
            self.start()
        }
    }

    // MARK: - Listener-side (all on .main queue)

    private func applyState(_ state: NWListener.State) {
        switch state {
        case .ready:
            // visionOS sandbox blocks gethostname() (returns "localhost")
            // and SCDynamicStoreCopyLocalHostName is unavailable, so we
            // print the IPv4 URL — works on hotspot/home Wi-Fi — and rely
            // on tools/watch_and_open.py to discover the mDNS hostname via
            // dns-sd and open Safari for client-isolated Wi-Fi.
            let ip = Self.firstIPv4Address() ?? "<unknown>"
            let url = "http://\(ip):\(port)"
            isReady = true
            print("[AdvanceServer] ready — open \(url) on your Mac")
            print("[AdvanceServer] or run on your Mac: python3 tools/watch_and_open.py")
            MainActor.assumeIsolated {
                onRunningChange(true)
                onURLChange(url)
            }

        case .failed(let err):
            print("[AdvanceServer] failed: \(err) — will restart in 1s")
            isReady = false
            listener?.cancel()
            listener = nil
            MainActor.assumeIsolated { onRunningChange(false) }
            if !stopRequested {
                scheduleRestart(after: 1)
            }

        case .cancelled:
            isReady = false
            MainActor.assumeIsolated { onRunningChange(false) }
            if !stopRequested {
                // Almost always means the OS cancelled us during app suspend
                // (participant took the headset off). When the app resumes,
                // restart so the laptop control page can reach us again.
                print("[AdvanceServer] cancelled — restarting in 1s")
                scheduleRestart(after: 1)
            }

        default:
            break
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if let headerEnd = self.endOfHeaders(in: buf) {
                let header = buf.prefix(headerEnd)
                self.respond(to: header, on: conn)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, accumulated: buf)
            }
        }
    }

    private func endOfHeaders(in data: Data) -> Int? {
        let needle: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        guard data.count >= needle.count else { return nil }
        for i in 0...(data.count - needle.count) {
            if Array(data[i..<i + needle.count]) == needle {
                return i + needle.count
            }
        }
        return nil
    }

    private func respond(to header: Data, on conn: NWConnection) {
        guard let line = String(data: header, encoding: .utf8)?
                .components(separatedBy: "\r\n").first else {
            write(conn, status: 400, headers: [:], body: Data())
            return
        }
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.dropFirst().first.map(String.init) ?? "/"

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            let body = Data(Self.controlPageHTML.utf8)
            write(conn, status: 200,
                  headers: ["Content-Type": "text/html; charset=utf-8"],
                  body: body)

        case ("GET", "/state"):
            let snap: StateSnapshot = MainActor.assumeIsolated { stateProvider() }
            let body = (try? JSONEncoder().encode(snap)) ?? Data("{}".utf8)
            write(conn, status: 200,
                  headers: ["Content-Type": "application/json",
                            "Cache-Control": "no-store"],
                  body: body)

        case ("POST", "/advance"), ("GET", "/advance"):
            MainActor.assumeIsolated { onAdvance() }
            write(conn, status: 204, headers: [:], body: Data())

        case ("POST", "/start"), ("GET", "/start"):
            MainActor.assumeIsolated { onStartSession() }
            write(conn, status: 204, headers: [:], body: Data())

        case ("POST", "/end"), ("GET", "/end"):
            MainActor.assumeIsolated { onEndSession() }
            write(conn, status: 204, headers: [:], body: Data())

        default:
            write(conn, status: 404, headers: [:], body: Data("not found".utf8))
        }
    }

    private func write(_ conn: NWConnection, status: Int,
                       headers: [String: String], body: Data) {
        let reason = Self.reasonPhrase(for: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        h["Access-Control-Allow-Origin"] = "*"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "OK"
        }
    }

    // MARK: - Interface discovery

    /// Best-guess local IPv4. Skips loopback and link-local so the printed
    /// URL is the address the Mac actually reaches over Wi-Fi.
    static func firstIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let i = p.pointee
            if let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let host = String(cString: hostname)
                let name = String(cString: i.ifa_name)
                if !host.isEmpty,
                   !host.hasPrefix("127."),
                   !host.hasPrefix("169.254."),
                   name != "lo0" {
                    return host
                }
            }
            ptr = i.ifa_next
        }
        return nil
    }

    // MARK: - Control page

    static let controlPageHTML = #"""
    <!doctype html>
    <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>SageOS · control</title>
      <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body { font: 15px -apple-system,system-ui,sans-serif; background:#0a0a0c; color:#eee;
               margin:0; padding:20px; display:flex; justify-content:center; min-height:100vh; }
        .card { background:#15151a; padding:24px; border-radius:14px;
                width:100%; max-width:560px; box-shadow:0 8px 30px rgba(0,0,0,.5);
                display:flex; flex-direction:column; gap:18px; }

        /* connection banner */
        .conn { display:flex; align-items:center; gap:10px;
                padding:10px 14px; border-radius:10px; font-weight:600; font-size:14px;
                transition:background .3s; }
        .conn .dot { width:10px; height:10px; border-radius:50%; flex:0 0 auto;
                     box-shadow:0 0 8px currentColor; }
        .conn.live   { background:rgba(60,200,120,.12); color:#3c6; }
        .conn.live   .dot { background:#3c6; animation:pulse 2s infinite; }
        .conn.warn   { background:rgba(255,180,60,.12); color:#fb6; }
        .conn.warn   .dot { background:#fb6; animation:pulse 1s infinite; }
        .conn.dead   { background:rgba(220,80,80,.12); color:#e66; }
        .conn.dead   .dot { background:#e66; }
        @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.4 } }

        /* scene block */
        .scene-row { display:flex; align-items:baseline; justify-content:space-between; }
        .scene-name { font-size:30px; font-weight:700; word-break:break-word; }
        .scene-meta { color:#889; font-size:13px; letter-spacing:.02em; }

        /* stats grid */
        .stats { display:grid; grid-template-columns:repeat(4, 1fr); gap:10px; }
        .stat { background:#1c1c22; padding:10px 12px; border-radius:8px; }
        .stat .k { color:#778; font-size:11px; text-transform:uppercase; letter-spacing:.06em; }
        .stat .v { font-size:18px; font-weight:600; margin-top:2px; font-variant-numeric:tabular-nums; }
        .stat .v.dim { color:#667; }

        /* live trail canvas */
        .trail-wrap { background:#08080a; border-radius:10px; padding:8px; position:relative; }
        canvas { width:100%; height:auto; display:block; border-radius:6px; }
        .trail-meta { position:absolute; top:14px; right:14px; font-size:11px; color:#667;
                      font-family:ui-monospace,monospace; }

        /* buttons */
        button { padding:16px 14px; font-size:16px; font-weight:600; color:white;
                 border:0; border-radius:10px; cursor:pointer; transition:background .1s, opacity .15s;
                 font-family:inherit; }
        button:disabled { background:#23232a !important; cursor:not-allowed; opacity:.45; }
        #next  { background:#28a16a; flex:2; padding:22px 14px; font-size:19px; }
        #next:not(:disabled):hover  { background:#2eb978; }
        #start { background:#2a6fd6; }
        #start:not(:disabled):hover { background:#3681e8; }
        #end   { background:#a13a3a; }
        #end:not(:disabled):hover   { background:#b54545; }
        .row { display:flex; gap:10px; }

        .keys { color:#667; font-size:12px; }
        kbd { background:#222; padding:1px 6px; border-radius:4px;
              font-family:ui-monospace,monospace; font-size:11px; color:#bbd; }

        .log { font-family:ui-monospace,monospace; font-size:12px; color:#778;
               max-height:180px; overflow-y:auto;
               border-top:1px solid #222; padding-top:12px; }
        .log div { padding:2px 0; }
        .log .sys { color:#9aa; }
        .log .warn { color:#fb6; }
      </style>
    </head><body>
      <div class="card">

        <div class="conn warn" id="conn">
          <span class="dot"></span>
          <span id="conn-text">connecting…</span>
        </div>

        <div>
          <div class="scene-row">
            <div class="scene-meta">scene <span id="idx">–</span>/<span id="total">–</span> · sessions: <span id="sessions">0</span></div>
            <div class="scene-meta" id="rec-state">idle</div>
          </div>
          <div class="scene-name" id="scene">—</div>
        </div>

        <div class="stats">
          <div class="stat"><div class="k">samples</div><div class="v" id="samples">0</div></div>
          <div class="stat"><div class="k">last</div><div class="v" id="latency">—</div></div>
          <div class="stat"><div class="k">yaw °</div><div class="v" id="yaw">—</div></div>
          <div class="stat"><div class="k">pitch °</div><div class="v" id="pitch">—</div></div>
        </div>

        <div class="trail-wrap">
          <canvas id="trail" width="540" height="280"></canvas>
          <div class="trail-meta" id="provider">provider: —</div>
        </div>

        <div class="row">
          <button id="next" disabled>Next scene →</button>
        </div>
        <div class="row">
          <button id="start" style="flex:1">Start new session</button>
          <button id="end"   style="flex:1" disabled>End session</button>
        </div>

        <div class="keys">
          <kbd>space</kbd>/<kbd>→</kbd> next · <kbd>n</kbd> new session · <kbd>e</kbd> end
        </div>

        <div class="log" id="log"></div>
      </div>

      <script>
        const $ = id => document.getElementById(id);
        const FOV_H_DEG = 60, FOV_V_DEG = 40;   // canvas mapping range; not the recording FOV

        let connected = false;
        let lastScene = null;
        let lastRecording = null;
        let lastSampleCount = null;
        let lastTrail = [];

        function logLine(text, cls) {
          const div = document.createElement('div');
          div.textContent = new Date().toLocaleTimeString() + '  ' + text;
          if (cls) div.className = cls;
          $('log').prepend(div);
          // cap log size
          while ($('log').children.length > 100) $('log').lastChild.remove();
        }

        function setConn(state, msg) {
          $('conn').className = 'conn ' + state;
          $('conn-text').textContent = msg;
        }

        function setRecording(rec) {
          $('rec-state').textContent = rec ? '● recording' : '○ idle';
          $('rec-state').style.color = rec ? '#3c6' : '#778';
          $('next').disabled = !rec;
          $('end').disabled = !rec;
        }

        function drawTrail(points) {
          const c = $('trail');
          // adjust canvas resolution to match displayed size, once
          const dpr = window.devicePixelRatio || 1;
          if (c.width !== c.clientWidth * dpr) {
            c.width = c.clientWidth * dpr;
            c.height = Math.round(c.clientWidth * 0.52) * dpr;
            c.style.height = Math.round(c.clientWidth * 0.52) + 'px';
          }
          const ctx = c.getContext('2d');
          const W = c.width, H = c.height;
          ctx.fillStyle = '#08080a';
          ctx.fillRect(0, 0, W, H);

          // crosshair
          ctx.strokeStyle = '#1a1a22';
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(W/2, 0); ctx.lineTo(W/2, H);
          ctx.moveTo(0, H/2); ctx.lineTo(W, H/2);
          ctx.stroke();

          if (!points || !points.length) return;

          const fovH = FOV_H_DEG * Math.PI / 180;
          const fovV = FOV_V_DEG * Math.PI / 180;
          const toPx = (y, p) => [
            W/2 + (y / (fovH/2)) * (W/2),
            H/2 - (p / (fovV/2)) * (H/2),
          ];

          // fading trail
          for (let i = 0; i < points.length; i++) {
            const [x, yy] = toPx(points[i].y, points[i].p);
            const a = (i + 1) / points.length;
            ctx.fillStyle = `rgba(80,200,140,${a * 0.7})`;
            ctx.beginPath();
            ctx.arc(x, yy, 3 * dpr, 0, Math.PI*2);
            ctx.fill();
          }
          // current point as ring
          const last = points[points.length - 1];
          const [lx, ly] = toPx(last.y, last.p);
          ctx.strokeStyle = '#3c6';
          ctx.lineWidth = 2 * dpr;
          ctx.beginPath();
          ctx.arc(lx, ly, 9 * dpr, 0, Math.PI*2);
          ctx.stroke();
        }

        function updateFromState(s) {
          // banner state based on session + tracking liveness
          const fresh = s.lastSampleAgoMs >= 0 && s.lastSampleAgoMs < 1500;
          if (s.recording) {
            if (fresh) {
              setConn('live', 'live · head tracking active');
            } else {
              setConn('warn', `recording but no fresh samples (${s.lastSampleAgoMs < 0 ? 'never' : s.lastSampleAgoMs + 'ms ago'}) — headset on?`);
            }
          } else {
            setConn('warn', 'idle — press Start new session');
          }

          $('idx').textContent = s.index + 1;
          $('total').textContent = s.total;
          $('scene').textContent = s.scene;
          $('sessions').textContent = s.sessionsRecorded;
          $('samples').textContent = s.samples.toLocaleString();
          $('latency').textContent = s.lastSampleAgoMs < 0 ? '—'
              : (s.lastSampleAgoMs < 10000 ? s.lastSampleAgoMs + 'ms' : '>10s');
          $('latency').className = 'v' + (fresh ? '' : ' dim');
          $('yaw').textContent   = (s.yaw   * 180 / Math.PI).toFixed(1);
          $('pitch').textContent = (s.pitch * 180 / Math.PI).toFixed(1);
          $('provider').textContent = 'provider: ' + s.providerState;

          setRecording(s.recording);
          $('start').disabled = false;
          drawTrail(s.trail);

          if (lastRecording !== null && lastRecording !== s.recording) {
            logLine(s.recording ? '● session started' : '○ session ended', 'sys');
          }
          if (lastScene !== null && lastScene !== s.scene && s.recording) {
            logLine('→ ' + s.scene);
          }
          lastScene = s.scene;
          lastRecording = s.recording;
          lastSampleCount = s.samples;
        }

        async function refreshOnce() {
          const r = await fetch('/state', { cache: 'no-store' });
          if (!r.ok) throw new Error('http ' + r.status);
          return r.json();
        }

        // Polling loop that NEVER stops. When disconnected, it backs off to
        // 1.5s; when live, it polls every 400ms. As soon as the AVP comes
        // back, the very next fetch lands and the UI snaps to live again.
        async function loop() {
          try {
            const s = await refreshOnce();
            if (!connected) {
              connected = true;
              logLine('reconnected to headset', 'sys');
            }
            updateFromState(s);
          } catch (e) {
            if (connected) {
              connected = false;
              logLine('lost connection — headset asleep?', 'warn');
            }
            setConn('dead', 'headset offline — reconnecting…');
            // freeze recording indicator; we don't know if it's still on
          } finally {
            // Poll cadence kept gentle on purpose: the AVP's CPU/GPU is
            // shared with the immersive Spline scene AND AirPlay mirroring;
            // higher poll rates (we tried 400ms) visibly chopped the
            // mirror. 1s is plenty for a live monitoring dashboard.
            setTimeout(loop, connected ? 1000 : 2000);
          }
        }

        async function send(path, btnId) {
          if (btnId) {
            const b = $(btnId);
            b.disabled = true;
            setTimeout(() => { b.disabled = false; }, 350);
          }
          try { await fetch(path, { method:'POST' }); } catch (e) {}
          setTimeout(refreshOnce().then(updateFromState).catch(()=>{}), 80);
        }

        $('next').onclick  = () => send('/advance', 'next');
        $('start').onclick = () => send('/start',   'start');
        $('end').onclick   = () => send('/end',     'end');

        document.addEventListener('keydown', e => {
          if (e.target.tagName === 'INPUT') return;
          if (e.code === 'Space' || e.code === 'ArrowRight' || e.code === 'Enter') {
            if (!$('next').disabled) { e.preventDefault(); send('/advance', 'next'); }
          } else if (e.key === 'n' || e.key === 'N') {
            e.preventDefault(); send('/start', 'start');
          } else if (e.key === 'e' || e.key === 'E') {
            if (!$('end').disabled) { e.preventDefault(); send('/end', 'end'); }
          }
        });

        loop();
      </script>
    </body></html>
    """#
}
