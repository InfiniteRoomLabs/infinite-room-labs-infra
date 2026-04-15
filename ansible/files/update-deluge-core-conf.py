#!/usr/bin/env python3
"""
Update Deluge core.conf settings surgically.

Preserves all keys not explicitly managed here. Emits "CHANGED" on stdout
if writes happened, "NOT_CHANGED" otherwise (used by ansible changed_when).

core.conf has Deluge's quirky dual-JSON format:
    {<metadata object>}{<config object>}

Settings to update come from environment variables, passed by the caller
(ansible.builtin.script environment block).

Required env vars:
    DELUGE_CORE_CONF       Absolute path to core.conf
    DELUGE_DAEMON_PORT     RPC daemon listen port (int)
    DELUGE_INCOMPLETE_DIR  Active downloads directory
    DELUGE_COMPLETE_DIR    Completed/moved torrents directory
    DELUGE_BT_PORT         BitTorrent peer listen port (int)
"""
import json
import os
import sys
from pathlib import Path


def main() -> int:
    path = Path(os.environ["DELUGE_CORE_CONF"])
    raw = path.read_text()

    first_end = raw.index("}") + 1
    header = raw[:first_end]
    config = json.loads(raw[first_end:])

    original = json.dumps(config, sort_keys=True)

    config["allow_remote"] = True
    config["daemon_port"] = int(os.environ["DELUGE_DAEMON_PORT"])
    config["download_location"] = os.environ["DELUGE_INCOMPLETE_DIR"]
    config["move_completed"] = True
    config["move_completed_path"] = os.environ["DELUGE_COMPLETE_DIR"]
    config["listen_ports"] = [int(os.environ["DELUGE_BT_PORT"])] * 2
    config["random_port"] = False

    if json.dumps(config, sort_keys=True) == original:
        print("NOT_CHANGED")
        return 0

    path.write_text(header + json.dumps(config, indent=4, sort_keys=True))
    print("CHANGED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
