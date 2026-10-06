#!/usr/bin/env python3
"""Convert cmcc-iptv-export.py channels.json into an HTTP-proxied CMCC IPTV M3U.

Only catalog multicast tuples and downloaded logo filenames are copied. Operator
URLs, credentials, and arbitrary replay URLs are never passed through.
"""

import argparse
import ipaddress
import json
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import quote, urlsplit


CHANNEL_CODE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
MULTICAST_URL = re.compile(r"(?:rtp|udp)://([0-9.]+):([0-9]{1,5})\Z", re.IGNORECASE)
LOGO_FILE = re.compile(r"logos/([A-Za-z0-9_-]+\.(?:png|jpg|gif|webp))\Z")
REPLAY_BASE = "http://183.235.162.80:6610/190000002005/"
REPLAY_SUFFIX = "/index.m3u8?starttime={starttime}&endtime={endtime}"
START = "${(b)yyyyMMddHHmmss}"
END = "${(e)yyyyMMddHHmmss}"


class PlaylistError(Exception):
    """Invalid catalog, URL setting, or output location."""


def public_url(value, name, *, base=False, proxy=False):
    """Reject malformed or credential-bearing URLs before embedding them in M3U."""
    if not isinstance(value, str) or any(ord(c) <= 32 or ord(c) == 127 for c in value):
        raise PlaylistError(f"{name} must be an HTTP(S) URL without spaces or control characters")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.port == 0 or parsed.query or parsed.fragment):
            raise ValueError("invalid URL parts")
    except ValueError as exc:
        raise PlaylistError(f"{name} must be an HTTP(S) URL without credentials, query, or fragment") from exc
    if proxy and not parsed.path.rstrip("/").endswith("/udp"):
        raise PlaylistError(f"{name} must end in /udp")
    if base and not value.endswith("/"):
        value += "/"
    return value


def multicast_tuple(value):
    """Return the original IPv4 group:port only for a bare multicast URL."""
    if not isinstance(value, str):
        return None
    match = MULTICAST_URL.fullmatch(value)
    if match is None:
        return None
    group, port = match.groups()
    try:
        if not ipaddress.IPv4Address(group).is_multicast or not 1 <= int(port) <= 65535:
            return None
    except ValueError:
        return None
    return group + ":" + port


def replay_source(channel):
    """Recognize only the credential-free template built by cmcc-iptv-export.py."""
    if str(channel.get("lookbackAvailable", "")).lower() != "true":
        return None
    params = channel.get("params")
    if not isinstance(params, dict):
        return None
    ztecode = params.get("ztecode")
    if not isinstance(ztecode, str) or not CHANNEL_CODE.fullmatch(ztecode):
        return None
    expected = REPLAY_BASE + ztecode + REPLAY_SUFFIX
    if channel.get("replay_url_template") != expected:
        return None
    return expected.replace("{starttime}", START).replace("{endtime}", END)


def clean_text(value):
    return "".join(" " if ord(c) < 32 or ord(c) == 127 or c in "\u2028\u2029"
                   else c for c in value).strip()


def m3u_attr(value):
    return clean_text(value).replace('"', "&quot;")


def render(channels, guide_url, logo_base_url, proxy_base, include_catchup):
    if not isinstance(channels, list):
        raise PlaylistError("channels.json has no channels array")
    lines = [f'#EXTM3U x-tvg-url="{m3u_attr(guide_url)}"']
    seen = set()
    skipped = 0
    for channel in channels:
        if not isinstance(channel, dict):
            skipped += 1
            continue
        code, title = channel.get("code"), channel.get("title")
        params = channel.get("params")
        if (not isinstance(code, str) or not CHANNEL_CODE.fullmatch(code)
                or code in seen or not isinstance(title, str) or not clean_text(title)
                or not isinstance(params, dict)):
            skipped += 1
            continue
        seen.add(code)
        live = multicast_tuple(params.get("hwurl")) or multicast_tuple(params.get("zteurl"))
        if live is None:
            skipped += 1
            continue
        title = clean_text(title)
        attrs = [f'tvg-id="{m3u_attr(code)}"', f'tvg-name="{m3u_attr(title)}"']
        logo_file = channel.get("logo_file")
        logo = LOGO_FILE.fullmatch(logo_file) if isinstance(logo_file, str) else None
        if logo:
            attrs.append(f'tvg-logo="{m3u_attr(logo_base_url + quote(logo.group(1), safe=""))}"')
        if include_catchup:
            source = replay_source(channel)
            if source:
                attrs.extend(('catchup="default"', f'catchup-source="{m3u_attr(source)}"'))
        attrs.append('group-title="CMCC IPTV"')
        lines.extend((f'#EXTINF:-1 {" ".join(attrs)},{title}', f'{proxy_base}/{live}'))
    count = (len(lines) - 1) // 2
    if not count:
        raise PlaylistError("no usable IPv4 multicast channels in channels.json")
    return ("\n".join(lines) + "\n").encode("utf-8"), count, skipped


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".part")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channels", type=Path, default=Path("cmcc-iptv-export/channels.json"),
                        help="input from cmcc-iptv-export.py (default: ./cmcc-iptv-export/channels.json)")
    parser.add_argument("--out", type=Path, default=Path("cmcc-iptv-export/cmcc.m3u"),
                        help="generated playlist (default: ./cmcc-iptv-export/cmcc.m3u)")
    parser.add_argument("--guide-url", default="http://192.168.2.253:6780/iptv/guide.xml",
                        help="public XMLTV URL advertised in the M3U header")
    parser.add_argument("--logo-base-url", default="http://192.168.2.253:6780/iptv/logos/",
                        help="public URL of the exported logos/ directory")
    parser.add_argument("--proxy-base", default="http://192.168.2.1:4023/udp",
                        help="CMCC rtp2httpd HTTP /udp endpoint (not the Telecom 4022 instance)")
    parser.add_argument("--catchup", action="store_true",
                        help="include credential-free HLS catchup metadata where exported and valid")
    args = parser.parse_args(argv)
    try:
        if args.out.resolve() == args.channels.resolve():
            raise PlaylistError("--out must differ from --channels")
        guide_url = public_url(args.guide_url, "--guide-url")
        logo_base_url = public_url(args.logo_base_url, "--logo-base-url", base=True)
        proxy_base = public_url(args.proxy_base, "--proxy-base", proxy=True).rstrip("/")
        with args.channels.open(encoding="utf-8") as source:
            catalog = json.load(source)
        if not isinstance(catalog, dict):
            raise PlaylistError("channels.json must contain an object")
        content, count, skipped = render(catalog.get("channels"), guide_url, logo_base_url,
                                          proxy_base, args.catchup)
        atomic_write(args.out, content)
        print(f"{args.out}: {count} CMCC live channels; {skipped} skipped")
        return 0
    except (OSError, UnicodeError, ValueError, PlaylistError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
