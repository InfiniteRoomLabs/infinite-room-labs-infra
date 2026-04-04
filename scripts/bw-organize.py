# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Organize Bitwarden items in the IRL folder tree.

Creates missing folders and moves misplaced items into their proper
locations. Also renames items to fix ambiguity issues with `bw get item`.

Phase 1: Fetch all IRL items and folders concurrently.
Phase 2: Create missing folders sequentially.
Phase 3: Move/rename items sequentially.

Requires: `bw` CLI installed and unlocked (check with `bw status`).

Usage:
    uv run scripts/bw-organize.py              # apply changes
    uv run scripts/bw-organize.py --dry-run    # preview without changes
"""

import argparse
import asyncio
import base64
import json
import subprocess
import sys


# ── Desired folder structure ──────────────────────────────────────────
# Folders that must exist (created if missing).
REQUIRED_FOLDERS = [
    "IRL/Services/Vaultwarden",
    "IRL/Services/OpenViking",
    "IRL/Services/DockerHub",
    "IRL/Services/NPM",
    "IRL/Services/Twilio",
    "IRL/Infrastructure/Porkbun",
    "IRL/Infrastructure/Terraform",
]

# ── Move rules ────────────────────────────────────────────────────────
# Each rule: (item_name, current_folder, target_folder, new_name_or_None)
MOVE_RULES = [
    # IRL root -> proper subfolders
    ("pg-vaultwarden", "IRL", "IRL/Infrastructure/PostgreSQL", None),
    ("vaultwarden-admin-token", "IRL", "IRL/Services/Vaultwarden", None),
    ("docker-hub-pat", "IRL", "IRL/Services/DockerHub", None),
    ("npm-org-token", "IRL", "IRL/Services/NPM", None),
    ("porkbun-api-key", "IRL", "IRL/Infrastructure/Porkbun", None),
    ("porkbun-api-secret", "IRL", "IRL/Infrastructure/Porkbun", None),
    ("terraform-cloud-org-api", "IRL", "IRL/Infrastructure/Terraform", None),
    # IRL/Services root -> proper subfolders
    ("openviking-api-key", "IRL/Services", "IRL/Services/OpenViking", None),
    ("passwords.lab.infiniteroomlabs.cloud", "IRL/Services", "IRL/Services/Vaultwarden", None),
    # IRL/Services -> Twilio subfolder
    ("twilio.com", "IRL/Services", "IRL/Services/Twilio", None),
    # Rename to fix ambiguity with bw get item
    ("git.lab.infiniteroomlabs.cloud", "IRL/Services/Homepage", "IRL/Services/Homepage", "homepage-gitea-token"),
]


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


async def bw_list(object_type: str) -> list[dict]:
    proc = await asyncio.create_subprocess_exec(
        "bw", "list", object_type,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"bw list {object_type} failed")
    return json.loads(stdout)


def bw_create_folder(encoded: str) -> dict:
    result = subprocess.run(
        ["bw", "create", "folder", encoded],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def bw_edit_item(item_id: str, encoded: str) -> dict:
    result = subprocess.run(
        ["bw", "edit", "item", item_id, encoded],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def encode(data: dict) -> str:
    return base64.b64encode(json.dumps(data).encode()).decode()


async def main():
    parser = argparse.ArgumentParser(description="Organize BW items in the IRL folder tree.")
    parser.add_argument("--dry-run", action="store_true", help="Preview without changes.")
    args = parser.parse_args()

    status = await bw_status()
    if status.get("status") != "unlocked":
        print(f"Error: Bitwarden vault is {status.get('status')}. Run `bw unlock` first.", file=sys.stderr)
        sys.exit(1)

    # -- Phase 1: fetch folders and items concurrently --
    print("Fetching folders and items...")
    folders_list, items_list = await asyncio.gather(
        bw_list("folders"),
        bw_list("items"),
    )

    folder_by_name: dict[str, str] = {f["name"]: f["id"] for f in folders_list}
    folder_by_id: dict[str, str] = {f["id"]: f["name"] for f in folders_list}

    # -- Phase 2: create missing folders --
    print("\n-- Creating folders --")
    created_folders = 0
    for folder_name in REQUIRED_FOLDERS:
        if folder_name in folder_by_name:
            print(f"  [exists]  {folder_name}")
            continue
        if args.dry_run:
            print(f"  [would create]  {folder_name}")
            folder_by_name[folder_name] = f"dry-run-{folder_name}"
            created_folders += 1
            continue
        result = bw_create_folder(encode({"name": folder_name}))
        folder_by_name[result["name"]] = result["id"]
        folder_by_id[result["id"]] = result["name"]
        print(f"  [created]  {folder_name}")
        created_folders += 1

    # -- Phase 3: move/rename items --
    print("\n-- Moving items --")
    moved = 0
    errors = 0

    for item_name, current_folder, target_folder, new_name in MOVE_RULES:
        current_folder_id = folder_by_name.get(current_folder)
        matches = [
            i for i in items_list
            if i["name"] == item_name and i.get("folderId") == current_folder_id
        ]

        if not matches:
            print(f"  [not found]  {item_name} in {current_folder}")
            errors += 1
            continue

        if len(matches) > 1:
            print(f"  [ambiguous]  {item_name} in {current_folder} ({len(matches)} matches)")
            errors += 1
            continue

        item = matches[0]
        target_folder_id = folder_by_name.get(target_folder)
        if target_folder_id is None:
            print(f"  [error]  target folder {target_folder} not found (create it first?)")
            errors += 1
            continue

        changes = []
        if item.get("folderId") != target_folder_id:
            changes.append(f"move -> {target_folder}")
        if new_name and item["name"] != new_name:
            changes.append(f"rename -> {new_name}")

        if not changes:
            print(f"  [skip]  {item_name} (already correct)")
            continue

        desc = ", ".join(changes)
        if args.dry_run:
            print(f"  [would update]  {item_name}: {desc}")
            moved += 1
            continue

        item["folderId"] = target_folder_id
        if new_name:
            item["name"] = new_name

        try:
            bw_edit_item(item["id"], encode(item))
            print(f"  [done]  {item_name}: {desc}")
            moved += 1
        except subprocess.CalledProcessError as e:
            print(f"  [error]  {item_name}: {e.stderr.strip()}", file=sys.stderr)
            errors += 1

    prefix = "[dry-run] " if args.dry_run else ""
    print(f"\n{prefix}{created_folders} folders created, {moved} items moved/renamed, {errors} errors")

    if errors > 0:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
