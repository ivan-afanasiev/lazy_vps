#!/usr/bin/env python3
"""
lazy-vps Telegram bot.

Runs on the lazy-vps EC2 instance inside a Docker container and exposes the
monitoring / link commands from the repo Makefile to a fixed list of allowed
Telegram users.

Config via env:
  TELEGRAM_BOT_TOKEN         - bot token from @BotFather
  ALLOWED_USERS_JSON         - JSON array of user IDs (strings of digits) and usernames
  AWS_REGION                 - AWS region for CloudWatch traffic queries
  XRAY_UUID, XRAY_SHORT_ID, CAMOUFLAGE_DOMAIN - to build vless link
  MTPROTO_PORT               - informational
  AMNEZIA_ENABLED            - 'true' if AmneziaWG is configured on this VPS
  TAILSCALE_ENABLED          - 'true' if Tailscale is configured on this VPS
  CTL_SOCKET                 - path to lazy-vps-ctl Unix socket for restart
  XRAY_PUBLIC_KEY_PATH       - default /data/xray/public_key.txt
  XRAY_ACCESS_LOG            - default /data/xray/access.log
  TG_LINK_PATH               - default /data/telemt/tg_link.txt
  AMNEZIA_VPN_URI_PATH       - default /data/amnezia/vpn.uri
  AMNEZIA_CLIENT_CONF_PATH   - default /data/amnezia/client.conf
  DOCKER_SOCK                - default /var/run/docker.sock
"""
from __future__ import annotations

import asyncio
import datetime as dt
import functools
import json
import logging
import os
import re
import socket
import subprocess
from typing import Iterable

import urllib.request
import urllib.error

import boto3
from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("lazy-vps-bot")

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
AWS_REGION = os.environ.get("AWS_REGION", "eu-north-1")
XRAY_UUID = os.environ.get("XRAY_UUID", "")
XRAY_SHORT_ID = os.environ.get("XRAY_SHORT_ID", "")
CAMOUFLAGE_DOMAIN = os.environ.get("CAMOUFLAGE_DOMAIN", "")
MTPROTO_PORT = os.environ.get("MTPROTO_PORT", "8443")

XRAY_PUBLIC_KEY_PATH = os.environ.get("XRAY_PUBLIC_KEY_PATH", "/data/xray/public_key.txt")
XRAY_ACCESS_LOG = os.environ.get("XRAY_ACCESS_LOG", "/data/xray/access.log")
TG_LINK_PATH = os.environ.get("TG_LINK_PATH", "/data/telemt/tg_link.txt")
AMNEZIA_ENABLED = os.environ.get("AMNEZIA_ENABLED", "").strip().lower() in {"true", "1", "yes"}
AMNEZIA_VPN_URI_PATH = os.environ.get("AMNEZIA_VPN_URI_PATH", "/data/amnezia/vpn.uri")
AMNEZIA_CLIENT_CONF_PATH = os.environ.get("AMNEZIA_CLIENT_CONF_PATH", "/data/amnezia/client.conf")
TAILSCALE_ENABLED = os.environ.get("TAILSCALE_ENABLED", "").strip().lower() in {"true", "1", "yes"}
CTL_SOCKET = os.environ.get("CTL_SOCKET", "/data/ctl/lazy-vps-ctl.sock")
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
INSTANCE_NAME_TAG = os.environ.get("INSTANCE_NAME_TAG", "lazy-vps")


def _parse_allowed(raw: str) -> tuple[set[str], set[str]]:
    """Return (user_ids as str, usernames lowercased)."""
    try:
        items = json.loads(raw) if raw else []
    except json.JSONDecodeError:
        log.error("ALLOWED_USERS_JSON is not valid JSON: %r", raw)
        items = []
    ids: set[str] = set()
    names: set[str] = set()
    for item in items:
        s = str(item).strip()
        if not s:
            continue
        if s.startswith("@"):
            s = s[1:]
        if s.isdigit():
            ids.add(s)
        else:
            names.add(s.lower())
    return ids, names


ALLOWED_IDS, ALLOWED_USERNAMES = _parse_allowed(os.environ.get("ALLOWED_USERS_JSON", "[]"))
log.info(
    "Authorized: %d user IDs, %d usernames",
    len(ALLOWED_IDS),
    len(ALLOWED_USERNAMES),
)


def _is_authorized(update: Update) -> bool:
    user = update.effective_user
    if user is None:
        return False
    if str(user.id) in ALLOWED_IDS:
        return True
    if user.username and user.username.lower() in ALLOWED_USERNAMES:
        return True
    return False


def authorized(handler):
    @functools.wraps(handler)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        if not _is_authorized(update):
            uid = user.id if user else "?"
            uname = user.username if user else "?"
            log.warning("Unauthorized access attempt: id=%s username=%s", uid, uname)
            if update.effective_message:
                await update.effective_message.reply_text("Not authorized.")
            return
        log.info(
            "Authorized call: user=%s id=%s cmd=%s",
            user.username if user else "?",
            user.id if user else "?",
            update.effective_message.text if update.effective_message else "?",
        )
        return await handler(update, context)

    return wrapper


async def _run(cmd: list[str], timeout: float = 15.0) -> tuple[int, str]:
    """Run a shell command in an executor. Returns (returncode, combined_output)."""
    loop = asyncio.get_running_loop()

    def _do() -> tuple[int, str]:
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            out = (proc.stdout or "") + (proc.stderr or "")
            return proc.returncode, out.strip()
        except FileNotFoundError as exc:
            return 127, f"command not found: {exc}"
        except subprocess.TimeoutExpired:
            return 124, f"command timed out after {timeout}s"
        except Exception as exc:  # noqa: BLE001
            return 1, f"error: {exc}"

    return await loop.run_in_executor(None, _do)


def _read_file(path: str, limit: int = 4096) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = fh.read(limit + 1)
        return data[:limit] + ("…" if len(data) > limit else "")
    except FileNotFoundError:
        return ""
    except OSError as exc:
        return f"(error reading {path}: {exc})"


def _code_block(text: str, limit: int = 3500) -> str:
    if len(text) > limit:
        text = text[:limit] + "\n…(truncated)"
    return f"<pre>{_html_escape(text)}</pre>"


def _html_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


HELP_TEXT = (
    "lazy-vps bot\n\n"
    "/vless - VLESS connection link\n"
    "/tg - Telegram proxy link\n"
    "/amnezia - AmneziaWG client config + vpn:// link\n"
    "/status - Xray service status\n"
    "/tgstatus - Telemt (Telegram proxy) container status\n"
    "/amnstatus - AmneziaWG interface status (peers, handshake, transfer)\n"
    "/tsstatus - Tailscale daemon + tunnel status\n"
    "/tsup - Bring the VPS back onto the tailnet (re-runs `tailscale up`)\n"
    "/tsdown - Take the VPS off the tailnet (`tailscale down`; re-up via /tsup)\n"
    "/traffic - Month-to-date EC2 network traffic (CloudWatch)\n"
    "/destinations [N] - Top N destinations this month (default 20)\n"
    "/users [N] - Top N client IPs per service this month (default 10)\n"
    "/restart xray|telemt|amnezia|tailscale - Restart a service\n"
    "/help - Show this message"
)


@authorized
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.effective_message.reply_text(HELP_TEXT)


@authorized
async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.effective_message.reply_text(HELP_TEXT)


def _get_public_ip() -> str:
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
        )
        with urllib.request.urlopen(token_req, timeout=3) as resp:
            token = resp.read().decode().strip()
        ip_req = urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/public-ipv4",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(ip_req, timeout=3) as resp:
            return resp.read().decode().strip()
    except Exception as exc:  # noqa: BLE001
        log.warning("IMDS public IP fetch failed: %s", exc)
        return ""


@authorized
async def cmd_vless(update: Update, context: ContextTypes.DEFAULT_TYPE):
    ip = _get_public_ip()
    pbk = _read_file(XRAY_PUBLIC_KEY_PATH).strip()
    if not ip:
        await update.effective_message.reply_text(
            "Could not determine server public IP (IMDS unreachable)."
        )
        return
    if not pbk:
        await update.effective_message.reply_text(
            "Xray public key not available yet. If the server just booted, wait a minute."
        )
        return
    link = (
        f"vless://{XRAY_UUID}@{ip}:443?"
        f"encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={CAMOUFLAGE_DOMAIN}&fp=chrome&pbk={pbk}"
        f"&sid={XRAY_SHORT_ID}&type=tcp#lazy-vps"
    )
    msg = (
        "VLESS Connection Link:\n\n"
        f"<code>{_html_escape(link)}</code>\n\n"
        "Import this link into your client app:\n"
        "  iOS: Streisand / V2Box\n"
        "  macOS: V2Box / Hiddify Next\n"
        "  Android: v2rayNG / Hiddify Next\n"
        "  Windows: v2rayN"
    )
    await update.effective_message.reply_text(msg, parse_mode=ParseMode.HTML)


@authorized
async def cmd_tg(update: Update, context: ContextTypes.DEFAULT_TYPE):
    link = _read_file(TG_LINK_PATH).strip()
    if not link:
        await update.effective_message.reply_text(
            "Telegram proxy link not available yet. If the server just booted, wait a minute."
        )
        return
    msg = (
        "Telegram Proxy Link:\n\n"
        f"<code>{_html_escape(link)}</code>\n\n"
        "Open this link on any device with Telegram; it will offer to enable the proxy."
    )
    await update.effective_message.reply_text(msg, parse_mode=ParseMode.HTML)


@authorized
async def cmd_amnezia(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not AMNEZIA_ENABLED:
        await update.effective_message.reply_text(
            "AmneziaWG is disabled on this VPS.\n"
            "Set TF_VAR_amnezia_enabled=true and re-deploy."
        )
        return

    # vpn:// is a single line; .conf is multi-line. We send each as its
    # own message so users can long-press → copy each independently. The
    # .conf message also doubles as a sanity check ("if you can't import
    # the link, just paste this into a WireGuard-style client").
    uri = _read_file(AMNEZIA_VPN_URI_PATH, limit=8192).strip()
    conf = _read_file(AMNEZIA_CLIENT_CONF_PATH, limit=4096).strip()

    if not uri and not conf:
        await update.effective_message.reply_text(
            "AmneziaWG config not available yet. If the server just booted, "
            "wait a minute (DKMS module compile + first start can take ~5 min)."
        )
        return

    if uri:
        await update.effective_message.reply_text(
            "AmneziaWG vpn:// link (one-tap import in the Amnezia VPN app):\n\n"
            f"<code>{_html_escape(uri)}</code>",
            parse_mode=ParseMode.HTML,
        )
    if conf:
        await update.effective_message.reply_text(
            "Same config as a .conf file (for AmneziaWG / WireGuard apps):\n\n"
            f"<pre>{_html_escape(conf)}</pre>",
            parse_mode=ParseMode.HTML,
        )


@authorized
async def cmd_amnstatus(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not AMNEZIA_ENABLED:
        await update.effective_message.reply_text(
            "AmneziaWG is disabled on this VPS."
        )
        return
    rc, out = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, "status amnezia"
    )
    if rc != 0:
        await update.effective_message.reply_text(f"AmneziaWG status unavailable: {out}")
        return
    # _ctl_call already stripped the leading "OK " — `out` is the rest.
    await update.effective_message.reply_text(
        _code_block(out) if out else "(no output from awg show)",
        parse_mode=ParseMode.HTML,
    )


def _tailscale_disabled_msg() -> str:
    return (
        "Tailscale is not configured on this VPS.\n"
        "Set TF_VAR_tailscale_auth_key and re-deploy."
    )


@authorized
async def cmd_tsstatus(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not TAILSCALE_ENABLED:
        await update.effective_message.reply_text(_tailscale_disabled_msg())
        return
    rc, out = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, "status tailscale"
    )
    if rc != 0:
        await update.effective_message.reply_text(f"Tailscale status unavailable: {out}")
        return
    await update.effective_message.reply_text(
        _code_block(out) if out else "(no output from tailscale status)",
        parse_mode=ParseMode.HTML,
    )


@authorized
async def cmd_tsup(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not TAILSCALE_ENABLED:
        await update.effective_message.reply_text(_tailscale_disabled_msg())
        return
    await update.effective_message.reply_text("Bringing tailnet up…")
    # `tailscale up` can take a few seconds to negotiate; bump the timeout.
    rc, out = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, "up tailscale", 30.0
    )
    if rc == 0:
        await update.effective_message.reply_text(f"OK: {out or 'up'}")
    else:
        await update.effective_message.reply_text(f"Failed: {out}")


@authorized
async def cmd_tsdown(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not TAILSCALE_ENABLED:
        await update.effective_message.reply_text(_tailscale_disabled_msg())
        return
    # Friendly heads-up: the operator is *probably* sitting on a laptop
    # whose only path to the VPS is the tailnet (since public SSH is
    # closed when Tailscale is configured). After /tsdown they'll lose
    # SSH but can still re-up via /tsup since the bot reaches the VPS
    # over Telegram, not the tailnet.
    await update.effective_message.reply_text(
        "Taking the VPS off the tailnet…\n"
        "You'll lose `make ssh` until you /tsup again."
    )
    rc, out = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, "down tailscale", 20.0
    )
    if rc == 0:
        await update.effective_message.reply_text(f"OK: {out or 'down'}")
    else:
        await update.effective_message.reply_text(f"Failed: {out}")


def _ctl_call(cmd: str, timeout: float = 10.0) -> tuple[int, str]:
    """Send a line to the lazy-vps-ctl Unix socket, read response.

    Protocol: client sends a single line like 'restart xray\\n'.
    Server responds with 'OK <message>\\n' (status 0) or 'ERR <message>\\n' (non-zero).
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(CTL_SOCKET)
            sock.sendall((cmd.strip() + "\n").encode())
            sock.shutdown(socket.SHUT_WR)
            data = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
            text = data.decode(errors="replace").strip()
    except FileNotFoundError:
        return 1, f"ctl socket not found at {CTL_SOCKET}"
    except (OSError, socket.timeout) as exc:
        return 1, f"ctl socket error: {exc}"
    if text.startswith("OK"):
        return 0, text[2:].strip()
    if text.startswith("ERR"):
        return 1, text[3:].strip()
    return 1, text or "(empty response)"


@authorized
async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    rc, out = await _run(["docker", "--version"])
    # Xray runs on the host, so use the ctl socket (same helper used for restart).
    rc2, out2 = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, "status xray"
    )
    if rc2 == 0:
        msg = f"Xray: {out2}"
    else:
        msg = f"Xray status unavailable: {out2}"
    await update.effective_message.reply_text(msg)


@authorized
async def cmd_tgstatus(update: Update, context: ContextTypes.DEFAULT_TYPE):
    rc, ps_out = await _run(["docker", "ps", "-f", "name=telemt", "--format",
                             "{{.Names}}  {{.Status}}  {{.Ports}}"])
    if rc != 0:
        await update.effective_message.reply_text(
            f"docker ps failed:\n{_code_block(ps_out)}",
            parse_mode=ParseMode.HTML,
        )
        return
    _, logs_out = await _run(["docker", "logs", "--tail", "20", "telemt"], timeout=10)
    body = "Containers:\n"
    body += ps_out or "(no telemt container found)"
    body += "\n\nRecent logs:\n"
    body += logs_out or "(no logs)"
    await update.effective_message.reply_text(
        _code_block(body),
        parse_mode=ParseMode.HTML,
    )


@authorized
async def cmd_restart(update: Update, context: ContextTypes.DEFAULT_TYPE):
    args = context.args or []
    valid = {"xray", "telemt", "amnezia", "tailscale"}
    if not args or args[0] not in valid:
        await update.effective_message.reply_text(
            "Usage: /restart xray|telemt|amnezia|tailscale"
        )
        return
    service = args[0]
    if service == "amnezia" and not AMNEZIA_ENABLED:
        await update.effective_message.reply_text(
            "AmneziaWG is disabled on this VPS."
        )
        return
    if service == "tailscale" and not TAILSCALE_ENABLED:
        await update.effective_message.reply_text(_tailscale_disabled_msg())
        return
    await update.effective_message.reply_text(f"Restarting {service}…")
    rc, out = await asyncio.get_running_loop().run_in_executor(
        None, _ctl_call, f"restart {service}", 20.0
    )
    if rc == 0:
        await update.effective_message.reply_text(f"OK: {out or 'restarted'}")
    else:
        await update.effective_message.reply_text(f"Failed: {out}")


def _get_instance_id() -> str:
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
        )
        with urllib.request.urlopen(token_req, timeout=3) as resp:
            token = resp.read().decode().strip()
        iid_req = urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/instance-id",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(iid_req, timeout=3) as resp:
            return resp.read().decode().strip()
    except Exception as exc:  # noqa: BLE001
        log.warning("IMDS instance-id fetch failed: %s", exc)
        return ""


def _sum_metric(client, instance_id: str, metric: str, start: dt.datetime, end: dt.datetime) -> float:
    resp = client.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName=metric,
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=start,
        EndTime=end,
        Period=86400,
        Statistics=["Sum"],
    )
    return float(sum(dp.get("Sum", 0) or 0 for dp in resp.get("Datapoints", [])))


def _do_traffic() -> str:
    instance_id = _get_instance_id()
    if not instance_id:
        return "Could not determine instance-id from IMDS."
    now = dt.datetime.now(dt.timezone.utc)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    cw = boto3.client("cloudwatch", region_name=AWS_REGION)
    try:
        in_b = _sum_metric(cw, instance_id, "NetworkIn", start, now)
        out_b = _sum_metric(cw, instance_id, "NetworkOut", start, now)
    except Exception as exc:  # noqa: BLE001
        return f"CloudWatch error: {exc}"
    gb = 1024 ** 3
    free_gb = 100.0
    rate = 0.09
    out_gb = out_b / gb
    free_left = max(0.0, free_gb - out_gb)
    billable = max(0.0, out_gb - free_gb)
    cost = billable * rate
    month_label = now.strftime("%B %Y")
    lines = [
        f"Traffic for {month_label} (month-to-date)",
        f"Instance: {instance_id}  ({AWS_REGION})",
        "",
        f"  In:    {in_b/gb:7.2f} GB  (free)",
        f"  Out:   {out_gb:7.2f} GB",
        f"  Total: {(in_b+out_b)/gb:7.2f} GB",
        "",
        "Billing estimate (data transfer out to internet):",
        f"  Free tier:    {min(out_gb, free_gb):6.2f} GB / {free_gb:.0f} GB (account-wide)",
        f"  Free left:    {free_left:6.2f} GB",
        f"  Billable:     {billable:6.2f} GB  @ ${rate:.2f}/GB",
        f"  Est. cost:    ${cost:.2f}",
        "",
        "  Note: rate assumes first 10 TB tier.",
        "        EC2 instance-hours and EBS are billed separately.",
    ]
    return "\n".join(lines)


@authorized
async def cmd_traffic(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.effective_message.reply_text("Fetching CloudWatch metrics…")
    text = await asyncio.get_running_loop().run_in_executor(None, _do_traffic)
    await update.effective_message.reply_text(
        _code_block(text), parse_mode=ParseMode.HTML
    )


def _parse_top(args: Iterable[str], default: int) -> int:
    for a in args:
        try:
            return max(0, int(a))
        except ValueError:
            continue
    return default


def _iter_xray_log_lines_this_month(prefix: str) -> Iterable[str]:
    try:
        with open(XRAY_ACCESS_LOG, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith(prefix):
                    yield line
    except FileNotFoundError:
        return
    except OSError as exc:
        log.warning("read xray log: %s", exc)
        return


def _do_destinations(top: int) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    prefix = now.strftime("%Y/%m/01")
    # Xray access log line example:
    # 2026/04/21 10:23:45 from 1.2.3.4:5678 accepted tcp:example.com:443 ...
    counts: dict[str, int] = {}
    host_re = re.compile(r"(?:tcp|udp):([^\s]+)")
    for line in _iter_xray_log_lines_this_month(prefix):
        parts = line.split()
        if len(parts) < 6 or parts[4] != "accepted":
            continue
        m = host_re.match(parts[5])
        if not m:
            continue
        hostport = m.group(1)
        # strip :port (handle IPv6 in brackets)
        if hostport.startswith("[") and "]" in hostport:
            host = hostport[1:hostport.index("]")]
        else:
            host = hostport.rsplit(":", 1)[0]
        counts[host] = counts.get(host, 0) + 1

    month_label = now.strftime("%B %Y")
    lines = [
        f"Destinations for {month_label} (month-to-date)",
    ]
    if not counts:
        lines += [
            "",
            "  No traffic logged yet this month.",
            "  (Xray access logging may have been enabled recently.)",
        ]
        return "\n".join(lines)

    items = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)
    lines.append(f"Unique destinations: {len(items)}")
    lines.append("")
    lines.append(f"  {'conns':>9}  destination")
    shown = items if top == 0 else items[:top]
    for host, n in shown:
        lines.append(f"  {n:>9}  {host}")
    if top and len(items) > top:
        lines.append(f"  … +{len(items) - top} more (use /destinations 0 to show all)")
    return "\n".join(lines)


@authorized
async def cmd_destinations(update: Update, context: ContextTypes.DEFAULT_TYPE):
    top = _parse_top(context.args or [], default=20)
    text = await asyncio.get_running_loop().run_in_executor(
        None, _do_destinations, top
    )
    await update.effective_message.reply_text(
        _code_block(text), parse_mode=ParseMode.HTML
    )


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
PEER_RE = re.compile(r"peer=(\d+\.\d+\.\d+\.\d+)")


def _xray_ip_counts(prefix: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in _iter_xray_log_lines_this_month(prefix):
        parts = line.split()
        if len(parts) < 4 or parts[2] != "from":
            continue
        ip = parts[3].split(":", 1)[0]
        counts[ip] = counts.get(ip, 0) + 1
    return counts


def _telemt_ip_counts(since: str) -> dict[str, int]:
    try:
        proc = subprocess.run(
            ["docker", "logs", "telemt", "--since", since],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        log.warning("docker logs telemt failed: %s", exc)
        return {}
    combined = (proc.stdout or "") + (proc.stderr or "")
    combined = ANSI_RE.sub("", combined)
    counts: dict[str, int] = {}
    for m in PEER_RE.finditer(combined):
        ip = m.group(1)
        counts[ip] = counts.get(ip, 0) + 1
    return counts


def _geo_lookup(ips: list[str]) -> dict[str, tuple[str, str]]:
    """Batch GeoIP via ip-api.com. Returns {ip: (location, isp)}."""
    result: dict[str, tuple[str, str]] = {}
    if not ips:
        return result
    for i in range(0, len(ips), 100):
        batch = ips[i : i + 100]
        body = json.dumps(batch).encode()
        req = urllib.request.Request(
            "http://ip-api.com/batch?fields=status,query,countryCode,city,isp,as",
            data=body,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            log.warning("ip-api batch failed: %s", exc)
            continue
        for entry in data:
            if entry.get("status") != "success":
                continue
            ip = entry.get("query", "")
            city = entry.get("city") or ""
            cc = entry.get("countryCode") or "?"
            loc = f"{city}, {cc}" if city else cc
            isp = entry.get("isp") or entry.get("as") or "?"
            result[ip] = (loc, isp)
    return result


def _render_section(title: str, counts: dict[str, int], geo: dict[str, tuple[str, str]], top: int) -> list[str]:
    lines: list[str] = [""]
    total = len(counts)
    lines.append(f"{title} — unique client IPs: {total}")
    if not counts:
        lines.append("  (no data)")
        return lines
    items = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)
    lines.append(f"  {'conns':>6}  {'IP':<15}  {'Location':<22}  ISP")
    shown = items if top == 0 else items[:top]
    for ip, n in shown:
        loc, isp = geo.get(ip, ("?", "?"))
        if len(loc) > 22:
            loc = loc[:20] + ".."
        if len(isp) > 38:
            isp = isp[:36] + ".."
        lines.append(f"  {n:>6}  {ip:<15}  {loc:<22}  {isp}")
    if top and len(items) > top:
        lines.append(f"  … +{len(items) - top} more (use /users 0 to show all)")
    return lines


def _do_users(top: int) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    prefix = now.strftime("%Y/%m/01")
    month_start = now.strftime("%Y-%m-01T00:00:00")
    month_label = now.strftime("%B %Y")

    xray_counts = _xray_ip_counts(prefix)
    telemt_counts = _telemt_ip_counts(month_start)

    all_ips = sorted(set(xray_counts) | set(telemt_counts))
    geo = _geo_lookup(all_ips)

    out: list[str] = [f"Users for {month_label} (month-to-date)"]
    if not xray_counts:
        out += [
            "",
            "VLESS VPN (Xray) — no connections logged yet this month",
            "  (Xray access logging may have been enabled recently.)",
        ]
    else:
        out += _render_section("VLESS VPN (Xray)", xray_counts, geo, top)
    out += _render_section("Telegram Proxy (Telemt)", telemt_counts, geo, top)
    suffix = "all" if top == 0 else str(top)
    out += ["", f"  Showing top {suffix} per service. /users N or /users 0 (all)."]
    return "\n".join(out)


@authorized
async def cmd_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    top = _parse_top(context.args or [], default=10)
    await update.effective_message.reply_text("Collecting IP data (may take a few seconds)…")
    text = await asyncio.get_running_loop().run_in_executor(None, _do_users, top)
    await update.effective_message.reply_text(
        _code_block(text), parse_mode=ParseMode.HTML
    )


def main() -> None:
    if not BOT_TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN is required")
    if not (ALLOWED_IDS or ALLOWED_USERNAMES):
        log.warning(
            "ALLOWED_USERS_JSON did not parse any authorized users; "
            "the bot will reject all messages."
        )
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("vless", cmd_vless))
    app.add_handler(CommandHandler("tg", cmd_tg))
    app.add_handler(CommandHandler("amnezia", cmd_amnezia))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("tgstatus", cmd_tgstatus))
    app.add_handler(CommandHandler("amnstatus", cmd_amnstatus))
    app.add_handler(CommandHandler("tsstatus", cmd_tsstatus))
    app.add_handler(CommandHandler("tsup", cmd_tsup))
    app.add_handler(CommandHandler("tsdown", cmd_tsdown))
    app.add_handler(CommandHandler("traffic", cmd_traffic))
    app.add_handler(CommandHandler("destinations", cmd_destinations))
    app.add_handler(CommandHandler("users", cmd_users))
    app.add_handler(CommandHandler("restart", cmd_restart))
    log.info("lazy-vps bot starting")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()






