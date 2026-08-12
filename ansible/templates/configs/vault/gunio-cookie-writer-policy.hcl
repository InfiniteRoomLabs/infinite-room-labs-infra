# gunio-cookie-writer -- least-privilege WRITE-ONLY policy for the laptop's
# weekly cookie-refresh timer (playbooks/laptop.yml). It may overwrite the
# gun.io session cookie at exactly one path and can read nothing back, so a
# stolen laptop credential can annoy (replace the cookie) but never exfil one.
#
# KV v2: `vault kv put irl/gunio-mcp/app ...` writes to irl/data/gunio-mcp/app.
# No `read`, no `list`, no metadata, no other path. Separate from the ESO
# read policy (eso-gunio-mcp) on purpose -- different consumer, different verb.
path "irl/data/gunio-mcp/app" {
  capabilities = ["create", "update"]
}
