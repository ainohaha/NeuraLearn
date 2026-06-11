#!/usr/bin/env python3
"""
Generate a printable QR code for the NeuraLearn AR web page.

Usage:
  python3 tools/gen_qr.py https://ainohaha.github.io/SageOS/web/

The script writes ./web/qr.png (a ~1000px QR) next to the page itself, so
you can print it on a card at the exhibition. Defaults to a guess of the
GitHub Pages URL if you don't pass one.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

DEFAULT_URL = "https://ainohaha.github.io/SageOS/web/"
OUT = Path(__file__).resolve().parent.parent / "web" / "qr.png"


def ensure_qrcode_installed() -> None:
    try:
        import qrcode  # noqa: F401
    except ImportError:
        print("Installing qrcode[pil] (one-time)…", file=sys.stderr)
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--quiet", "qrcode[pil]"]
        )


def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    ensure_qrcode_installed()

    import qrcode
    from qrcode.constants import ERROR_CORRECT_H

    # High error correction so the code still scans through a tiny crop or
    # a glossy print. box_size=20 gives us a ~1000px PNG at the default
    # version-auto sizing — large enough to read from across a room.
    qr = qrcode.QRCode(
        version=None,
        error_correction=ERROR_CORRECT_H,
        box_size=20,
        border=4,
    )
    qr.add_data(url)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    size = os.path.getsize(OUT)
    print(f"wrote {OUT}  ({size:,} bytes)")
    print(f"encodes: {url}")


if __name__ == "__main__":
    main()
