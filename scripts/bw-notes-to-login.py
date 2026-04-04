# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6.0"]
# ///
"""Convert Bitwarden Secure Note items to Login items.

Reads bw-sync-config.yaml to find all managed secrets, checks which ones
are Secure Notes (type 2) with values stored in the notes field, and
converts them to Login items (type 1) with the value in login.password.

Phase 1: Fetch all items concurrently (reads are safe to parallelize).
Phase 2: Convert matching items sequentially (writes touch the local vault).

Requires: `bw` CLI installed and unlocked (check with `bw status`).

Usage:
    uv run scripts/bw-notes-to-login.py              # auto-detect from config
    uv run scripts/bw-notes-to-login.py --dry-run     # preview without changes
    uv run scripts/bw-notes-to-login.py --items foo bar  # specific items only
"""

import argparse
import asyncio
import base64
import json
import subprocess
import sys
from pathlib import Path

import yaml

BW_TYPE_LOGIN = 1
BW_TYPE_SECURE_NOTE = 2

CONFIG_PATH = Path(__file__).parent / "bw-sync-config.yaml"


async def bw_status() -> dict:
    proc = await asyncio.create_subprocess_exec(
        "bw", "status",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError("bw status failed")
    return json.loads(stdout)


async def bw_get_item(name: str) -> tuple[str, dict | None]:
    """Fetch a single item by exact name match.

    Uses `bw list` + filter instead of `bw get item` to avoid ambiguity
    errors when one item name is a prefix of another (e.g. pg-vault vs
    pg-vaultwarden).
    """
    proc = await asyncio.create_subprocess_exec(
        "bw", "list", "items", "--search", name,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    if proc.returncode != 0:
        return name, None
    items = json.loads(stdout)
    exact = [i for i in items if i["name"] == name]
    if len(exact) == 1:
        return name, exact[0]
    if len(exact) > 1:
        # Multiple items with the same exact name -- pick the one in an IRL folder
        for i in exact:
            if i.get("folderId"):
                return name, i
    return name, exact[0] if exact else None


def bw_create_item_sync(item_data: dict) -> dict:
    """Create a new item. Returns the created item."""
    encoded = base64.b64encode(json.dumps(item_data).encode()).decode()
    result = subprocess.run(
        ["bw", "create", "item", encoded],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def bw_delete_item_sync(item_id: str) -> None:
    """Permanently delete an item by ID."""
    subprocess.run(
        ["bw", "delete", "item", item_id],
        capture_output=True, text=True, check=True,
    )


def get_managed_item_names() -> list[str]:
    with open(CONFIG_PATH) as f:
        config = yaml.safe_load(f)
    return [s["bw_item"] for s in config.get("secrets", [])]


def swap_note_to_login(item: dict, *, dry_run: bool = False) -> bool:
    """Convert a Secure Note to a Login via safe three-step swap.

    1. Create {name}-tmp as a Login with the secret in login.password
    2. Verify the tmp item has the correct password, then delete the original
    3. Rename {name}-tmp back to {name}
    """
    name = item["name"]
    tmp_name = f"{name}-tmp"
    secret = item["notes"]

    if dry_run:
        print(f"  [would convert] {name}")
        return True

    # Step 1: create tmp Login item
    new_item = {
        "type": BW_TYPE_LOGIN,
        "name": tmp_name,
        "folderId": item.get("folderId"),
        "login": {"password": secret},
        "notes": None,
        "favorite": False,
        "fields": [],
        "reprompt": 0,
    }
    print(f"  [step 1/3]   {name}: creating {tmp_name}...")
    created = bw_create_item_sync(new_item)
    created_id = created["id"]

    # Step 2: verify tmp has the right password, then delete original
    verify = subprocess.run(
        ["bw", "get", "item", created_id],
        capture_output=True, text=True, check=True,
    )
    verified = json.loads(verify.stdout)
    if verified.get("login", {}).get("password") != secret:
        print(f"  [error]      {name}: tmp item password mismatch, aborting (tmp left in place)")
        return False

    print(f"  [step 2/3]   {name}: verified, deleting original...")
    bw_delete_item_sync(item["id"])

    # Step 3: rename tmp -> original name
    verified["name"] = name
    encoded = base64.b64encode(json.dumps(verified).encode()).decode()
    subprocess.run(
        ["bw", "edit", "item", created_id, encoded],
        capture_output=True, text=True, check=True,
    )
    print(f"  [step 3/3]   {name}: renamed, done")
    return True


async def main():
    parser = argparse.ArgumentParser(
        description="Convert BW Secure Notes to Login items for bw-sync compatibility."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be converted without making changes.",
    )
    parser.add_argument(
        "--items",
        nargs="+",
        metavar="NAME",
        help="Convert only these items (default: all from bw-sync-config.yaml).",
    )
    args = parser.parse_args()

    status = await bw_status()
    if status.get("status") != "unlocked":
        print(f"Error: Bitwarden vault is {status.get('status')}. Run `bw unlock` first.", file=sys.stderr)
        sys.exit(1)

    item_names = args.items or get_managed_item_names()

    # -- Phase 1: fetch all items concurrently --
    print(f"Fetching {len(item_names)} items...")
    results = await asyncio.gather(*(bw_get_item(name) for name in item_names))

    # -- Phase 2: convert sequentially --
    to_convert: list[dict] = []
    skipped = 0
    errors = 0

    for name, item in results:
        if item is None:
            print(f"  [not found]  {name}")
            errors += 1
            continue

        if item["type"] != BW_TYPE_SECURE_NOTE:
            print(f"  [skip]       {name} (already type={item['type']})")
            skipped += 1
            continue

        if not item.get("notes"):
            print(f"  [skip]       {name} (secure note but notes field is empty)")
            skipped += 1
            continue

        to_convert.append(item)

    converted = 0
    for item in to_convert:
        try:
            if swap_note_to_login(item, dry_run=args.dry_run):
                converted += 1
            else:
                errors += 1
        except subprocess.CalledProcessError as e:
            print(f"  [error]      {item['name']}: {e.stderr.strip()}", file=sys.stderr)
            errors += 1

    prefix = "[dry-run] " if args.dry_run else ""
    print(f"\n{prefix}{converted} converted, {skipped} skipped, {errors} errors")

    if errors > 0:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
