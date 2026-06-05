# NeuraLearn / SageOS — A Gaze-Tracking Research Probe for Apple Vision Pro

Case study of the build, the constraint that shaped it, and the workaround that made data collection possible at the grad show.

---

## 1. The research goal

The exhibition piece is an immersive Spline experience built for Apple Vision Pro. As a grad-show research probe, I wanted to know *what* visitors actually paid attention to as they moved through the eleven scenes of the experience — which on-screen elements pulled their gaze, where attention concentrated within each scene, and what they looked at during the decision moments (consent gates, homework selection, adjustment prompts).

The deliverable I designed toward:

- **Per-participant time-series of attention**, scoped to each scene.
- **Per-scene heatmaps** showing where attention concentrated.
- **A "follow the eyes" trail** overlaid onto the actual screen recording of what the participant saw, so I could narrate the experience visually for the case study.

---

## 2. The constraint that shaped everything

Apple does not expose raw eye-gaze data to third-party apps on visionOS. This is not an oversight or a hidden entitlement — it is a deliberate privacy decision. The only way an app "uses" eye gaze is implicitly: the system handles dwell-to-select for UI buttons, but the app never sees gaze coordinates. There is no API, no entitlement to request, no workaround at that layer.

This blocked the obvious approach (record where the user is looking) before I'd written a line of code. So the question became: *what signal can I capture that correlates with attention, even imperfectly?*

---

## 3. The workaround — head pose as an attention proxy

The premise: in a fully immersive Spline scene where content is distributed across the user's field of view, people **orient their head toward what holds their attention**. A user fixating on the top-right of the scene tilts their head up and right; a user reading text in the lower-left brings their head down and left. Pure eye-flicks are missed, but head-anchored attention shifts are captured cleanly.

Apple **does** expose device pose (the AVP's 6-DoF position and orientation in world space) through ARKit's `WorldTrackingProvider`. Calling `queryDeviceAnchor(atTimestamp:)` on a polling loop gives me the full transform of the headset at ~60 Hz. From the transform's forward vector I derive:

- **yaw** = `atan2(forward.x, -forward.z)` — left/right head turn
- **pitch** = `asin(forward.y)` — up/down tilt

Combined with the current scene label, that becomes a JSON time series: `{t, yaw, pitch, scene}`. A 100-second session produces ~6,000 samples and ~600 KB of JSON.

This is a proxy, not eye-gaze. It has real limits (Section 8). But for an immersive experience where attention shifts come with head motion, it's enough to produce meaningful heatmaps and trails.

---

## 4. System architecture

Three pieces working together:

```
┌─────────────────────────┐        ┌──────────────────────┐         ┌───────────────────────┐
│  Apple Vision Pro        │  Wi-Fi │  Laptop / phone       │  AirPlay │  Monitor (audience)    │
│  ──────────────────────  │ ◀───▶  │  ──────────────────   │ ◀──────  │  (Reflector mirror)    │
│  • SageOS app            │        │  • Browser at IP:9876 │         └───────────────────────┘
│  • Spline immersive demo │        │  • Next / Start / End │
│  • Head-pose recorder    │        │    buttons             │
│  • HTTP control server   │        │  • Live state polling │
│    (NWListener, Bonjour) │        └──────────────────────┘
└─────────────────────────┘
              │
              │  After the show: devicectl copies app Documents to Mac
              ▼
       ┌───────────────────────────┐
       │  Python visualization      │
       │  (numpy, scipy, opencv)    │
       │  → per-scene heatmaps      │
       │  → trail overlays on .mov  │
       │  → heatmap overlays on .mov│
       └───────────────────────────┘
```

### 4.1 The headset app (`SageOS`)

- Runs the Spline scene as an `ImmersiveSpace` using `SplineImmersiveSpaceContent(sceneFileURL:)`.
- A `GazeSession` actor (`@MainActor @Observable`) owns a `WorldTrackingProvider` and a detached polling task. The polling task queries device pose off the main actor, then hops back to MainActor to ingest each sample. It writes the JSON every 3 seconds (checkpointing) so a crash doesn't lose data, and again on `end()`.
- An `AdvanceServer` (deliberately *not* MainActor — `final class … @unchecked Sendable` pinned to `.main` queue) runs an HTTP server on port 9876 and advertises Bonjour service `_sageos._tcp`.
- A 2D "operator" window shows the control URL as both readable text and a **QR code** so the operator can scan it off the Reflector mirror with a phone.
- A second toggleable "gaze-debug" 2D window shows live recording state, sample count, current scene/gate, and a fading trail Canvas — for the developer to verify the rig is working. Set `debugLiveOverlay = false` for live participants so they see nothing extra.

### 4.2 The control page

The headset itself serves an HTML page on port 9876. The page polls `/state` every 400 ms and offers three actions:

- **Next scene** (POST `/advance`, or keyboard `space`) — bumps the scene index and tags subsequent samples.
- **New session** (POST `/start`, or `n`) — closes the immersive space, reopens it, resets the scene index, and starts a fresh recording.
- **End session** (POST `/end`, or `e`) — flushes the JSON.

This exists because Spline's *immersive* runtime, unlike its 2D `SplineView`, does not expose any event hooks — there is no `SplineController.addEventListener` to subscribe to button presses inside the scene. So scene transitions are **operator-driven**: I watch the live AirPlay mirror, see the participant trigger a scene's gate, and press space.

### 4.3 The visualization pipeline (`tools/gaze_heatmap.py`)

Runs on the Mac after a session. Reads the JSON, optionally smooths/centers, and produces:

- `gaze-<id>.json` → eleven `heatmap_<scene>.png` files (one per scene) + `heatmap_all.png`.
- Per-scene trail clips: `trail_<scene>.mp4`.
- `scene_overlay.mp4` — gaze trail + a moving pointer dot painted on top of the actual screen recording.
- `heatmap_overlay.mp4` — a rolling 8-second gaussian-blurred heatmap painted on top of the same recording.

The pixel mapping is straightforward perspective math:

```
x_px = W/2 + degrees(yaw)   * W / fov_h
y_px = H/2 - degrees(pitch) * H / fov_v
```

…with `fov_h` and `fov_v` tuned to match the recording's actual captured field of view (e.g. `90/52` for a 1814×1050 frame; `90/90` for a square-padded 1920×1920 frame from an iPad capture).

---

## 5. The build journey — key decisions

| Decision | Why |
|---|---|
| **One cloud Spline URL** loaded for the whole experience | Simpler than per-scene asset management; the Spline scene already encodes its own state machine. |
| **All eleven scenes button-gated** (no timers) | Operator advances each one. Lets the participant explore at their pace and lets me tag transitions precisely from the mirror. |
| **Multiple sessions per app launch** | "Start" and "End" on the control page — I don't have to rebuild from Xcode between participants. Each session writes its own JSON. |
| **Auto-start fallback on launch** | If the network/control page never connects (school Wi-Fi, hotspot off), the experience still runs and still records. The operator can later "End" and "Start" a clean session once the control page is up. The fallback never blocks the demo. |
| **Toggleable debug overlay** (default off for participants) | Verifies the rig is working without showing anything to the demo subject. |
| **QR code in the operator window** | Scan it off the Reflector mirror with a phone — no typing IPs. |

---

## 6. Hard problems I had to work around

### 6.1 Swift 6 strict concurrency + the HTTP server

`NWListener` callbacks fire on the connection queue, not the main actor. Writing the server as `@MainActor` produced *"reference to captured var self in concurrently-executing code"* errors. Fix:

- `AdvanceServer` is `final class … @unchecked Sendable` and **not** `@MainActor`.
- All callbacks (`onAdvance`, `onStartSession`, `onEndSession`, `stateProvider`, `onURLChange`, `onRunningChange`) are typed `@MainActor () -> Void`.
- The listener is pinned to `DispatchQueue.main`, and call sites that need to invoke MainActor closures use `MainActor.assumeIsolated { … }`.

### 6.2 `WorldTrackingProvider` is single-use

After the first `session.run`, calling `start()` a second time would silently put the provider in the `.paused` state and produce zero samples. Fix: store `worldTracking` as a `var` and **recreate it** on every `start()`. Same for `ARKitSession` if needed.

### 6.3 No reliable `.local` hostname on visionOS

`SCDynamicStoreCopyLocalHostName` is not available on visionOS, and `gethostname()` returns `localhost` inside the sandbox — which would print a useless `localhost.local` URL. Fix: enumerate IPv4 interfaces via `getifaddrs()` and use the device's actual `10.x.x.x` / `192.168.x.x` address in the URL. The Bonjour advertisement carries the canonical `.local` name for clients that can resolve it, and a small Mac-side `tools/watch_and_open.py` listens for `_sageos._tcp` and auto-opens the URL in Safari (forced, because Chrome can't reach IPv6 link-local AWDL addresses without an explicit zone ID).

### 6.4 Public Wi-Fi client isolation

School Wi-Fi blocks peer-to-peer discovery. There is no app-level fix. Operational workaround: bring an iPhone hotspot (or a travel router) and put both the AVP and the laptop on the same SSID. On hotspot, Bonjour works and the laptop reaches the control page over the standard `10.x.x.x:9876` URL.

### 6.5 Sharing the live view to an audience

Mirroring the AVP onto the laptop screen via Reflector worked, but using a second monitor as the mirror destination blacked out the operator's primary display. Solution: keep the Reflector window on the laptop and **drag it onto a secondary monitor** as an ordinary window. Audience sees what the participant sees; operator keeps their workspace.

### 6.6 OpenCV + screen recordings

The visualization pipeline uses `opencv-python`. Some screen recordings come down as HEVC, which OpenCV won't decode out of the box — needs `ffmpeg` to transcode to H.264 first. Other times the issue isn't the codec at all; it's a filename with embedded spaces being passed through shell escaping incorrectly. Lesson: resolve the path with `find … -print -quit` and quote it once, end-to-end.

### 6.7 Synchronizing the recording with the gaze log

The screen recording (Reflector) and the gaze session start independently — there is no shared clock. The pipeline takes a `--offset` flag (seconds the gaze log starts after the recording starts) and the dot is positioned at `t_gaze = t_recording - offset`. Tuning is empirical: I open the overlay, watch a known scene transition, and nudge `--offset` until the dot moves at the same moment the on-screen content changes. For the May 27 session, the math from filename timestamps gave 54s and review pulled it to 53s.

### 6.8 Field-of-view calibration

The `fov_h` / `fov_v` knobs convert degrees of head turn into pixels on the recording. They depend on the actual captured field of view, which is not documented anywhere I could find for the AirPlay shared view. I tune them once per recording shape: `90 / 52` for the 1814×1050 captures, `90 / 90` for an older 1920×1920 iPad capture (which was a pillarboxed 1920×1080 inside a square frame).

---

## 7. The data + outputs

### Raw

```
gaze-<unix>.json
{
  "startedAtUTC": 1779923473.9039168,
  "samples": [
    {"t": 0.0,    "yaw": 0.012, "pitch": -0.034, "scene": "hello"},
    {"t": 0.017,  "yaw": 0.014, "pitch": -0.033, "scene": "hello"},
    ...
  ]
}
```

Stable filename per session, checkpointed every 3 s, finalized on `end()`.

### Pulled off the device

```
xcrun devicectl device copy from \
  --device <UDID> \
  --domain-type appDataContainer \
  --domain-identifier Aino.SageOS \
  --source Documents \
  --destination ~/Downloads/sessions_<date>
```

### Rendered

For each `(session JSON, screen recording)` pair, `tools/gaze_heatmap.py` writes a `runs/<label>/` directory containing:

- `scene_overlay.mp4` — trail + pointer dot on the recording.
- `heatmap_overlay.mp4` — rolling 8-second heatmap on the recording.
- `heatmap_timeline.mp4`, `trail_session.mp4` — standalone (no underlay) versions.
- `heatmap_<scene>.png` for each of the eleven scenes.
- `heatmap_all.png` — the full session.
- `trail_<scene>.mp4` for each scene.

---

## 8. Honest limitations

Worth stating plainly in a research case study:

1. **Head pose ≠ eye gaze.** Within a scene where the participant holds their head still and just darts their eyes, the probe registers zero motion even if attention is shifting. This is a fundamental ceiling, not a tuning issue — it follows directly from the privacy constraint that motivated the proxy in the first place.
2. **Operator timing.** Scene transitions are tagged when *I* press space, which lags the participant's actual button-press by maybe 0.5–1 s. Per-scene boundaries are therefore approximate.
3. **Sync offset is per-recording.** Reflector and the gaze session have no shared clock, so each render needs `--offset` tuned by eye. A future improvement would be to flash a synchronization marker (e.g. a black frame) at session start.
4. **FOV is empirical.** The pixel mapping depends on the captured field of view of the AirPlay shared view, which is undocumented; I tune `--fov-h` and `--fov-v` against a known visual reference per recording shape.
5. **Network discovery depends on Wi-Fi policy.** Client-isolated networks (universities, conferences) block Bonjour and same-subnet routing — solved operationally with a hotspot or travel router, not architecturally.

---

## 9. The operator runbook at the exhibition

1. Power on the AVP. Launch SageOS — it auto-starts a fallback session immediately so the demo is never blocked.
2. On the laptop, run `python3 tools/watch_and_open.py` (or scan the QR code in the operator window off the Reflector mirror) — Safari opens the control page.
3. Mirror the AVP to the laptop via Reflector; drag the Reflector window onto the audience monitor.
4. Hand the headset to the participant. If using Guest Mode (chosen-app-only — locks them to SageOS, hides everything else), they do the ~30 s eye + hand setup; their calibration is discarded after the session, but the gaze JSON persists in your app's Documents container because Guest Mode does not swap app containers.
5. On the control page, press **New Session** to start a clean recording for this participant.
6. Watch the mirror. Press **space** whenever the participant triggers a scene gate (consent, homework selection, "begin", etc.) so the right scene label is tagged on subsequent samples.
7. When the experience ends, press **End Session** — the JSON is flushed to disk.
8. For the next participant, re-arm Guest Mode if applicable (an Optic ID glance, not a typed passcode) and repeat from step 5.
9. After the day, pull the container with `devicectl device copy from`, then run `gaze_heatmap.py` against the JSONs paired with the Reflector recordings.

---

## 10. What this proved

The proxy works well enough that the heatmaps and trail overlays tell a coherent attention story per scene — which homework option the participant lingered on, where their head moved during the consent moments, what they were looking at when they decided to "Begin." The probe collected attention data on a platform that explicitly prevents direct collection of it, by reframing the question from *"where are the eyes pointing"* to *"where is the head pointing,"* and the answer turned out to be informative for an immersive experience where those two signals are strongly coupled.
