#!/usr/bin/env python3
"""Interactive initializer for SOC demo .env secrets and required settings."""

from __future__ import annotations

import getpass
import os
import re
import tempfile
from pathlib import Path
from typing import Dict, List, Tuple

ROOT = Path(__file__).resolve().parent
ENV_FILES = [
    ROOT / ".env",
    ROOT / "regional/.env",
    ROOT / "central/.env",
    ROOT / "zammad/.env",
    ROOT / "edge/.env",
]

SECRET_KEYS = {
    "INDEXER_PASSWORD",
    "OPENSEARCH_INITIAL_ADMIN_PASSWORD",
    "POSTGRES_PASSWORD",
}

DEPRECATED_COMPONENT_CERT_KEYS = {
    "CERT_COUNTRY",
    "CERT_STATE",
    "CERT_LOCALITY",
    "CERT_ORGANIZATION",
    "CERT_ADMIN_CN",
}

ENV_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


class UserAbort(Exception):
    """Raised when the user cancels the flow."""


def parse_env_values(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ENV_LINE_RE.match(stripped)
        if not match:
            continue
        key, raw = match.groups()
        values[key] = unquote(raw.strip())
    return values


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def quote_like(old_raw: str, new_value: str) -> str:
    old = old_raw.strip()
    if len(old) >= 2 and old[0] == old[-1] and old[0] in {'"', "'"}:
        quote = old[0]
        if quote == "'" and "'" in new_value:
            escaped = new_value.replace("\\", "\\\\").replace('"', '\\"')
            return f'"{escaped}"'
        if quote == "\"":
            escaped = new_value.replace("\\", "\\\\").replace('"', '\\"')
        else:
            escaped = new_value.replace("\\", "\\\\")
        return f"{quote}{escaped}{quote}"
    return new_value


def prompt_value(label: str, default: str, *, secret: bool = False, validator=None) -> str:
    while True:
        if secret:
            prompt = f"{label} [leave blank to keep current]"
            entered = getpass.getpass(f"{prompt}: ")
            value = entered.strip() or default
        else:
            suffix = f" [{default}]" if default else ""
            entered = input(f"{label}{suffix}: ").strip()
            value = entered or default

        if not value:
            print("  Value is required.")
            continue

        if validator and not validator(value):
            print("  Invalid value. Please try again.")
            continue

        return value


def is_email(value: str) -> bool:
    return bool(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", value))


def is_domain_like(value: str) -> bool:
    return bool(re.match(r"^[A-Za-z0-9.-]+$", value))


def mask_value(key: str, value: str) -> str:
    if key not in SECRET_KEYS:
        return value
    if len(value) <= 4:
        return "*" * len(value)
    return f"{value[:2]}{'*' * (len(value) - 4)}{value[-2:]}"


def compute_updates(current: Dict[Path, Dict[str, str]]) -> Dict[Path, Dict[str, str]]:
    root_vals = current[ROOT / ".env"]
    reg_vals = current[ROOT / "regional/.env"]
    cen_vals = current[ROOT / "central/.env"]
    zam_vals = current[ROOT / "zammad/.env"]
    edge_vals = current[ROOT / "edge/.env"]

    print("\nSOC Demo required configuration\n")

    domain = prompt_value("Base domain (DOMAIN)", root_vals.get("DOMAIN", "connection.lan"), validator=is_domain_like)
    dashboard_fqdn = prompt_value(
        "Dashboard FQDN (DASHBOARD_FQDN)",
        cen_vals.get("DASHBOARD_FQDN", f"dashboard.{domain}"),
        validator=is_domain_like,
    )
    helpdesk_fqdn = prompt_value(
        "Helpdesk FQDN (HELPDESK_FQDN)",
        zam_vals.get("HELPDESK_FQDN", f"helpdesk.{domain}"),
        validator=is_domain_like,
    )

    acme_email = prompt_value(
        "Traefik ACME email (TRAEFIK_ACME_EMAIL)",
        edge_vals.get("TRAEFIK_ACME_EMAIL", ""),
        validator=is_email,
    )

    organization = prompt_value("Certificate organization (ORGANIZATION)", root_vals.get("ORGANIZATION", "Acme Corporation"))
    country = prompt_value("Certificate country (COUNTRY)", root_vals.get("COUNTRY", "IN"))
    state = prompt_value("Certificate state (STATE)", root_vals.get("STATE", "Maharashtra"))
    locality = prompt_value("Certificate locality (LOCALITY)", root_vals.get("LOCALITY", "Mumbai"))
    cert_days = prompt_value("Certificate validity days (DAYS)", root_vals.get("DAYS", "3650"), validator=lambda v: v.isdigit())
    cn_root = prompt_value("Certificate root CN (CN_ROOT)", root_vals.get("CN_ROOT", "RootCA"))
    cn_admin = prompt_value("Certificate admin CN (CN_ADMIN)", root_vals.get("CN_ADMIN", "admin"))

    indexer_user = prompt_value("Indexer username (shared)", reg_vals.get("INDEXER_USER", cen_vals.get("INDEXER_USER", "admin")))
    indexer_password = prompt_value(
        "Indexer password (shared)",
        reg_vals.get("INDEXER_PASSWORD", cen_vals.get("INDEXER_PASSWORD", "")),
        secret=True,
    )

    postgres_user = prompt_value("Zammad Postgres user (POSTGRES_USER)", zam_vals.get("POSTGRES_USER", "admin"))
    postgres_password = prompt_value(
        "Zammad Postgres password (POSTGRES_PASSWORD)",
        zam_vals.get("POSTGRES_PASSWORD", ""),
        secret=True,
    )

    return {
        ROOT / ".env": {
            "DOMAIN": domain,
            "DAYS": cert_days,
            "COUNTRY": country,
            "STATE": state,
            "LOCALITY": locality,
            "ORGANIZATION": organization,
            "CN_ROOT": cn_root,
            "CN_ADMIN": cn_admin,
        },
        ROOT / "regional/.env": {
            "DOMAIN": domain,
            "INDEXER_USER": indexer_user,
            "INDEXER_PASSWORD": indexer_password,
            "OPENSEARCH_INITIAL_ADMIN_PASSWORD": indexer_password,
        },
        ROOT / "central/.env": {
            "DOMAIN": domain,
            "DASHBOARD_FQDN": dashboard_fqdn,
            "INDEXER_USER": indexer_user,
            "INDEXER_PASSWORD": indexer_password,
            "OPENSEARCH_INITIAL_ADMIN_PASSWORD": indexer_password,
        },
        ROOT / "zammad/.env": {
            "DOMAIN": domain,
            "HELPDESK_FQDN": helpdesk_fqdn,
            "POSTGRES_USER": postgres_user,
            "POSTGRES_PASSWORD": postgres_password,
        },
        ROOT / "edge/.env": {
            "TRAEFIK_ACME_EMAIL": acme_email,
        },
    }


def build_summary(
    current: Dict[Path, Dict[str, str]],
    updates: Dict[Path, Dict[str, str]],
    removals: Dict[Path, List[str]],
) -> Dict[Path, List[Tuple[str, str, str]]]:
    summary: Dict[Path, List[Tuple[str, str, str]]] = {}
    for path in ENV_FILES:
        file_changes: List[Tuple[str, str, str]] = []
        keyvals = updates.get(path, {})
        existing = current.get(path, {})
        for key, new_val in keyvals.items():
            old_val = existing.get(key, "")
            if old_val != new_val:
                file_changes.append((key, old_val, new_val))
        for key in removals.get(path, []):
            old_val = existing.get(key, "")
            if old_val:
                file_changes.append((key, old_val, "<removed>"))
        if file_changes:
            summary[path] = file_changes
    return summary


def print_summary(summary: Dict[Path, List[Tuple[str, str, str]]]) -> None:
    print("\nPending changes:\n")
    if not summary:
        print("No changes detected. Files are already up to date.")
        return

    for path in ENV_FILES:
        if path not in summary:
            continue
        rel = path.relative_to(ROOT)
        print(f"- {rel}")
        for key, old_val, new_val in summary[path]:
            old_disp = mask_value(key, old_val) if old_val else "<empty>"
            new_disp = mask_value(key, new_val)
            print(f"  {key}: {old_disp} -> {new_disp}")
        print("")


def apply_updates(path: Path, keyvals: Dict[str, str], remove_keys: set[str] | None = None) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    remaining = dict(keyvals)
    remove_keys = remove_keys or set()

    updated_lines: List[str] = []
    for line in lines:
        match = ENV_LINE_RE.match(line.strip())
        if not match:
            updated_lines.append(line)
            continue

        key, raw = match.groups()

        if key in remove_keys:
            continue

        if key not in remaining:
            updated_lines.append(line)
            continue

        new_value = remaining.pop(key)
        formatted = quote_like(raw, new_value)
        newline = "\n" if line.endswith("\n") else ""
        updated_lines.append(f"{key}={formatted}{newline}")

    if remaining:
        if updated_lines and not updated_lines[-1].endswith("\n"):
            updated_lines[-1] += "\n"
        updated_lines.append("\n# Added by init-secrets.py\n")
        for key, value in remaining.items():
            updated_lines.append(f"{key}={value}\n")

    tmp_fd, tmp_name = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tmpf:
            tmpf.writelines(updated_lines)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def main() -> int:
    missing = [str(p.relative_to(ROOT)) for p in ENV_FILES if not p.exists()]
    if missing:
        print("Missing required .env files:")
        for item in missing:
            print(f"- {item}")
        return 1

    current = {path: parse_env_values(path) for path in ENV_FILES}
    updates = compute_updates(current)
    removals = {
        ROOT / "regional/.env": [
            key for key in DEPRECATED_COMPONENT_CERT_KEYS if key in current[ROOT / "regional/.env"]
        ],
        ROOT / "central/.env": [
            key for key in DEPRECATED_COMPONENT_CERT_KEYS if key in current[ROOT / "central/.env"]
        ],
    }
    summary = build_summary(current, updates, removals)
    print_summary(summary)

    if not summary:
        return 0

    confirm = input("Save these changes to .env files? Type 'yes' to continue: ").strip().lower()
    if confirm != "yes":
        raise UserAbort("No files were modified.")

    changed_paths = set(summary.keys())
    for path in changed_paths:
        apply_updates(path, updates.get(path, {}), set(removals.get(path, [])))

    print("\nSaved updates to:")
    for path in ENV_FILES:
        if path in changed_paths:
            print(f"- {path.relative_to(ROOT)}")

    print("\nNext steps:")
    print("1. Review values if needed.")
    print("2. Run ./scripts/ssl.sh to regenerate certificates if cert metadata changed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. No files were modified.")
        raise SystemExit(130)
    except UserAbort as exc:
        print(f"\n{exc}")
        raise SystemExit(0)
