#!/usr/bin/env python3
"""Phase 0 probe for Inframy: find out what Matt's Frame TV's art-mode API actually does.

Read-only by default. Anything that changes the TV needs an explicit flag AND a typed confirmation.

Setup (from the repo root):
    python3 -m venv .venv && source .venv/bin/activate
    pip install "samsungtvws[async,cli]" pillow

Usage:
    python tools/probe.py --host 192.168.1.50                     # read-only survey
    python tools/probe.py --host 192.168.1.50 --upload-test       # upload one test image, matte "none"
    python tools/probe.py --host 192.168.1.50 --show MY_F0001     # display a content id now
    python tools/probe.py --host 192.168.1.50 --shuffle 15        # shuffle personal photos every 15 min (0 = off)
    python tools/probe.py --host 192.168.1.50 --delete MY_F0001   # delete content ids

The first run shows an Allow prompt on the TV. The token is saved to tools/.tv-token (gitignored).
Results go to tools/probe-output/<timestamp>/ (gitignored): a JSON log of every call plus thumbnails.
Copy what matters into docs/PROTOCOL.md, with tokens redacted.

Method names follow samsungtvws' art API (as in NickWaterton's fork). They vary between library versions
and TV firmware, so every call is attempted defensively and failures are recorded rather than fatal.
This script has NOT been run against a real TV or against samsungtvws 3.0.6 yet. If calls fail with
AttributeError, the installed library names things differently: check its art.py and adjust, or try
NickWaterton's fork (pip install git+https://github.com/NickWaterton/samsung-tv-ws-api.git). Note that
the PyPI release reportedly handles the Art API 0.97 upload path; the fork's art.py only does the d2d path.
"""

import argparse
import datetime as dt
import io
import json
import logging
import sys
import traceback
from pathlib import Path

PERSONAL_CATEGORY = "MY-C0002"
TOOLS_DIR = Path(__file__).resolve().parent
TOKEN_FILE = TOOLS_DIR / ".tv-token"


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe a Samsung Frame TV's art-mode API.")
    parser.add_argument("--host", required=True, help="TV IP address")
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--debug", action="store_true", help="log raw websocket traffic")
    parser.add_argument("--upload-test", action="store_true", help="upload one 3840x2160 test JPEG with matte none")
    parser.add_argument("--show", metavar="CONTENT_ID", help="select and display this content id")
    parser.add_argument("--shuffle", type=int, metavar="MINUTES", help="set shuffle on personal photos (0 = off)")
    parser.add_argument("--delete", nargs="+", metavar="CONTENT_ID", help="delete these content ids")
    parser.add_argument("--yes", action="store_true", help="skip confirmations (only if Matt said so)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.WARNING)

    try:
        from samsungtvws import SamsungTVWS
    except ImportError:
        print('samsungtvws is not installed. Run: pip install "samsungtvws[async,cli]" pillow', file=sys.stderr)
        return 1

    out_dir = TOOLS_DIR / "probe-output" / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)
    log = Log(out_dir)

    tv = SamsungTVWS(host=args.host, port=args.port, token_file=str(TOKEN_FILE),
                     timeout=args.timeout, name="Inframy")

    log.call("rest_device_info", lambda: tv.rest_device_info())
    art = tv.art()

    # ---- Read-only survey -------------------------------------------------------------------------
    log.call("art.supported", lambda: art.supported())
    log.call("art.get_api_version", lambda: art.get_api_version())
    log.call("art.get_device_info", lambda: art.get_device_info())
    log.call("art.get_artmode", lambda: art.get_artmode())
    log.call("art.get_current", lambda: art.get_current())
    personal = log.call(f"art.available({PERSONAL_CATEGORY})", lambda: art.available(PERSONAL_CATEGORY))
    log.call("art.get_matte_list(include_colour=True)", lambda: art.get_matte_list(include_colour=True))
    log.call("art.get_slideshow_status (newer firmware)", lambda: art.get_slideshow_status())
    log.call("art.get_auto_rotation_status (older firmware)", lambda: art.get_auto_rotation_status())
    log.call("art.get_artmode_settings", lambda: art.get_artmode_settings())
    log.call("art.get_photo_filter_list", lambda: art.get_photo_filter_list())

    if isinstance(personal, list):
        print(f"\nPersonal photos on the TV: {len(personal)}")
        for item in personal[:3]:
            cid = item.get("content_id") if isinstance(item, dict) else None
            if not cid:
                continue
            thumb = log.call(f"art.get_thumbnail({cid})", lambda cid=cid: art.get_thumbnail(cid), keep_result=False)
            if isinstance(thumb, (bytes, bytearray)):
                path = out_dir / f"thumb-{cid}.jpg"
                path.write_bytes(thumb)
                print(f"  saved thumbnail {path.name} ({len(thumb)} bytes)")

    # ---- Changes (opt-in) -------------------------------------------------------------------------
    if args.upload_test and confirm("Upload one test image to the TV (matte none)?", args.yes):
        jpeg = make_test_jpeg()
        cid = log.call("art.upload(test, matte=none)", lambda: upload(art, jpeg))
        if cid:
            print(f"Uploaded test image as {cid}. Use --show {cid} to display it, --delete {cid} to remove it.")
            log.call(f"art.available({PERSONAL_CATEGORY}) after upload", lambda: art.available(PERSONAL_CATEGORY))

    if args.show and confirm(f"Display {args.show} on the TV now?", args.yes):
        log.call(f"art.select_image({args.show})", lambda: art.select_image(args.show, category=PERSONAL_CATEGORY))

    if args.shuffle is not None and confirm(
            f"Set shuffle on personal photos to {args.shuffle or 'off'} (minutes)?", args.yes):
        ok = log.call("art.set_slideshow_status", lambda: art.set_slideshow_status(
            duration=args.shuffle, type=True, category=2))
        if ok is None:
            log.call("art.set_auto_rotation_status (fallback)", lambda: art.set_auto_rotation_status(
                duration=args.shuffle, type=True, category=2))

    if args.delete and confirm(f"Delete {', '.join(args.delete)} from the TV? This can't be undone.", args.yes):
        log.call(f"art.delete_list({args.delete})", lambda: art.delete_list(args.delete))

    log.close()
    print(f"\nFull log: {log.path}")
    return 0


def upload(art, jpeg: bytes):
    try:
        return art.upload(jpeg, file_type="JPEG", matte="none", portrait_matte="none")
    except TypeError:
        # Older/newer library signatures differ; retry without portrait_matte.
        return art.upload(jpeg, file_type="JPEG", matte="none")


def make_test_jpeg() -> bytes:
    from PIL import Image, ImageDraw

    w, h = 3840, 2160
    img = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(img)
    for y in range(h):  # simple vertical gradient so banding/compression is visible
        shade = int(40 + 160 * y / h)
        draw.line([(0, y), (w, y)], fill=(shade, shade // 2 + 40, 200 - shade // 2))
    draw.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255), width=12)  # edges: is anything cropped?
    stamp = f"Inframy probe {dt.datetime.now():%Y-%m-%d %H:%M}"
    try:
        draw.text((w // 2, h // 2), stamp, fill=(255, 255, 255), anchor="mm", font_size=160)
    except (TypeError, ValueError, OSError):  # older Pillow or no FreeType: small default font
        draw.text((w // 2, h // 2), stamp, fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def confirm(question: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    return input(f"{question} Type 'yes' to continue: ").strip().lower() == "yes"


class Log:
    """Records every call's result or error to calls.json, and prints a one-line summary."""

    def __init__(self, out_dir: Path):
        self.path = out_dir / "calls.json"
        self.entries = []

    def call(self, label, fn, keep_result=True):
        try:
            result = fn()
        except Exception as exc:  # noqa: BLE001 - we want every failure recorded, not raised
            self.entries.append({"call": label, "ok": False, "error": repr(exc),
                                 "traceback": traceback.format_exc()})
            print(f"✗ {label}: {exc!r}")
            self._flush()
            return None
        entry = {"call": label, "ok": True}
        if keep_result:
            entry["result"] = jsonable(result)
        elif isinstance(result, (bytes, bytearray)):
            entry["result"] = f"<{len(result)} bytes>"
        self.entries.append(entry)
        print(f"✓ {label}: {summarize(result)}")
        self._flush()
        return result

    def _flush(self):
        self.path.write_text(json.dumps(self.entries, indent=2, default=str))

    def close(self):
        self._flush()


def jsonable(value):
    if isinstance(value, (bytes, bytearray)):
        return f"<{len(value)} bytes>"
    try:
        json.dumps(value)
        return value
    except TypeError:
        return repr(value)


def summarize(value) -> str:
    if isinstance(value, (bytes, bytearray)):
        return f"<{len(value)} bytes>"
    if isinstance(value, list):
        return f"list of {len(value)}"
    text = json.dumps(jsonable(value), default=str)
    return text if len(text) <= 160 else text[:157] + "..."


if __name__ == "__main__":
    sys.exit(main())
