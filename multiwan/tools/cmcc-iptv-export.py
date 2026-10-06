#!/usr/bin/env python3
"""Export CMCC IPTV's HTTP channel catalog, EPG, and logos via router SSH.

Requires Python 3 locally and SSH access to a router with curl. No packet capture,
STB credentials, router routing changes, or third-party Python packages are needed.
"""

import argparse
import ipaddress
import json
import re
import shlex
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote, urlsplit
from xml.etree import ElementTree as ET
from zoneinfo import ZoneInfo


TIME_ZONE = ZoneInfo("Asia/Shanghai")
CATALOG_URL = "http://183.235.16.92:8082/epg/api/custom/getAllChannel2.json"
EPG_BASE = "http://183.235.16.92:8082/epg/api/channel/"
REPLAY_BASE = "http://183.235.162.80:6610/190000002005/"
CHANNEL_CODE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


class ExportError(Exception):
    """An actionable router, API, or export failure."""


def atomic_bytes(path, data):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".part")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_json(path, data):
    atomic_bytes(path, (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def ssh_command(host, remote_script):
    # OpenSSH sends a single string to the remote shell. Quote its entire script,
    # and quote URL arguments independently when constructing that script.
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "--", host, "sh -c " + shlex.quote(remote_script)]


def router_get(host, url):
    script = ("curl -fsS --connect-timeout 8 --max-time 30 --max-filesize 8388608 -- "
              + shlex.quote(url))
    try:
        result = subprocess.run(ssh_command(host, script), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=42, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ExportError(f"router curl {url}: {exc}") from exc
    if result.returncode:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise ExportError(f"router curl {url} (SSH exit {result.returncode}): {message}")
    return result.stdout


def router_json(host, url):
    try:
        result = json.loads(router_get(host, url))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExportError(f"invalid JSON at {url}: {exc}") from exc
    if not isinstance(result, dict):
        raise ExportError(f"expected JSON object at {url}")
    if str(result.get("status")) != "200":
        raise ExportError(f"API status at {url}: {result.get('status')!r} (expected '200')")
    return result


def image_extension(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return ".webp"
    raise ExportError("logo response is not a PNG, JPEG, GIF, or WebP image")


def logo_url_accepted(url):
    if not isinstance(url, str) or not url:
        return False
    try:
        parsed = urlsplit(url)
        return (parsed.scheme == "http" and parsed.hostname == "183.235.16.92"
                and parsed.port == 8081 and not parsed.username and not parsed.password)
    except ValueError:
        return False


def m3u_attr(value):
    return str(value).replace("\r", " ").replace("\n", " ").replace("\x00", "").replace('"', "&quot;")


def m3u_title(value):
    return str(value).replace("\r", " ").replace("\n", " ").replace("\x00", "")


def xml_text(value):
    # ElementTree escapes markup; XML 1.0 additionally disallows control chars.
    return "".join(c for c in value if c in "\t\n\r" or
                   0x20 <= ord(c) <= 0xD7FF or 0xE000 <= ord(c) <= 0xFFFD or
                   0x10000 <= ord(c) <= 0x10FFFF)


def multicast_url(value):
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
        return (parsed.scheme in ("rtp", "udp") and parsed.port is not None
                and ipaddress.ip_address(parsed.hostname).is_multicast)
    except (ValueError, TypeError):
        return False


def parse_schedule(program):
    if not isinstance(program, dict) or not isinstance(program.get("title"), str):
        raise ValueError("missing program title")
    start_text, end_text = program.get("starttime"), program.get("endtime")
    if not (isinstance(start_text, str) and isinstance(end_text, str)
            and re.fullmatch(r"[0-9]{14}", start_text)
            and re.fullmatch(r"[0-9]{14}", end_text)):
        raise ValueError("invalid starttime/endtime (expected YYYYMMDDHHMMSS)")
    try:
        start = datetime.strptime(start_text, "%Y%m%d%H%M%S").replace(tzinfo=TIME_ZONE)
        end = datetime.strptime(end_text, "%Y%m%d%H%M%S").replace(tzinfo=TIME_ZONE)
    except ValueError as exc:
        raise ValueError(f"invalid program time: {exc}") from exc
    if end <= start:
        raise ValueError("endtime does not follow starttime")
    return start, end


def fetch_channel(host, index, channel, date, output):
    code = channel["code"]
    epg = None
    errors = []
    try:
        url = EPG_BASE + quote(code, safe="") + ".json?begintime=" + date
        epg = router_json(host, url)
        if not isinstance(epg.get("schedules"), list):
            raise ExportError(f"EPG has no schedules array at {url}")
    except ExportError as exc:
        epg = None
        errors.append({"channel_code": code, "stage": "epg", "error": str(exc)})

    logo_file = None
    icon = channel.get("icon")
    if icon:  # Some operator channels have no icon: that is not a download error.
        try:
            if not logo_url_accepted(icon):
                raise ExportError(f"unexpected logo URL/origin: {icon!r}")
            data = router_get(host, icon)
            extension = image_extension(data)
            logo_file = f"logos/{index:04d}-{code}{extension}"
            atomic_bytes(output / logo_file, data)
        except (ExportError, OSError) as exc:
            errors.append({"channel_code": code, "stage": "logo", "error": str(exc)})
            logo_file = None
    return epg, logo_file, errors


def export(host, date, output):
    catalog = router_json(host, CATALOG_URL)
    channels = catalog.get("channels")
    if not isinstance(channels, list) or not channels:
        raise ExportError(f"catalog has no channels array at {CATALOG_URL}")
    output_channels = [dict(channel) if isinstance(channel, dict) else channel
                       for channel in channels]
    errors = []
    valid = []
    seen = set()
    for index, channel in enumerate(channels, 1):
        if (not isinstance(channel, dict) or not isinstance(channel.get("code"), str)
                or not CHANNEL_CODE.fullmatch(channel["code"])
                or not isinstance(channel.get("title"), str)):
            errors.append({"channel_index": index, "stage": "catalog",
                           "error": "missing/invalid channel code or title"})
            continue
        code = channel["code"]
        if code in seen:
            errors.append({"channel_index": index, "channel_code": code,
                           "stage": "catalog", "error": "duplicate channel code"})
            continue
        seen.add(code)
        valid.append((index, channel))
    if not valid:
        raise ExportError("catalog has no usable channels")
    (output / "logos").mkdir(exist_ok=True)

    results = {}
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(fetch_channel, host, index, channel, date, output): index
                   for index, channel in valid}
        for future in as_completed(futures):
            index = futures[future]
            try:
                results[index] = future.result()
            except Exception as exc:
                # Keep successfully retrieved channels; never substitute made-up EPG.
                results[index] = (None, None, [{"channel_code": channels[index - 1]["code"],
                                                "stage": "fetch", "error": str(exc)}])

    now = datetime.now(TIME_ZONE)
    live_lines = ["#EXTM3U"]
    replay_lines = ["#EXTM3U"]
    tv = ET.Element("tv", {"generator-info-name": "cmcc-iptv-export",
                           "source-info-url": CATALOG_URL})
    epg_count = logo_count = 0
    program_count = 0
    for index, channel in valid:
        code, title = channel["code"], channel["title"]
        enriched = output_channels[index - 1]
        epg, logo_file, channel_errors = results[index]
        errors.extend(channel_errors)
        if logo_file:
            enriched["logo_file"] = logo_file
            logo_count += 1
        params = channel.get("params") if isinstance(channel.get("params"), dict) else {}
        ztecode = params.get("ztecode")
        replay_template = None
        if (str(channel.get("lookbackAvailable", "")).lower() == "true"
                and isinstance(ztecode, str) and CHANNEL_CODE.fullmatch(ztecode)):
            replay_template = (REPLAY_BASE + quote(ztecode, safe="")
                               + "/index.m3u8?starttime={starttime}&endtime={endtime}")
            enriched["replay_url_template"] = replay_template

        logo_attr = f' tvg-logo="{m3u_attr(logo_file)}"' if logo_file else ""
        live_url = next((url for url in (params.get("zteurl"), params.get("hwurl"))
                         if multicast_url(url)), None)
        if live_url:
            live_lines.extend((f'#EXTINF:-1 tvg-id="{m3u_attr(code)}"'
                               f' tvg-name="{m3u_attr(title)}"{logo_attr}'
                               f' group-title="CMCC IPTV",{m3u_title(title)}', live_url))
        else:
            errors.append({"channel_code": code, "stage": "live",
                           "error": "no valid multicast zteurl or hwurl"})

        tv_channel = ET.SubElement(tv, "channel", id=code)
        ET.SubElement(tv_channel, "display-name").text = xml_text(title)
        if logo_file:
            ET.SubElement(tv_channel, "icon", src=logo_file)
        if epg is None:
            continue
        epg_count += 1
        enriched["epg"] = epg  # Preserve actual per-channel API response, not inferred schedules.
        for schedule_index, program in enumerate(epg["schedules"], 1):
            try:
                start, end = parse_schedule(program)
            except ValueError as exc:
                errors.append({"channel_code": code, "stage": "schedule",
                               "schedule_index": schedule_index, "error": str(exc)})
                continue
            program_count += 1
            item = ET.SubElement(tv, "programme", channel=code,
                                 start=start.strftime("%Y%m%d%H%M%S %z"),
                                 stop=end.strftime("%Y%m%d%H%M%S %z"))
            ET.SubElement(item, "title", lang="zh").text = xml_text(program["title"])
            if replay_template and end <= now:
                replay_url = replay_template.format(starttime=program["starttime"],
                                                    endtime=program["endtime"])
                replay_lines.extend((f'#EXTINF:-1 tvg-id="{m3u_attr(code)}"{logo_attr}'
                                     f' group-title="CMCC Replay",{m3u_title(title)} - '
                                     f'{m3u_title(program["title"])} ({start:%Y-%m-%d %H:%M})',
                                     replay_url))

    payload = dict(catalog)
    payload["channels"] = output_channels
    payload["source"] = {"kind": "operator_http_api_via_router_ssh_curl",
                         "catalog_url": CATALOG_URL,
                         "epg_url_template": EPG_BASE + "{code}.json?begintime={date}",
                         "epg_date": date, "timezone": "Asia/Shanghai",
                         "replay_urls_individually_verified": False}
    payload["errors"] = errors
    atomic_json(output / "channels.json", payload)
    atomic_bytes(output / "live.m3u", ("\n".join(live_lines) + "\n").encode("utf-8"))
    atomic_bytes(output / "replay.m3u", ("\n".join(replay_lines) + "\n").encode("utf-8"))
    atomic_bytes(output / "guide.xml", ET.tostring(tv, encoding="utf-8", xml_declaration=True))
    return {"channels": len(channels), "epgs": epg_count, "logos": logo_count,
            "live": (len(live_lines) - 1) // 2, "replay": (len(replay_lines) - 1) // 2,
            "programs": program_count}, errors


def epg_date(value):
    try:
        if not re.fullmatch(r"[0-9]{8}", value):
            raise ValueError("expected YYYYMMDD")
        return datetime.strptime(value, "%Y%m%d").strftime("%Y%m%d")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid --date {value!r}: {exc}") from exc


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="root@192.168.2.1",
                        help="router SSH target (default: root@192.168.2.1)")
    parser.add_argument("--date", type=epg_date,
                        default=(datetime.now(TIME_ZONE) - timedelta(days=1)).strftime("%Y%m%d"),
                        help="EPG day YYYYMMDD (default: yesterday in Asia/Shanghai)")
    parser.add_argument("--out", type=Path, default=Path("cmcc-iptv-export"),
                        help="output directory (default: ./cmcc-iptv-export)")
    args = parser.parse_args(argv)
    if (not args.host or args.host.startswith("-")
            or not re.fullmatch(r"[A-Za-z0-9._:@\[\]-]+", args.host)):
        parser.error("--host must be an SSH hostname or user@hostname, without SSH options")
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        args.out.mkdir(parents=True, exist_ok=True)
        counts, errors = export(args.host, args.date, args.out)
        print(f"{args.out}: {counts['channels']} catalog channels, {counts['epgs']} EPGs, "
              f"{counts['logos']} logos, {counts['programs']} guide programs, "
              f"{counts['live']} live entries, {counts['replay']} ended replay entries")
        if errors:
            for error in errors[:10]:
                print("  " + json.dumps(error, ensure_ascii=False), file=sys.stderr)
            if len(errors) > 10:
                print(f"  ... {len(errors) - 10} more in channels.json", file=sys.stderr)
        if not counts["epgs"] or not counts["live"]:
            print("Error: no usable EPGs or live channels; exported results are incomplete",
                  file=sys.stderr)
            return 1
        return 2 if errors else 0
    except (ExportError, OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
