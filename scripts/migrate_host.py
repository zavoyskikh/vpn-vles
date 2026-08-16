#!/usr/bin/env python3
"""Rewrite panel/subscription/NPM hostnames after restoring onto another server."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse

IPV4_RE = re.compile(r"^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$")
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,}$"
)
URL_KEYS = ("subURI", "subJsonURI", "subClashURI")
HOST_KEYS = ("webDomain", "subDomain")
# Bind addresses from the old host (e.g. docker0 172.18.0.1) are not valid
# inside a new container namespace — listen on all interfaces instead.
LISTEN_KEYS = ("webListen", "subListen")


def is_ipv4(value: str) -> bool:
    return bool(IPV4_RE.fullmatch(value.strip()))


def is_domain(value: str) -> bool:
    return bool(DOMAIN_RE.fullmatch(value.strip().lower()))


def is_ip_based_host(host: str) -> bool:
    host = (host or "").strip().lower().rstrip(".")
    if not host:
        return False
    if is_ipv4(host):
        return True
    lowered = host.lower()
    if lowered.endswith(".sslip.io") or lowered.endswith(".nip.io"):
        return True
    return False


def sslip_domain(ip: str) -> str:
    return f"{ip}.sslip.io"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def rewrite_text(value: str, old_domain: str, new_domain: str, old_ip: str, new_ip: str) -> str:
    if not value:
        return value
    out = value
    if old_domain and new_domain and old_domain != new_domain:
        out = out.replace(old_domain, new_domain)
    if old_ip and new_ip and old_ip != new_ip:
        out = out.replace(old_ip, new_ip)
    return out


def rewrite_url(value: str, new_host: str, panel_port: int) -> str:
    raw = (value or "").strip()
    if not raw:
        return raw
    parsed = urlparse(raw)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return raw
    netloc = new_host
    if panel_port and not (
        (parsed.scheme == "https" and panel_port == 443)
        or (parsed.scheme == "http" and panel_port == 80)
    ):
        netloc = f"{new_host}:{panel_port}"
    return urlunparse(
        (parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment)
    )


def psql(args: argparse.Namespace, sql: str, capture: bool = False) -> str:
    cmd = [
        "docker",
        "exec",
        "-i",
        args.pg_container,
        "psql",
        "-U",
        args.pg_user,
        "-d",
        args.pg_db,
        "-v",
        "ON_ERROR_STOP=1",
        "-t",
        "-A",
    ]
    result = subprocess.run(cmd, input=sql, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "psql failed")
    return result.stdout if capture else ""


def fetch_settings(args: argparse.Namespace) -> dict[str, str]:
    keys = URL_KEYS + HOST_KEYS + LISTEN_KEYS
    in_list = ", ".join(sql_literal(k) for k in keys)
    out = psql(
        args,
        f"SELECT key || E'\\t' || COALESCE(value, '') FROM settings WHERE key IN ({in_list});",
        capture=True,
    )
    data: dict[str, str] = {}
    for line in out.splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        data[key] = value
    return data


def update_setting(args: argparse.Namespace, key: str, value: str) -> None:
    psql(
        args,
        f"UPDATE settings SET value = {sql_literal(value)} WHERE key = {sql_literal(key)};",
    )


def rewrite_postgres(args: argparse.Namespace, changes: list[str]) -> None:
    settings = fetch_settings(args)
    for key in URL_KEYS:
        old = settings.get(key, "")
        if not old.strip():
            continue
        new = rewrite_url(old, args.new_domain, args.panel_port)
        if new != old:
            update_setting(args, key, new)
            changes.append(f"settings.{key}: {old} -> {new}")
    for key in HOST_KEYS:
        old = settings.get(key, "")
        if not old.strip():
            continue
        new = rewrite_text(old, args.old_domain, args.new_domain, args.old_ip, args.new_ip)
        if new != old:
            update_setting(args, key, new)
            changes.append(f"settings.{key}: {old} -> {new}")
    for key in LISTEN_KEYS:
        old = settings.get(key, "")
        if old.strip() in ("", "0.0.0.0", "::"):
            continue
        update_setting(args, key, "")
        changes.append(f"settings.{key}: {old} -> (all interfaces)")

    for table, column in (("hosts", "address"), ("inbounds", "share_addr")):
        out = psql(
            args,
            f"SELECT id || E'\\t' || COALESCE({column}, '') FROM {table};",
            capture=True,
        )
        for line in out.splitlines():
            if "\t" not in line:
                continue
            row_id, value = line.split("\t", 1)
            if not value:
                continue
            new = rewrite_text(value, args.old_domain, args.new_domain, args.old_ip, args.new_ip)
            if new == value:
                continue
            psql(
                args,
                f"UPDATE {table} SET {column} = {sql_literal(new)} WHERE id = {int(row_id)};",
            )
            changes.append(f"{table}.{column} id={row_id}: {value} -> {new}")


def rewrite_npm_sqlite(db_path: Path, args: argparse.Namespace, changes: list[str]) -> None:
    if not db_path.is_file():
        return
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT id, domain_names FROM proxy_host WHERE COALESCE(is_deleted, 0) = 0"
        ).fetchall()
        for row in rows:
            try:
                names = json.loads(row["domain_names"] or "[]")
            except json.JSONDecodeError:
                names = [row["domain_names"]]
            new_names = [
                rewrite_text(str(name), args.old_domain, args.new_domain, args.old_ip, args.new_ip)
                for name in names
            ]
            if new_names != names:
                conn.execute(
                    "UPDATE proxy_host SET domain_names = ?, modified_on = CURRENT_TIMESTAMP WHERE id = ?",
                    (json.dumps(new_names, ensure_ascii=False), row["id"]),
                )
                changes.append(f"npm proxy_host {row['id']}: {names} -> {new_names}")
        conn.commit()
    finally:
        conn.close()


def rewrite_nginx_dir(nginx_dir: Path, args: argparse.Namespace, changes: list[str]) -> None:
    if not nginx_dir.is_dir():
        return
    for path in nginx_dir.rglob("*.conf"):
        original = path.read_text(encoding="utf-8", errors="replace")
        updated = rewrite_text(
            original, args.old_domain, args.new_domain, args.old_ip, args.new_ip
        )
        if updated == original:
            continue
        path.write_text(updated, encoding="utf-8")
        changes.append(f"nginx {path.relative_to(nginx_dir)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-ip", required=True)
    parser.add_argument("--new-ip", required=True)
    parser.add_argument("--old-domain", default="")
    parser.add_argument("--new-domain", required=True)
    parser.add_argument("--panel-port", type=int, default=4443)
    parser.add_argument("--pg-container", default="3xui_postgres")
    parser.add_argument("--pg-user", default="xui")
    parser.add_argument("--pg-db", default="xui")
    parser.add_argument("--npm-sqlite", default="")
    parser.add_argument("--npm-nginx-dir", default="")
    return parser.parse_args()


def validate(args: argparse.Namespace) -> None:
    if not is_ipv4(args.old_ip) or not is_ipv4(args.new_ip):
        raise SystemExit("old-ip and new-ip must be IPv4 addresses")
    if not is_domain(args.new_domain) and not is_ipv4(args.new_domain):
        raise SystemExit(f"invalid new-domain: {args.new_domain}")
    if args.old_domain and not (is_domain(args.old_domain) or is_ipv4(args.old_domain)):
        raise SystemExit(f"invalid old-domain: {args.old_domain}")
    if args.panel_port < 1 or args.panel_port > 65535:
        raise SystemExit("invalid panel-port")


def main() -> int:
    args = parse_args()
    args.old_ip = args.old_ip.strip()
    args.new_ip = args.new_ip.strip()
    args.old_domain = args.old_domain.strip().lower().rstrip(".")
    args.new_domain = args.new_domain.strip().lower().rstrip(".")
    validate(args)

    if not args.old_domain:
        args.old_domain = sslip_domain(args.old_ip) if is_ip_based_host(args.new_domain) else ""

    if (
        args.old_ip == args.new_ip
        and (not args.old_domain or args.old_domain == args.new_domain)
    ):
        print("Host identity unchanged, nothing to rewrite.")
        return 0

    changes: list[str] = []
    rewrite_postgres(args, changes)
    if args.npm_sqlite:
        rewrite_npm_sqlite(Path(args.npm_sqlite), args, changes)
    if args.npm_nginx_dir:
        rewrite_nginx_dir(Path(args.npm_nginx_dir), args, changes)

    summary = {
        "old_ip": args.old_ip,
        "new_ip": args.new_ip,
        "old_domain": args.old_domain,
        "new_domain": args.new_domain,
        "panel_port": args.panel_port,
        "changes": changes,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # pragma: no cover
        print(f"migrate_host failed: {exc}", file=sys.stderr)
        sys.exit(1)
