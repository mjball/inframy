#!/usr/bin/env python3
"""Phase 0 probe for Inframy: find out what Matt's Frame TV's art-mode API actually does.

Read-only by default. Anything that changes the TV needs an explicit flag AND a typed confirmation.

Setup (from the repo root):
    python3 -m venv .venv && source .venv/bin/activate
    pip install "samsungtvws[async,cli]" pillow

Usage:
    python tools/probe.py                                         # discover the Frame (Bonjour/SSDP), then survey
    python tools/probe.py --discover-only                         # just find Frame TVs on the network
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
    parser.add_argument("--host", help="TV IP address (default: discover via Bonjour/SSDP)")
    parser.add_argument("--discover-only", action="store_true", help="list Frame TVs found on the network and exit")
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

    if args.discover_only or not args.host:
        frames = discover_frames()
        for f in frames:
            print(f"Found Frame TV: {f['ip']}  name={f['name']!r}  model={f['model']}  id={f['id']}  wifiMac={f['mac']}")
        if args.discover_only:
            return 0 if frames else 1
        if len(frames) != 1:
            print(f"Expected exactly one Frame TV, found {len(frames)}. Pass --host.", file=sys.stderr)
            return 1
        args.host = frames[0]["ip"]

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
    log.call("art.get_matte_list", lambda: art.get_matte_list())
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
        saved = out_dir / "test-upload.jpg"
        saved.write_bytes(jpeg)  # keep exactly what we sent, for comparing with what the TV shows
        cid = log.call("art.upload(test, matte=none)", lambda: upload(art, jpeg))
        if cid:
            saved.rename(out_dir / f"test-upload-{cid}.jpg")
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


SSDP_TARGETS = (
    "urn:samsung.com:device:RemoteControlReceiver:1",
    "urn:dial-multiscreen-org:service:dial:1",
)


def discover_frames() -> list[dict]:
    """Find Frame TVs: Bonjour (_samsungmsf._tcp) first, SSDP as a fallback; keep FrameTVSupport=true.

    Matt's TV stops answering SSDP when its gateway is set to its own IP (no-internet setup),
    but keeps advertising over Bonjour. Read-only.
    """
    ips = bonjour_samsung_ips() or ssdp_samsung_ips()
    return [f for ip in sorted(ips) if (f := frame_info(ip))]


def bonjour_samsung_ips(wait: float = 3.0) -> set[str]:
    """Browse _samsungmsf._tcp with macOS dns-sd and read the REST URL from each TXT record (se=...)."""
    import re
    import subprocess

    def run(args):
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=wait).stdout
        except subprocess.TimeoutExpired as exc:  # dns-sd never exits on its own
            return exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        except FileNotFoundError:
            return ""

    names = set(re.findall(r"_samsungmsf\._tcp\.\s+(\S.*?)\s*$", run(["dns-sd", "-B", "_samsungmsf._tcp", "local."]), re.M))
    ips = set()
    for name in names:
        txt = run(["dns-sd", "-L", name, "_samsungmsf._tcp", "local."])
        ips.update(re.findall(r"se=https?://([\d.]+):", txt))
    return ips


def ssdp_samsung_ips(wait: float = 4.0) -> set[str]:
    import socket
    import time

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    for st in SSDP_TARGETS:
        msg = (f"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
               f"MX: 2\r\nST: {st}\r\n\r\n").encode()
        sock.sendto(msg, ("239.255.255.250", 1900))
    responders: set[str] = set()
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        try:
            data, (ip, _) = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if b"samsung" in data.lower() or b"dial" in data.lower():
            responders.add(ip)
    sock.close()
    return responders


def frame_info(ip: str) -> dict | None:
    import urllib.request

    try:
        with urllib.request.urlopen(f"http://{ip}:8001/api/v2/", timeout=3) as resp:
            info = json.load(resp)
    except Exception as exc:  # noqa: BLE001
        print(f"  {ip}: REST info failed: {exc!r}")
        return None
    dev = info.get("device", {})
    if str(dev.get("FrameTVSupport", "")).lower() != "true":
        print(f"  {ip}: Samsung device, not a Frame ({dev.get('modelName')})")
        return None
    return {"ip": ip, "name": dev.get("name"), "model": dev.get("modelName"),
            "id": dev.get("id") or info.get("id"), "mac": dev.get("wifiMac")}


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
    # Cropping check: a colored triangle in each corner. Don't draw a border: on the TV it looks exactly like a mat.
    s = 200
    draw.polygon([(0, 0), (s, 0), (0, s)], fill=(230, 40, 40))                  # top-left: red
    draw.polygon([(w - 1, 0), (w - 1 - s, 0), (w - 1, s)], fill=(40, 200, 60))  # top-right: green
    draw.polygon([(0, h - 1), (s, h - 1), (0, h - 1 - s)], fill=(240, 210, 40))  # bottom-left: yellow
    draw.polygon([(w - 1, h - 1), (w - 1 - s, h - 1), (w - 1, h - 1 - s)], fill=(40, 200, 220))  # bottom-right: cyan
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
