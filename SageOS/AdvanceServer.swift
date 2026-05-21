//
//  AdvanceServer.swift
//  SageOS
//
//  In-app HTTP control surface so the researcher on a Mac (same Wi-Fi) can
//  advance scenes by clicking a button in a browser, while the participant
//  wears the headset and clicks Spline buttons inside the immersive scene.
//
//  Endpoints:
//    GET  /         — control page (live scene + Next button)
//    GET  /state    — JSON snapshot of current scene/sample state
//    POST /advance  — calls AppModel.advance(), 204 No Content
//
//  Advertised via Bonjour as `_sageos._tcp.` on port 9876. Once the headset
//  is running, open `http://<headset-ip>:9876` from your Mac browser; the IP
//  is printed to the Xcode console and shown in the debug window.
//
//  Concurrency note: the class is NOT MainActor-isolated. The `NWListener`
//  callbacks are `@Sendable`, and Swift 6 would error on capturing a
//  MainActor `self` inside them. We pin all listener/connection queues to
//  `.main` so the callbacks always fire on the main thread; we then use
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

    struct StateSnapshot: Codable, Sendable {
        var scene: String
        var index: Int
        var total: Int
        var gate: String
        var samples: Int
        var recording: Bool
        var sessionsRecorded: Int

        static let empty = StateSnapshot(scene: "—", index: 0, total: 0,
                                         gate: "—", samples: 0, recording: false,
                                         sessionsRecorded: 0)
    }

    func start() {
        guard listener == nil else { return }
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
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        MainActor.assumeIsolated { onRunningChange(false) }
    }

    // MARK: - Listener-side (all on .main queue)

    private func applyState(_ state: NWListener.State) {
        switch state {
        case .ready:
            // visionOS's sandbox blocks both gethostname() (returns
            // "localhost") and SCDynamicStoreCopyLocalHostName (marked
            // unavailable), so we can't compute the device's .local
            // hostname from inside the app. We print the IPv4 URL — works
            // on hotspot/home Wi-Fi — and rely on the Mac-side watcher
            // script (tools/watch_and_open.py) to discover the real
            // mDNS hostname via dns-sd and open the right URL in Safari.
            // That path works even on client-isolated Wi-Fi via AWDL.
            let ip = Self.firstIPv4Address() ?? "<unknown>"
            let url = "http://\(ip):\(port)"
            print("[AdvanceServer] ready — open \(url) on your Mac")
            print("[AdvanceServer] or run on your Mac: python3 tools/watch_and_open.py")
            MainActor.assumeIsolated {
                onRunningChange(true)
                onURLChange(url)
            }
        case .failed(let err):
            print("[AdvanceServer] failed: \(err)")
            MainActor.assumeIsolated { onRunningChange(false) }
        case .cancelled:
            MainActor.assumeIsolated { onRunningChange(false) }
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
            // MainActor-typed stateProvider, called synchronously because we
            // know NWListener delivered this on the main thread.
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

    static let controlPageHTML = """
    <!doctype html>
    <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>SageOS control</title>
      <style>
        :root { color-scheme: dark; }
        body { font: 15px -apple-system,system-ui,sans-serif; background:#0c0c0e; color:#eee;
               margin:0; padding:24px; display:flex; justify-content:center; }
        .card { background:#17171b; padding:28px; border-radius:14px;
                width:100%; max-width:520px; box-shadow:0 8px 30px rgba(0,0,0,.4); }
        .meta { color:#9aa; font-size:13px; letter-spacing:.02em; }
        .scene { font-size:32px; font-weight:600; margin:8px 0 4px; word-break:break-word; }
        .rec { display:inline-block; width:8px; height:8px; border-radius:50%;
               background:#666; margin-right:6px; vertical-align:middle; }
        .rec.on { background:#3c6; box-shadow:0 0 8px #3c6; }
        button { padding:18px 14px; font-size:17px; font-weight:600; color:white;
                 border:0; border-radius:10px; cursor:pointer; transition:background .1s;
                 font-family:inherit; }
        button:disabled { background:#2a2a2f !important; cursor:not-allowed; opacity:.55; }
        #next  { background:#28a16a; flex:2; padding:26px 14px; font-size:21px; }
        #next:not(:disabled):hover  { background:#2cb578; }
        #start { background:#2a6fd6; }
        #start:not(:disabled):hover { background:#3681e8; }
        #end   { background:#a13a3a; }
        #end:not(:disabled):hover   { background:#b54545; }
        .row { display:flex; gap:10px; margin-top:18px; }
        .row.primary { margin-top:24px; }
        .log { font-family:ui-monospace,monospace; font-size:12px; color:#778;
               margin-top:18px; max-height:220px; overflow-y:auto;
               border-top:1px solid #222; padding-top:12px; }
        .log div { padding:3px 0; }
        .log .sys { color:#9aa; }
        kbd { background:#222; padding:1px 6px; border-radius:4px;
              font-family:ui-monospace,monospace; font-size:12px; color:#bbd; }
      </style>
    </head><body>
      <div class="card">
        <div class="meta">sessions recorded: <span id="sessions">0</span></div>
        <div class="meta" style="margin-top:6px">scene <span id="idx">–</span>/<span id="total">–</span></div>
        <div class="scene" id="scene">connecting…</div>
        <div class="meta"><span class="rec" id="rec"></span><span id="recording">idle</span>
          · samples: <span id="samples">0</span></div>

        <div class="row primary">
          <button id="next" disabled>Next scene →</button>
        </div>
        <div class="row">
          <button id="start" style="flex:1">Start new session</button>
          <button id="end"   style="flex:1" disabled>End session</button>
        </div>
        <div class="meta" style="margin-top:14px">
          <kbd>space</kbd>/<kbd>→</kbd> next · <kbd>n</kbd> new · <kbd>e</kbd> end
        </div>
        <div class="log" id="log"></div>
      </div>
      <script>
        const $ = id => document.getElementById(id);
        let last = null;
        let lastRecording = null;
        function logLine(text, sys) {
          const li = document.createElement('div');
          li.textContent = new Date().toLocaleTimeString() + '  ' + text;
          if (sys) li.className = 'sys';
          $('log').prepend(li);
        }
        async function refresh() {
          try {
            const r = await fetch('/state', { cache: 'no-store' });
            if (!r.ok) throw new Error(r.status);
            const s = await r.json();
            $('scene').textContent = s.scene;
            $('idx').textContent = s.index + 1;
            $('total').textContent = s.total;
            $('samples').textContent = s.samples.toLocaleString();
            $('sessions').textContent = s.sessionsRecorded;
            $('recording').textContent = s.recording ? 'recording' : 'idle';
            $('rec').classList.toggle('on', s.recording);
            $('next').disabled  = !s.recording;
            $('end').disabled   = !s.recording;
            $('start').disabled = false;  // always armed: it can also restart
            if (lastRecording !== null && lastRecording !== s.recording) {
              logLine(s.recording ? '● session started' : '○ session ended', true);
            }
            if (last && last !== s.scene && s.recording) {
              logLine('→ ' + s.scene);
            }
            last = s.scene;
            lastRecording = s.recording;
          } catch (e) {
            $('scene').textContent = 'disconnected';
            $('rec').classList.remove('on');
          }
        }
        async function send(path, btnId) {
          if (btnId) { const b = $(btnId); b.disabled = true; setTimeout(() => b.disabled = false, 350); }
          try { await fetch(path, { method:'POST' }); } catch (e) {}
          setTimeout(refresh, 80);
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
        setInterval(refresh, 400);
        refresh();
      </script>
    </body></html>
    """
}
