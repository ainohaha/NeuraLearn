# NeuraLearn — Phone AR demo

A web page that shows the back-camera feed with the interactive Spline scene
composited on top — works on any modern iPhone or Android without an app
install. Visitors scan a QR code to open it.

## Files

- **`index.html`** — the AR page. Full-screen camera + Spline scene.
- **`qr.png`** — printable QR pointing at the deployed URL.

## Deploy (GitHub Pages, ~2 min)

The repo is already on GitHub. To make this page reachable from a phone:

1. Push: `git add web tools/gen_qr.py && git commit -m "web: phone AR demo" && git push`
2. On GitHub: **Settings → Pages → Build and deployment**
   - Source: **Deploy from a branch**
   - Branch: **main**, folder: **/ (root)**
3. Wait ~1 min for the first build to finish.
4. Page lives at: **https://ainohaha.github.io/SageOS/web/**

Re-generate the QR if the URL ends up different:
```
python3 tools/gen_qr.py https://<your-actual-url>/
```

## Spline URL — IMPORTANT

The `<spline-viewer>` element in `index.html` points at the *web* export of
your scene:

```
https://prod.spline.design/GHUXNEykQsZGOnNwvOlk/scene.splinecode
```

I derived this from your visionOS URL by swapping `build.spline.design` →
`prod.spline.design` and `.splineswift` → `.splinecode`. If Spline gave you
a different export URL for the web/JS runtime, paste it in.

To get the official one: open the scene in Spline → **Export → Code Export
→ React / Web**. The URL it generates is what `<spline-viewer>` wants.

## Transparent background — IMPORTANT

For the camera feed to be visible behind the Spline scene, the scene's
background must be transparent in Spline:

1. Open the scene in Spline.
2. Right panel → **Scene** → **Background** → set to **None** (or alpha 0).
3. Re-publish. Same URL, transparent backdrop.

Without this, you'll just see the Spline background and no camera.

## Phone caveats

- **iOS Safari ≥ 15** and **Android Chrome** are the targets. Older
  browsers may fall through to the "Camera unavailable" toast.
- HTTPS is required for `getUserMedia` — GitHub Pages serves over HTTPS by
  default, so you're fine.
- The user has to **tap Start** before the camera turns on — browsers
  refuse otherwise.
- This is **not** true 3D-tracked AR. The Spline scene is composited over
  the camera image but doesn't anchor to the world. For the NeuraLearn
  demo flow that's plenty — the scene fills the frame and the visitor
  interacts with it.
