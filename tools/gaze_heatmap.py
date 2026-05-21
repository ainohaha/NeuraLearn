#!/usr/bin/env python3
"""
SageOS gaze heatmap generator.

Reads a gaze-*.json log written by GazeSession on Apple Vision Pro and produces:
  * heatmap_<scene>.png   per-scene aggregate attention map (yaw vs. pitch)
  * heatmap_all.png       combined aggregate across all scenes
  * heatmap_timeline.mp4  animated heatmap that accumulates over time, timecoded
  * trail_session.mp4     moving-dot + decaying-line trail across the whole
                          session (line fades over ~3s, scene boundaries clear)
  * trail_<scene>.mp4     per-scene trail clip (one file per scene span)
  * scene_overlay.mp4     (if --video supplied) trail painted DIRECTLY on
                          the headset recording via FOV-mapped pixel coords.
                          This is the "see what they saw + where they looked"
                          output you want for research write-ups.
  * heatmap_overlay.mp4   (if --video supplied) legacy picture-in-picture
                          composite — keep as fallback if scene_overlay's
                          FOV mapping needs tuning.

Note on signal: visionOS does not expose raw eye gaze to third-party apps. This
tracker samples the head-forward vector instead, which is a strong proxy for
attention on attended content (~200ms head-follow). Treat the heatmap as a
"where the viewer's head pointed" map, not a literal foveation map.

Setup:
  pip install numpy scipy matplotlib opencv-python

Usage:
  python gaze_heatmap.py gaze-1747200000.json
  python gaze_heatmap.py gaze-1747200000.json --video screen_recording.mp4 --offset 0.3
  python gaze_heatmap.py gaze-1747200000.json --out runs/test1 --fps 30
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import cm
except ImportError:
    print("matplotlib required: pip install matplotlib", file=sys.stderr)
    sys.exit(1)

try:
    from scipy.ndimage import gaussian_filter
except ImportError:
    print("scipy required: pip install scipy", file=sys.stderr)
    sys.exit(1)

try:
    import cv2
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False


def deg(rad: float) -> float:
    return rad * 180.0 / math.pi


def smooth_samples(samples, window_seconds: float):
    """Centered moving-average smoothing on yaw/pitch.

    The raw head-pose proxy at 30 Hz includes micro-jitter from breathing
    and postural sway that has no attentional meaning. A small smoothing
    window (~0.3s) removes the jitter while preserving real head movements.
    """
    if window_seconds <= 0 or len(samples) < 2:
        return samples
    samples = sorted(samples, key=lambda s: s["t"])
    times = [s["t"] for s in samples]
    yaws = [s["yaw"] for s in samples]
    pitches = [s["pitch"] for s in samples]
    n = len(samples)
    half = window_seconds / 2.0
    out = []
    lo = 0
    hi = 0
    for i in range(n):
        t = times[i]
        while lo < n and times[lo] < t - half:
            lo += 1
        while hi < n and times[hi] <= t + half:
            hi += 1
        m = max(hi - lo, 1)
        avg_yaw = sum(yaws[lo:hi]) / m
        avg_pitch = sum(pitches[lo:hi]) / m
        s = dict(samples[i])
        s["yaw"] = avg_yaw
        s["pitch"] = avg_pitch
        out.append(s)
    return out


def center_samples(samples):
    """Re-center yaw/pitch so the median of the data sits at (0, 0).

    The raw yaw=0 reference is wherever the AVP was facing when
    WorldTrackingProvider started, which is arbitrary. After centering,
    (0, 0) corresponds to "where the participant spent the most attention" —
    which, if they were watching the demo, is roughly the centre of the
    Spline scene. Important for the scene-aligned overlay, which assumes
    (0, 0) maps to the centre of the headset recording.
    """
    if not samples:
        return samples
    yaws = sorted(s["yaw"] for s in samples)
    pitches = sorted(s["pitch"] for s in samples)
    y_off = yaws[len(yaws) // 2]
    p_off = pitches[len(pitches) // 2]
    return [dict(s, yaw=s["yaw"] - y_off, pitch=s["pitch"] - p_off)
            for s in samples]


def compute_extent(samples, margin_deg=5.0, fallback=(-60.0, 60.0, -35.0, 35.0)):
    """Fit yaw/pitch extent to the data's 1–99 percentile, with padding."""
    if not samples:
        return fallback
    yaws = np.array([deg(s["yaw"]) for s in samples])
    pitches = np.array([deg(s["pitch"]) for s in samples])
    return (
        float(np.percentile(yaws, 1) - margin_deg),
        float(np.percentile(yaws, 99) + margin_deg),
        float(np.percentile(pitches, 1) - margin_deg),
        float(np.percentile(pitches, 99) + margin_deg),
    )


def histogram(samples, extent, bins=(120, 80)):
    """Return a (pitch_bins, yaw_bins) attention histogram."""
    if not samples:
        return np.zeros((bins[1], bins[0]))
    yaws = np.array([deg(s["yaw"]) for s in samples])
    pitches = np.array([deg(s["pitch"]) for s in samples])
    H, _, _ = np.histogram2d(
        yaws, pitches,
        bins=bins,
        range=[[extent[0], extent[1]], [extent[2], extent[3]]],
    )
    return H.T


def render_heatmap_png(H, extent, title, out_path, sigma=2.0):
    smoothed = gaussian_filter(H, sigma=sigma)
    if smoothed.max() > 0:
        smoothed = smoothed / smoothed.max()
    fig, ax = plt.subplots(figsize=(8, 5), dpi=140)
    im = ax.imshow(
        smoothed,
        extent=extent,
        origin="lower",
        aspect="auto",
        cmap="inferno",
        interpolation="bilinear",
    )
    ax.set_xlabel("Yaw (deg, +right)")
    ax.set_ylabel("Pitch (deg, +up)")
    ax.set_title(title)
    ax.axhline(0, color="white", alpha=0.25, lw=0.6)
    ax.axvline(0, color="white", alpha=0.25, lw=0.6)
    fig.colorbar(im, ax=ax, label="attention (normalized)")
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)


def render_timeline_video(samples, scenes, extent, out_path, fps=30, sigma=2.5,
                          width=960, height=540, bins=(120, 80)):
    if not HAS_CV2:
        print("opencv-python not installed; skipping timeline video", file=sys.stderr)
        return False
    duration = max((s["t"] for s in samples), default=0.0)
    if duration <= 0:
        print("no samples; skipping timeline video", file=sys.stderr)
        return False

    frames = int(math.ceil(duration * fps))
    H = np.zeros((bins[1], bins[0]), dtype=np.float64)

    samples_sorted = sorted(samples, key=lambda s: s["t"])
    yaw_edges = np.linspace(extent[0], extent[1], bins[0] + 1)
    pitch_edges = np.linspace(extent[2], extent[3], bins[1] + 1)

    header_h = 50
    panel_h = height - header_h

    writer = cv2.VideoWriter(
        str(out_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )

    sample_idx = 0
    for f in range(frames):
        t_now = (f + 1) / fps
        while sample_idx < len(samples_sorted) and samples_sorted[sample_idx]["t"] <= t_now:
            s = samples_sorted[sample_idx]
            y = deg(s["yaw"])
            p = deg(s["pitch"])
            yi = int(np.searchsorted(yaw_edges, y, side="right") - 1)
            pi = int(np.searchsorted(pitch_edges, p, side="right") - 1)
            if 0 <= yi < bins[0] and 0 <= pi < bins[1]:
                H[pi, yi] += 1.0
            sample_idx += 1

        smoothed = gaussian_filter(H, sigma=sigma)
        norm = smoothed / smoothed.max() if smoothed.max() > 0 else smoothed
        rgba = cm.inferno(norm)
        img = (rgba[:, :, :3] * 255).astype(np.uint8)
        img = np.flipud(img)  # pitch increases upward
        img = cv2.resize(img, (width, panel_h), interpolation=cv2.INTER_LINEAR)
        img_bgr = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)

        canvas = np.zeros((height, width, 3), dtype=np.uint8)
        canvas[header_h:, :, :] = img_bgr

        current = next(
            (sc for sc in scenes
             if sc["start"] <= t_now and (sc.get("end") if sc.get("end") is not None else 1e18) >= t_now),
            None,
        )
        scene_label = current["id"] if current else "—"
        text = f"t={t_now:6.2f}s   scene={scene_label}   samples={sample_idx}"
        cv2.putText(canvas, text, (14, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                    (255, 255, 255), 2, cv2.LINE_AA)
        # Subtle border
        cv2.rectangle(canvas, (0, header_h - 1), (width - 1, height - 1), (60, 60, 60), 1)

        writer.write(canvas)

    writer.release()
    return True


def render_trail_video(samples, extent, out_path, fps=30, trail_seconds=3.0,
                       width=960, height=540, clear_on_scene_change=True):
    """Render a moving-dot + decaying-line trail.

    The dot is the current head-pose proxy position. Behind it is a polyline
    of the last `trail_seconds` of samples whose alpha falls off with age, so
    you see motion without an ever-growing scribble. When
    `clear_on_scene_change` is True, the trail empties at each scene boundary
    so each segment reads as that scene's attention path alone.
    """
    if not HAS_CV2:
        print("opencv-python not installed; skipping trail video", file=sys.stderr)
        return False
    if not samples:
        return False

    samples_sorted = sorted(samples, key=lambda s: s["t"])
    duration = samples_sorted[-1]["t"]
    if duration <= 0:
        return False
    frames = int(math.ceil(duration * fps))

    yaw_min, yaw_max, pitch_min, pitch_max = extent

    def to_px(yaw_deg, pitch_deg):
        x = (yaw_deg - yaw_min) / max(yaw_max - yaw_min, 1e-6) * width
        # Flip y so +pitch goes up.
        y = (1 - (pitch_deg - pitch_min) / max(pitch_max - pitch_min, 1e-6)) * height
        return int(x), int(y)

    writer = cv2.VideoWriter(
        str(out_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )

    sample_idx = 0
    last_scene = None
    for f in range(frames):
        t_now = (f + 1) / fps
        while sample_idx < len(samples_sorted) and samples_sorted[sample_idx]["t"] <= t_now:
            sample_idx += 1
        if sample_idx == 0:
            writer.write(np.zeros((height, width, 3), dtype=np.uint8))
            continue

        head = samples_sorted[sample_idx - 1]
        scene_now = head["scene"]

        if clear_on_scene_change:
            trail_start_t = max(t_now - trail_seconds, _scene_start(samples_sorted, scene_now, sample_idx))
        else:
            trail_start_t = t_now - trail_seconds

        # Walk back from head to collect samples in the trail window.
        trail = []
        i = sample_idx - 1
        while i >= 0 and samples_sorted[i]["t"] >= trail_start_t:
            if clear_on_scene_change and samples_sorted[i]["scene"] != scene_now:
                break
            trail.append(samples_sorted[i])
            i -= 1
        trail.reverse()

        frame = np.zeros((height, width, 3), dtype=np.uint8)
        # Subtle border so axes are visible against passthrough backgrounds.
        cv2.rectangle(frame, (0, 0), (width - 1, height - 1), (40, 40, 40), 1)
        # Crosshair at 0,0 so reviewers can read pose absolutely.
        if yaw_min <= 0 <= yaw_max and pitch_min <= 0 <= pitch_max:
            cx, cy = to_px(0, 0)
            cv2.line(frame, (cx, 0), (cx, height), (50, 50, 50), 1)
            cv2.line(frame, (0, cy), (width, cy), (50, 50, 50), 1)

        for j in range(1, len(trail)):
            a_yaw = deg(trail[j - 1]["yaw"])
            a_pitch = deg(trail[j - 1]["pitch"])
            b_yaw = deg(trail[j]["yaw"])
            b_pitch = deg(trail[j]["pitch"])
            age = max(t_now - trail[j]["t"], 0.0)
            alpha = max(1.0 - age / trail_seconds, 0.0)
            color = (int(255 * alpha), int(220 * alpha), int(40 * alpha))  # BGR
            cv2.line(frame, to_px(a_yaw, a_pitch), to_px(b_yaw, b_pitch),
                     color, 2, cv2.LINE_AA)

        # Current dot.
        hx, hy = to_px(deg(head["yaw"]), deg(head["pitch"]))
        cv2.circle(frame, (hx, hy), 7, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(frame, (hx, hy), 9, (40, 220, 255), 1, cv2.LINE_AA)

        label = f"t={t_now:6.2f}s   scene={scene_now}"
        cv2.putText(frame, label, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.65,
                    (240, 240, 240), 1, cv2.LINE_AA)

        if scene_now != last_scene:
            last_scene = scene_now

        writer.write(frame)

    writer.release()
    return True


def _scene_start(samples_sorted, scene, idx_hint):
    """Find t of the first sample of the current scene span ending at idx_hint."""
    i = idx_hint - 1
    while i > 0 and samples_sorted[i - 1]["scene"] == scene:
        i -= 1
    return samples_sorted[i]["t"]


def render_scene_overlay(samples, video_path, out_path, offset=0.0,
                         fov_h=90.0, fov_v=55.0, trail_seconds=3.0,
                         dot_radius=9):
    """Paint the gaze trail directly onto each frame of the headset recording.

    yaw/pitch are mapped to recording pixels assuming the centre of the
    recording corresponds to yaw=0/pitch=0 (i.e. samples were centred first)
    and the recording covers `fov_h` × `fov_v` degrees of view. Use
    --fov-h / --fov-v on the CLI to tune if the trail seems off.

    `offset` = seconds the gaze log starts AFTER the recording starts.
    If you hit record on Reflector first and THEN clicked "Start new
    session", offset is positive (~1s).
    """
    if not HAS_CV2:
        print("opencv-python not installed; skipping scene overlay", file=sys.stderr)
        return False
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"could not open {video_path}", file=sys.stderr)
        return False

    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    writer = cv2.VideoWriter(
        str(out_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (W, H),
    )

    samples_sorted = sorted(samples, key=lambda s: s["t"])
    px_per_deg_x = W / fov_h
    px_per_deg_y = H / fov_v

    def to_px(yaw_rad: float, pitch_rad: float):
        x = W / 2.0 + deg(yaw_rad) * px_per_deg_x
        # pitch +up → y goes up → screen y decreases
        y = H / 2.0 - deg(pitch_rad) * px_per_deg_y
        return int(x), int(y)

    frame_idx = 0
    sample_idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t_recording = frame_idx / fps
        t_gaze = t_recording - offset

        # Advance sample_idx to the latest sample at or before t_gaze.
        while (sample_idx < len(samples_sorted)
               and samples_sorted[sample_idx]["t"] <= t_gaze):
            sample_idx += 1

        if sample_idx == 0 or t_gaze < 0:
            # Before the gaze log starts — write the frame untouched.
            writer.write(frame)
            frame_idx += 1
            continue

        head = samples_sorted[sample_idx - 1]
        scene_now = head["scene"]

        # Trail: walk back collecting samples within window, stop at scene change.
        trail = []
        i = sample_idx - 1
        cutoff = t_gaze - trail_seconds
        while i >= 0 and samples_sorted[i]["t"] >= cutoff:
            if samples_sorted[i]["scene"] != scene_now:
                break
            trail.append(samples_sorted[i])
            i -= 1
        trail.reverse()

        # Fading polyline.
        for j in range(1, len(trail)):
            age = max(t_gaze - trail[j]["t"], 0.0)
            alpha = max(1.0 - age / trail_seconds, 0.0)
            color = (int(60 + 195 * alpha),
                     int(220 * alpha),
                     int(40 * alpha))  # BGR — cyan-yellow gradient
            cv2.line(frame,
                     to_px(trail[j - 1]["yaw"], trail[j - 1]["pitch"]),
                     to_px(trail[j]["yaw"], trail[j]["pitch"]),
                     color, 3, cv2.LINE_AA)

        # Current dot — white core + cyan ring.
        hx, hy = to_px(head["yaw"], head["pitch"])
        cv2.circle(frame, (hx, hy), dot_radius + 3, (0, 0, 0), -1, cv2.LINE_AA)
        cv2.circle(frame, (hx, hy), dot_radius, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(frame, (hx, hy), dot_radius + 3, (50, 220, 255), 2, cv2.LINE_AA)

        # Caption: scene + time.
        label = f"{scene_now}    t={t_gaze:5.1f}s"
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
        cv2.rectangle(frame, (16, 16), (24 + tw, 30 + th), (0, 0, 0), -1)
        cv2.putText(frame, label, (20, 26 + th),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (240, 240, 240), 2, cv2.LINE_AA)

        writer.write(frame)
        frame_idx += 1

    cap.release()
    writer.release()
    return True


def render_heatmap_video_overlay(samples, video_path, out_path, offset=0.0,
                                 fov_h=90.0, fov_v=90.0, sigma=2.5,
                                 window_seconds=8.0, bins_x=192, bins_y=192,
                                 alpha=0.55, threshold=0.10):
    """Paint a heatmap directly onto each frame of the headset recording.

    For every frame at time t (in recording coords, t_gaze = t - offset),
    aggregate samples whose t lies in `[t_gaze - window_seconds, t_gaze]`
    into a 2D histogram in pixel space, Gaussian-blur it, normalize, then
    alpha-blend the colormapped heat over the frame. A rolling window
    (default 8s) means the heat reflects where the participant is looking
    *now* rather than accumulating forever — much more responsive than the
    fully-accumulating timeline panel.

    Set `window_seconds=0` for full accumulation from t=0.
    """
    if not HAS_CV2:
        print("opencv-python not installed; skipping heatmap overlay", file=sys.stderr)
        return False
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"could not open {video_path}", file=sys.stderr)
        return False

    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    writer = cv2.VideoWriter(
        str(out_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (W, H),
    )

    samples_sorted = sorted(samples, key=lambda s: s["t"])
    px_per_deg_x = W / fov_h
    px_per_deg_y = H / fov_v

    # Histogram works in a downsampled grid for speed, then we resize up
    # before blending. bins_y/bins_x of ~192 gives smooth heat without
    # being prohibitively slow.
    def bin_for(yaw_rad, pitch_rad):
        # Sample → pixel → bin
        x = W / 2.0 + deg(yaw_rad) * px_per_deg_x
        y = H / 2.0 - deg(pitch_rad) * px_per_deg_y
        bx = int(x / W * bins_x)
        by = int(y / H * bins_y)
        if 0 <= bx < bins_x and 0 <= by < bins_y:
            return bx, by
        return None

    # Running window via two indices: lo (oldest in window), hi (newest in window).
    # Increment when sample enters window, decrement when it leaves.
    H_grid = np.zeros((bins_y, bins_x), dtype=np.float32)
    lo = 0
    hi = 0
    n = len(samples_sorted)

    def add(idx):
        b = bin_for(samples_sorted[idx]["yaw"], samples_sorted[idx]["pitch"])
        if b is not None:
            H_grid[b[1], b[0]] += 1.0

    def sub(idx):
        b = bin_for(samples_sorted[idx]["yaw"], samples_sorted[idx]["pitch"])
        if b is not None:
            H_grid[b[1], b[0]] -= 1.0

    frame_idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t_recording = frame_idx / fps
        t_gaze = t_recording - offset

        # Slide window: include samples up to t_gaze, drop samples older
        # than t_gaze - window_seconds (when window > 0).
        while hi < n and samples_sorted[hi]["t"] <= t_gaze:
            add(hi)
            hi += 1
        if window_seconds > 0:
            cutoff = t_gaze - window_seconds
            while lo < hi and samples_sorted[lo]["t"] < cutoff:
                sub(lo)
                lo += 1

        if t_gaze < 0 or hi == 0:
            writer.write(frame)
            frame_idx += 1
            continue

        # Blur + normalize the rolling histogram.
        smoothed = gaussian_filter(H_grid, sigma=sigma)
        m = smoothed.max()
        if m <= 0:
            writer.write(frame)
            frame_idx += 1
            continue
        norm = smoothed / m

        # Colormap → BGR uint8 image at frame resolution.
        rgba = cm.inferno(norm)
        heat_rgb = (rgba[:, :, :3] * 255).astype(np.uint8)
        heat_bgr = cv2.cvtColor(heat_rgb, cv2.COLOR_RGB2BGR)
        heat_full = cv2.resize(heat_bgr, (W, H), interpolation=cv2.INTER_LINEAR)

        # Alpha mask: zero where cold, opaque where hot, smooth ramp in between.
        # Threshold cuts noise floor so the recording stays visible in cold areas.
        mask = np.clip((norm - threshold) / max(1.0 - threshold, 1e-6), 0.0, 1.0)
        mask = mask ** 0.7  # gentle gamma to widen mid-tones
        mask_full = cv2.resize(mask.astype(np.float32), (W, H),
                               interpolation=cv2.INTER_LINEAR)
        alpha_full = (mask_full * alpha)[:, :, None]
        blended = frame.astype(np.float32) * (1 - alpha_full) + heat_full.astype(np.float32) * alpha_full
        frame = np.clip(blended, 0, 255).astype(np.uint8)

        # Caption.
        label = f"{samples_sorted[hi - 1]['scene']}    t={t_gaze:5.1f}s"
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
        cv2.rectangle(frame, (16, 16), (24 + tw, 30 + th), (0, 0, 0), -1)
        cv2.putText(frame, label, (20, 26 + th),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (240, 240, 240), 2, cv2.LINE_AA)

        writer.write(frame)
        frame_idx += 1

    cap.release()
    writer.release()
    return True


def composite_overlay(video_path, panel_path, out_path, offset=0.0, scale=0.33,
                      margin=20):
    if not HAS_CV2:
        print("opencv-python not installed; skipping overlay", file=sys.stderr)
        return False
    cap = cv2.VideoCapture(str(video_path))
    panel = cv2.VideoCapture(str(panel_path))
    if not cap.isOpened():
        print(f"could not open {video_path}", file=sys.stderr)
        return False
    if not panel.isOpened():
        print(f"could not open {panel_path}", file=sys.stderr)
        return False

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"),
                             fps, (W, H))
    pw = int(W * scale)
    ph = int(H * scale)
    offset_frames = int(offset * fps)
    panel_frame = None
    frame_idx = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if frame_idx >= offset_frames:
            ok2, p = panel.read()
            if ok2:
                panel_frame = p
        if panel_frame is not None:
            p_resized = cv2.resize(panel_frame, (pw, ph))
            x0 = W - pw - margin
            y0 = H - ph - margin
            frame[y0:y0 + ph, x0:x0 + pw] = p_resized
            cv2.rectangle(frame, (x0 - 1, y0 - 1), (x0 + pw, y0 + ph),
                          (255, 255, 255), 1)
        writer.write(frame)
        frame_idx += 1

    cap.release()
    panel.release()
    writer.release()
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("json", help="path to gaze-*.json log")
    ap.add_argument("--video", help="screen recording to composite heatmap onto")
    ap.add_argument("--offset", type=float, default=0.0,
                    help="seconds gaze log starts AFTER the screen recording starts")
    ap.add_argument("--out", default="gaze_out", help="output directory")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--sigma", type=float, default=2.5, help="Gaussian blur sigma for heatmap")
    ap.add_argument("--trail-seconds", type=float, default=3.0,
                    help="seconds of trail history shown in trail_*.mp4 (default 3.0)")
    ap.add_argument("--trail-no-clear", action="store_true",
                    help="keep trail continuous across scene boundaries instead of clearing")
    ap.add_argument("--smooth-seconds", type=float, default=0.3,
                    help="centered moving-average window applied to yaw/pitch "
                         "to remove micro-jitter (default 0.3s, 0 to disable)")
    ap.add_argument("--no-center", action="store_true",
                    help="don't re-center yaw/pitch on the data median; use raw "
                         "values as recorded (default: center so 0,0 is the "
                         "attention centroid)")
    ap.add_argument("--fov-h", type=float, default=90.0,
                    help="horizontal FOV of the headset recording in degrees "
                         "(default 90 — tune if the trail overshoots/undershoots)")
    ap.add_argument("--fov-v", type=float, default=55.0,
                    help="vertical FOV of the headset recording in degrees "
                         "(default 55)")
    ap.add_argument("--heatmap-window", type=float, default=8.0,
                    help="rolling window in seconds for heatmap_overlay.mp4 — "
                         "heat reflects only the last N seconds of samples, "
                         "so old attention fades. Set 0 for full accumulation "
                         "(default 8s)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    with open(args.json) as f:
        log = json.load(f)
    samples = log.get("samples", [])
    scenes = log.get("scenes", [])

    if not samples:
        print("no samples in log; nothing to do", file=sys.stderr)
        sys.exit(1)

    duration = log.get("durationSeconds", samples[-1]["t"] if samples else 0)
    print(f"loaded {len(samples)} samples across {len(scenes)} scene span(s), duration={duration:.1f}s")

    # Apply smoothing then centering, so every downstream output (heatmaps,
    # trail videos, scene overlay) uses cleaner data.
    if args.smooth_seconds > 0:
        samples = smooth_samples(samples, args.smooth_seconds)
        print(f"smoothed with {args.smooth_seconds}s moving average")
    if not args.no_center:
        samples = center_samples(samples)
        print("re-centered yaw/pitch on data median")

    extent = compute_extent(samples)
    print(f"heatmap extent (deg): yaw [{extent[0]:.1f}, {extent[1]:.1f}], pitch [{extent[2]:.1f}, {extent[3]:.1f}]")

    by_scene: dict[str, list] = {}
    for s in samples:
        by_scene.setdefault(s["scene"], []).append(s)

    for scene_id, scene_samples in by_scene.items():
        png = out / f"heatmap_{scene_id}.png"
        render_heatmap_png(
            histogram(scene_samples, extent),
            extent,
            f"Scene: {scene_id}  (n={len(scene_samples)})",
            png,
            sigma=args.sigma,
        )
        print(f"  wrote {png}")

    all_png = out / "heatmap_all.png"
    render_heatmap_png(
        histogram(samples, extent),
        extent,
        f"All scenes (n={len(samples)})",
        all_png,
        sigma=args.sigma,
    )
    print(f"  wrote {all_png}")

    timeline_path = out / "heatmap_timeline.mp4"
    if render_timeline_video(samples, scenes, extent, timeline_path, fps=args.fps, sigma=args.sigma):
        print(f"  wrote {timeline_path}")

    trail_path = out / "trail_session.mp4"
    if render_trail_video(samples, extent, trail_path, fps=args.fps,
                          trail_seconds=args.trail_seconds,
                          clear_on_scene_change=not args.trail_no_clear):
        print(f"  wrote {trail_path}")

    # Per-scene trail clips: clip the global sample stream to each span so the
    # researcher can review one scene at a time without slicing the JSON.
    for scene_id, scene_samples in by_scene.items():
        if len(scene_samples) < 2:
            continue
        # Renormalize t to start at 0 within the clip so trail decay reads correctly.
        t0 = scene_samples[0]["t"]
        clip = [dict(s, t=s["t"] - t0) for s in scene_samples]
        scene_extent = compute_extent(clip)
        clip_path = out / f"trail_{scene_id}.mp4"
        if render_trail_video(clip, scene_extent, clip_path, fps=args.fps,
                              trail_seconds=args.trail_seconds,
                              clear_on_scene_change=False):
            print(f"  wrote {clip_path}")

    if args.video:
        # 1) Trail + dot painted directly on the recorded headset view.
        scene_overlay_path = out / "scene_overlay.mp4"
        if render_scene_overlay(samples, args.video, scene_overlay_path,
                                offset=args.offset,
                                fov_h=args.fov_h, fov_v=args.fov_v,
                                trail_seconds=args.trail_seconds):
            print(f"  wrote {scene_overlay_path}")
        # 2) Heatmap painted directly on the recorded headset view, using
        # a rolling window so heat reflects current attention, not 0-to-now.
        heatmap_overlay_path = out / "heatmap_overlay.mp4"
        if render_heatmap_video_overlay(samples, args.video, heatmap_overlay_path,
                                        offset=args.offset,
                                        fov_h=args.fov_h, fov_v=args.fov_v,
                                        sigma=args.sigma,
                                        window_seconds=args.heatmap_window):
            print(f"  wrote {heatmap_overlay_path}")


if __name__ == "__main__":
    main()
