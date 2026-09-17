#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE flag "-n --namespace <ns>" help="Namespace of the wotlk release" default="irl"
#USAGE flag "--deploy <name>" help="Worldserver Deployment name" default="wotlk-worldserver"

# scripts/wotlk-console.sh
# Drops you onto the AzerothCore worldserver console (the `AC>` prompt),
# the k8s equivalent of `docker attach ac-worldserver` in dads-mmo-lab.
#
# Safety: `kubectl attach` forwards Ctrl-C straight into the container, where
# the worldserver treats it as "shut down the world". This wrapper swallows
# Ctrl-C / Ctrl-\ and uses Ctrl-] to detach instead. Detaching never stops
# the server.
#
# First-run recipe (from the dads-mmo-lab guide):
#   account create <user> <password>
#   account set gmlevel <user> 3 -1
#   server info

exec python3 - "$usage_namespace" "$usage_deploy" <<'PY'
import os, pty, sys

ns, dep = sys.argv[1], sys.argv[2]
DETACH = b"\x1d"                 # Ctrl-]
SWALLOW = (b"\x03", b"\x1c")     # Ctrl-C, Ctrl-\

def stdin_read(fd):
    data = os.read(fd, 1024)
    if DETACH in data:
        sys.stdout.write("\r\n[detached -- worldserver keeps running]\r\n")
        sys.stdout.flush()
        os._exit(0)
    for b in SWALLOW:
        data = data.replace(b, b"")
    return data

print("Attaching to worldserver console. Press Enter for the AC> prompt.")
print("Ctrl-] detaches. Ctrl-C is swallowed here (it would shut the world down).")
sys.stdout.flush()
pty.spawn(["kubectl", "attach", "-n", ns, "-it", f"deploy/{dep}", "-c", "worldserver"],
          stdin_read=stdin_read)
PY
