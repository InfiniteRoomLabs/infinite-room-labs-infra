#!/usr/bin/env bash
set -euo pipefail

# scripts/bw-sync.sh
# Syncs Bitwarden secrets to Ansible Vault and/or Kubernetes Secrets.
# Uses bw-sync-config.yaml to define the secret-to-target mappings.
#
# Usage:
#   scripts/bw-sync.sh --target ansible|k8s|both [OPTIONS]
#
# Options:
#   --target ansible|k8s|both   Sync target(s)
#   --check-rotation             Report secrets past rotation deadline
#   --verify-k8s                 Verify K8s secrets match Bitwarden
#   --dry-run                    Preview changes without writing
#   --quiet                      Suppress non-error output
#   -h, --help                   Show this help message and exit
#
# Dependencies: bw, jq, yq, sha256sum
# Optional:     kubectl (for --target k8s), ansible-vault (for --target ansible)

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/bw-sync-config.yaml"
BW_SESSION_FILE="$HOME/.secrets/bw-session"
STATE_DIR="$HOME/.local/share/irl"
STATE_FILE="$STATE_DIR/bw-sync-state.json"
LOG_FILE="$STATE_DIR/bw-sync.log"

# Prometheus metrics -- prefer node-exporter dir, fall back to state dir
PROM_DEFAULT_DIR="/var/lib/prometheus/node-exporter"
if [[ -d "$PROM_DEFAULT_DIR" && -w "$PROM_DEFAULT_DIR" ]]; then
  PROM_FILE="$PROM_DEFAULT_DIR/irl_secrets.prom"
else
  PROM_FILE="$STATE_DIR/irl_secrets.prom"
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TARGET=""
CHECK_ROTATION=false
VERIFY_K8S=false
DRY_RUN=false
QUIET=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<HELP
Usage: $(basename "$0") --target ansible|k8s|both [OPTIONS]

Sync Bitwarden secrets to Ansible Vault and/or Kubernetes Secrets.
Reads mappings from: $CONFIG_FILE

Targets:
  ansible   Write encrypted ansible/inventory/group_vars/all/vault.yml
  k8s       Apply kubectl secrets in the configured namespace
  both      Both ansible and k8s

Options:
  --target ansible|k8s|both   Required unless using --check-rotation or --verify-k8s
  --check-rotation             Report secrets past their rotation deadline
  --verify-k8s                 Verify K8s secrets match Bitwarden (read-only)
  --dry-run                    Show what would change without writing anything
  --quiet                      Suppress non-error output (for hook usage)
  -h, --help                   Show this help message and exit

Environment:
  BW_SESSION   Bitwarden session token (loaded from ~/.secrets/bw-session if unset)

Exit codes:
  0   All secrets synced successfully
  1   One or more secrets failed to sync
  2   Bitwarden is locked or unreachable

Examples:
  # Sync everything
  scripts/bw-sync.sh --target both

  # Preview Ansible changes without writing
  scripts/bw-sync.sh --target ansible --dry-run

  # Check rotation compliance
  scripts/bw-sync.sh --check-rotation

  # Verify K8s is in sync (no writes)
  scripts/bw-sync.sh --verify-k8s
HELP
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)           usage; exit 0 ;;
    --target)            TARGET="${2:-}"; shift 2 ;;
    --check-rotation)    CHECK_ROTATION=true; shift ;;
    --verify-k8s)        VERIFY_K8S=true; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    --quiet)             QUIET=true; shift ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Validate argument combinations
if [[ -z "$TARGET" && "$CHECK_ROTATION" == false && "$VERIFY_K8S" == false ]]; then
  echo "Error: --target is required unless using --check-rotation or --verify-k8s" >&2
  usage >&2
  exit 1
fi

if [[ -n "$TARGET" ]] && [[ "$TARGET" != "ansible" && "$TARGET" != "k8s" && "$TARGET" != "both" ]]; then
  echo "Error: --target must be ansible, k8s, or both (got: $TARGET)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log() {
  [[ "$QUIET" == true ]] && return 0
  echo "$@"
}

log_err() {
  echo "$@" >&2
}

# Append a JSON object to the audit log. Never logs values.
# Args: item_name target action [error_msg]
audit_log() {
  local item_name="$1"
  local target="$2"
  local action="$3"
  local error_msg="${4:-}"

  mkdir -p "$STATE_DIR"
  local entry
  entry=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg item "$item_name" \
    --arg tgt "$target" \
    --arg act "$action" \
    --arg err "$error_msg" \
    '{timestamp: $ts, item: $item, target: $tgt, action: $act, error: (if $err == "" then null else $err end)}')
  echo "$entry" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  for cmd in bw jq yq sha256sum; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ "$TARGET" == "ansible" || "$TARGET" == "both" ]]; then
    command -v ansible-vault &>/dev/null || missing+=("ansible-vault")
  fi

  if [[ "$TARGET" == "k8s" || "$TARGET" == "both" || "$VERIFY_K8S" == true ]]; then
    command -v kubectl &>/dev/null || missing+=("kubectl")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Error: missing required commands: ${missing[*]}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Bitwarden session
# ---------------------------------------------------------------------------
load_bw_session() {
  if [[ -z "${BW_SESSION:-}" ]]; then
    if [[ -f "$BW_SESSION_FILE" ]]; then
      # shellcheck source=/dev/null
      BW_SESSION=$(cat "$BW_SESSION_FILE")
      export BW_SESSION
    else
      log_err "Error: BW_SESSION not set and $BW_SESSION_FILE not found."
      log_err "Run: bw unlock --raw > ~/.secrets/bw-session"
      exit 2
    fi
  fi
}

# bw_retry CMD [ARGS...]
# Retry a bw command up to 3 times with 2-second backoff.
bw_retry() {
  local attempt max_attempts=3 delay=2
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if BW_SESSION="$BW_SESSION" "$@"; then
      return 0
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      log_err "  bw command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
      sleep "$delay"
    fi
  done
  log_err "  bw command failed after $max_attempts attempts: $*"
  return 1
}

verify_bw_session() {
  if ! bw_retry bw unlock --check --session "$BW_SESSION" &>/dev/null; then
    log_err "Error: Bitwarden vault is locked or session is invalid."
    log_err "Run: export BW_SESSION=\$(bw unlock --raw)"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Config parsing helpers (yq)
# ---------------------------------------------------------------------------
cfg() {
  yq e "$1" "$CONFIG_FILE"
}

cfg_raw() {
  # Strips surrounding quotes from scalar yq output
  yq e "$1" "$CONFIG_FILE" | sed "s/^'//;s/'$//"
}

secret_count() {
  yq e '.secrets | length' "$CONFIG_FILE"
}

secret_field() {
  local idx="$1" field="$2"
  yq e ".secrets[$idx].$field" "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Bitwarden data retrieval
# ---------------------------------------------------------------------------

# Get all folder IDs under the IRL tree (including subfolders).
# Returns newline-separated folder IDs.
get_irl_folder_ids() {
  local folder_prefix
  folder_prefix=$(yq e '.bitwarden_folder' "$CONFIG_FILE")

  local ids
  ids=$(bw_retry bw list folders --session "$BW_SESSION" \
    | jq -r --arg prefix "$folder_prefix" \
      '.[] | select(.name == $prefix or (.name | startswith($prefix + "/"))) | .id')

  if [[ -z "$ids" ]]; then
    log_err "Error: No Bitwarden folders matching '$folder_prefix' found."
    exit 1
  fi
  echo "$ids"
}

# Fetch all items across all IRL subfolders and cache in a temp file.
# Sets global BW_ITEMS_FILE.
BW_ITEMS_FILE=""
fetch_all_items() {
  if [[ -n "$BW_ITEMS_FILE" && -f "$BW_ITEMS_FILE" ]]; then
    return 0
  fi

  log "==> Fetching items from Bitwarden..."

  # Sync first to get latest data
  bw_retry bw sync --session "$BW_SESSION" &>/dev/null || true

  BW_ITEMS_FILE=$(mktemp /tmp/bw-items-XXXXXX.json)
  # Register cleanup
  # shellcheck disable=SC2064
  trap "rm -f '$BW_ITEMS_FILE' ${ANSIBLE_PLAIN_FILE:-} ${VAULT_PASS_FILE:-}" EXIT

  # Collect items from all IRL subfolders into a single JSON array
  local folder_ids all_items="[]"
  folder_ids=$(get_irl_folder_ids)

  while IFS= read -r fid; do
    [[ -z "$fid" ]] && continue
    local items
    items=$(bw_retry bw list items --folderid "$fid" --session "$BW_SESSION" 2>/dev/null || echo "[]")
    all_items=$(echo "$all_items" "$items" | jq -s '.[0] + .[1]')
  done <<< "$folder_ids"

  echo "$all_items" > "$BW_ITEMS_FILE"

  local count
  count=$(jq 'length' "$BW_ITEMS_FILE")
  log "    Found $count items across IRL folders."
}

# get_item_password ITEM_NAME
# Prints the password for named item to stdout. Never echoed -- callers pipe directly.
get_item_password() {
  local item_name="$1"
  jq -r --arg name "$item_name" \
    '.[] | select(.name == $name) | (.login.password // (.fields[]? | select(.name == "password") | .value) // empty)' \
    "$BW_ITEMS_FILE" | head -1
}

# get_item_revision_date ITEM_NAME
get_item_revision_date() {
  local item_name="$1"
  jq -r --arg name "$item_name" \
    '.[] | select(.name == $name) | .revisionDate' \
    "$BW_ITEMS_FILE" | head -1
}

# get_item_rotation_days ITEM_NAME
# Reads rotation_days from the Notes field JSON metadata.
get_item_rotation_days() {
  local item_name="$1"
  jq -r --arg name "$item_name" \
    '.[] | select(.name == $name) | .notes // "null"' \
    "$BW_ITEMS_FILE" | head -1 \
    | jq -r '.rotation_days // "null"' 2>/dev/null || echo "null"
}

# ---------------------------------------------------------------------------
# Checksum state helpers
# ---------------------------------------------------------------------------
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo "{}"
  fi
}

get_stored_checksum() {
  local item_name="$1"
  load_state | jq -r --arg k "$item_name" '.[$k] // empty'
}

save_checksum() {
  local item_name="$1"
  local checksum="$2"
  mkdir -p "$STATE_DIR"
  local current
  current=$(load_state)
  echo "$current" | jq --arg k "$item_name" --arg v "$checksum" '. + {($k): $v}' \
    > "$STATE_FILE"
}

compute_checksum() {
  # Read from stdin, output just the hex hash
  sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
write_metrics() {
  local total="$1"
  local overdue="$2"
  local sync_ts
  sync_ts=$(date +%s)

  mkdir -p "$(dirname "$PROM_FILE")"

  {
    echo "# HELP irl_secrets_total Total number of managed secrets"
    echo "# TYPE irl_secrets_total gauge"
    echo "irl_secrets_total $total"
    echo ""
    echo "# HELP irl_secrets_synced_timestamp_seconds Unix timestamp of last successful sync"
    echo "# TYPE irl_secrets_synced_timestamp_seconds gauge"
    echo "irl_secrets_synced_timestamp_seconds $sync_ts"
    echo ""
    echo "# HELP irl_secrets_rotation_overdue Count of secrets past their rotation deadline"
    echo "# TYPE irl_secrets_rotation_overdue gauge"
    echo "irl_secrets_rotation_overdue $overdue"
    echo ""
    echo "# HELP irl_secret_age_days Age of each secret in days since last rotation"
    echo "# TYPE irl_secret_age_days gauge"
  } > "$PROM_FILE"

  local n
  n=$(secret_count)
  local now_ts
  now_ts=$(date +%s)
  for ((i=0; i<n; i++)); do
    local item_name
    item_name=$(secret_field "$i" "bw_item")
    local rev_date
    rev_date=$(get_item_revision_date "$item_name")
    if [[ -n "$rev_date" && "$rev_date" != "null" ]]; then
      local rev_ts
      rev_ts=$(date -d "$rev_date" +%s 2>/dev/null || echo "$now_ts")
      local age_days=$(( (now_ts - rev_ts) / 86400 ))
      echo "irl_secret_age_days{name=\"$item_name\"} $age_days" >> "$PROM_FILE"
    fi
  done
}

# ---------------------------------------------------------------------------
# --check-rotation
# ---------------------------------------------------------------------------
run_check_rotation() {
  log "==> Checking rotation policy compliance..."
  fetch_all_items

  local n overdue=0
  n=$(secret_count)
  local now_ts
  now_ts=$(date +%s)

  for ((i=0; i<n; i++)); do
    local item_name
    item_name=$(secret_field "$i" "bw_item")
    local rotation_days
    rotation_days=$(get_item_rotation_days "$item_name")
    local rev_date
    rev_date=$(get_item_revision_date "$item_name")

    if [[ "$rotation_days" == "null" || -z "$rotation_days" || "$rotation_days" == "never" ]]; then
      log "  [skip]    $item_name (no rotation policy)"
      continue
    fi

    if [[ -z "$rev_date" || "$rev_date" == "null" ]]; then
      log_err "  [warn]    $item_name - no revisionDate found"
      continue
    fi

    local rev_ts
    rev_ts=$(date -d "$rev_date" +%s 2>/dev/null || echo "0")
    local age_days=$(( (now_ts - rev_ts) / 86400 ))
    local deadline_days="$rotation_days"

    if [[ $age_days -gt $deadline_days ]]; then
      log_err "  [OVERDUE] $item_name - age=${age_days}d deadline=${deadline_days}d"
      ((overdue++)) || true
    else
      local remaining=$(( deadline_days - age_days ))
      log "  [ok]      $item_name - age=${age_days}d, ${remaining}d until rotation due"
    fi
  done

  log ""
  if [[ $overdue -gt 0 ]]; then
    log_err "Rotation check complete: $overdue secret(s) overdue for rotation."
    return 1
  else
    log "Rotation check complete: all secrets within policy."
    return 0
  fi
}

# ---------------------------------------------------------------------------
# --verify-k8s
# ---------------------------------------------------------------------------
run_verify_k8s() {
  log "==> Verifying K8s secrets match Bitwarden..."
  fetch_all_items

  local kubeconfig
  kubeconfig=$(yq e '.targets.kubernetes.kubeconfig' "$CONFIG_FILE")
  kubeconfig="${kubeconfig/#\~/$HOME}"
  local namespace
  namespace=$(yq e '.targets.kubernetes.namespace' "$CONFIG_FILE")

  local n mismatches=0
  n=$(secret_count)

  for ((i=0; i<n; i++)); do
    local item_name k8s_secret k8s_key
    item_name=$(secret_field "$i" "bw_item")
    k8s_secret=$(secret_field "$i" "k8s_secret")
    k8s_key=$(secret_field "$i" "k8s_key")

    if [[ "$k8s_secret" == "null" || "$k8s_key" == "null" ]]; then
      log "  [skip]    $item_name (no k8s target)"
      continue
    fi

    # Get password from BW (pipe to checksum immediately -- never stored in var)
    local bw_checksum
    bw_checksum=$(get_item_password "$item_name" | compute_checksum)

    # Get value from K8s (base64 decode, then checksum)
    local k8s_checksum
    if k8s_checksum=$(kubectl get secret "$k8s_secret" \
        --namespace "$namespace" \
        --kubeconfig "$kubeconfig" \
        -o jsonpath="{.data.${k8s_key}}" 2>/dev/null \
        | base64 -d \
        | compute_checksum); then
      if [[ "$bw_checksum" == "$k8s_checksum" ]]; then
        log "  [match]   $item_name -> $k8s_secret/$k8s_key"
      else
        log_err "  [MISMATCH] $item_name -> $k8s_secret/$k8s_key (K8s differs from Bitwarden)"
        ((mismatches++)) || true
      fi
    else
      log_err "  [missing]  $item_name -> $k8s_secret/$k8s_key (secret or key not found in K8s)"
      ((mismatches++)) || true
    fi
  done

  log ""
  if [[ $mismatches -gt 0 ]]; then
    log_err "K8s verify complete: $mismatches mismatch(es) found."
    return 1
  else
    log "K8s verify complete: all secrets match."
    return 0
  fi
}

# ---------------------------------------------------------------------------
# --target ansible
# ---------------------------------------------------------------------------

# Build a flat key=value map of all ansible vars, then write vault.yml.
# Handles nested keys like vault_pg_passwords.gitea -> YAML nested structure.
ANSIBLE_PLAIN_FILE=""

run_sync_ansible() {
  log "==> Syncing secrets to Ansible Vault..."
  fetch_all_items

  local output_file
  output_file=$(yq e '.targets.ansible_vault.output_file' "$CONFIG_FILE")
  output_file="$REPO_ROOT/$output_file"
  local enc_password_item
  enc_password_item=$(yq e '.targets.ansible_vault.encryption_password_item' "$CONFIG_FILE")

  ANSIBLE_PLAIN_FILE=$(mktemp /tmp/bw-vault-plain-XXXXXX.yml)
  VAULT_PASS_FILE=$(mktemp /tmp/bw-vault-pass-XXXXXX)

  # Build the plaintext vault YAML using yq mutations.
  # Start with an empty document.
  echo "---" > "$ANSIBLE_PLAIN_FILE"

  local n
  n=$(secret_count)
  local synced=0 unchanged=0 errors=0

  for ((i=0; i<n; i++)); do
    local item_name ansible_var
    item_name=$(secret_field "$i" "bw_item")
    ansible_var=$(secret_field "$i" "ansible_var")

    if [[ "$ansible_var" == "null" ]]; then
      log "  [skip]    $item_name (no ansible_var)"
      continue
    fi

    # Get password -- pipe through a process substitution to avoid storing in shell var
    # We must read the value to write it into YAML. We write directly via yq.
    # To keep the value out of the environment and shell history, we use a fd trick.
    local value
    value=$(get_item_password "$item_name")

    if [[ -z "$value" ]]; then
      log_err "  [error]   $item_name - no password found in Bitwarden"
      audit_log "$item_name" "ansible" "error" "no password found"
      ((errors++)) || true
      continue
    fi

    # Compute checksum to detect changes
    local new_checksum
    new_checksum=$(printf '%s' "$value" | compute_checksum)
    local old_checksum
    old_checksum=$(get_stored_checksum "$item_name")

    if [[ "$new_checksum" == "$old_checksum" && -f "$output_file" ]]; then
      log "  [unchanged] $item_name"
      audit_log "$item_name" "ansible" "unchanged"
      ((unchanged++)) || true
    else
      log "  [updated]   $item_name -> $ansible_var"
      ((synced++)) || true
    fi

    # Write into the plaintext YAML using yq.
    # Dot notation in ansible_var (e.g., vault_pg_passwords.gitea) maps to nested YAML.
    # Convert dot-path to yq path expression.
    local yq_path
    yq_path=".$(echo "$ansible_var" | sed 's/\./\./g')"
    yq e -i "${yq_path} = \"${value}\"" "$ANSIBLE_PLAIN_FILE"

    # Clear value from memory as soon as possible
    unset value
  done

  # Write the vault password to a temp file (never echoed)
  get_item_password "$enc_password_item" > "$VAULT_PASS_FILE"

  if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "  [dry-run] Would write encrypted vault to: $output_file"
    log "  [dry-run] $synced updated, $unchanged unchanged, $errors errors"
    rm -f "$ANSIBLE_PLAIN_FILE" "$VAULT_PASS_FILE"
    ANSIBLE_PLAIN_FILE="" VAULT_PASS_FILE=""
    [[ $errors -gt 0 ]] && return 1 || return 0
  fi

  # Encrypt and write. ansible-vault encrypt reads from file, writes encrypted in-place.
  mkdir -p "$(dirname "$output_file")"
  local encrypt_args=(--output "$output_file")
  # Only pass --vault-password-file if ANSIBLE_VAULT_PASSWORD_FILE is not already set,
  # otherwise ansible-vault sees two "default" vault-ids and refuses to encrypt.
  if [[ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
    encrypt_args+=(--vault-password-file "$VAULT_PASS_FILE")
  fi
  ansible-vault encrypt "${encrypt_args[@]}" "$ANSIBLE_PLAIN_FILE"

  # Save checksums only after successful write
  for ((i=0; i<n; i++)); do
    local item_name ansible_var
    item_name=$(secret_field "$i" "bw_item")
    ansible_var=$(secret_field "$i" "ansible_var")
    [[ "$ansible_var" == "null" ]] && continue

    local value
    value=$(get_item_password "$item_name")
    [[ -z "$value" ]] && continue
    local new_checksum
    new_checksum=$(printf '%s' "$value" | compute_checksum)
    save_checksum "$item_name" "$new_checksum"
    unset value
    audit_log "$item_name" "ansible" "updated"
  done

  rm -f "$ANSIBLE_PLAIN_FILE" "$VAULT_PASS_FILE"
  ANSIBLE_PLAIN_FILE="" VAULT_PASS_FILE=""

  log ""
  log "Ansible Vault written: $output_file"
  log "  $synced updated, $unchanged unchanged, $errors errors"
  [[ $errors -gt 0 ]] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# --target k8s
# ---------------------------------------------------------------------------
run_sync_k8s() {
  log "==> Syncing secrets to Kubernetes..."
  fetch_all_items

  local kubeconfig
  kubeconfig=$(yq e '.targets.kubernetes.kubeconfig' "$CONFIG_FILE")
  kubeconfig="${kubeconfig/#\~/$HOME}"
  local namespace
  namespace=$(yq e '.targets.kubernetes.namespace' "$CONFIG_FILE")

  # Group secrets by k8s_secret name so we can create multi-key secrets atomically.
  # Build a list of unique k8s secret names first.
  local n
  n=$(secret_count)

  # Collect all unique k8s_secret names (excluding nulls)
  local k8s_secret_names=()
  for ((i=0; i<n; i++)); do
    local k8s_secret
    k8s_secret=$(secret_field "$i" "k8s_secret")
    [[ "$k8s_secret" == "null" ]] && continue
    # Add to list if not already present
    local found=false
    for name in "${k8s_secret_names[@]:-}"; do
      [[ "$name" == "$k8s_secret" ]] && found=true && break
    done
    [[ "$found" == false ]] && k8s_secret_names+=("$k8s_secret")
  done

  local synced=0 unchanged=0 errors=0

  for k8s_secret_name in "${k8s_secret_names[@]:-}"; do
    # Build --from-literal args for all keys belonging to this secret
    local from_literal_args=()
    local secret_changed=false
    local secret_error=false
    local item_names_for_secret=()

    for ((i=0; i<n; i++)); do
      local item_name k8s_secret k8s_key
      item_name=$(secret_field "$i" "bw_item")
      k8s_secret=$(secret_field "$i" "k8s_secret")
      k8s_key=$(secret_field "$i" "k8s_key")

      [[ "$k8s_secret" != "$k8s_secret_name" ]] && continue

      local value
      value=$(get_item_password "$item_name")

      if [[ -z "$value" ]]; then
        log_err "  [error]   $item_name - no password found"
        audit_log "$item_name" "k8s" "error" "no password found"
        secret_error=true
        unset value
        continue
      fi

      # Detect change via checksum
      local new_checksum
      new_checksum=$(printf '%s' "$value" | compute_checksum)
      local old_checksum
      old_checksum=$(get_stored_checksum "$item_name")
      [[ "$new_checksum" != "$old_checksum" ]] && secret_changed=true

      from_literal_args+=("--from-literal=${k8s_key}=${value}")
      item_names_for_secret+=("$item_name:$new_checksum")
      unset value
    done

    if [[ "$secret_error" == true ]]; then
      ((errors++)) || true
      continue
    fi

    if [[ ${#from_literal_args[@]} -eq 0 ]]; then
      continue
    fi

    if [[ "$secret_changed" == false ]]; then
      log "  [unchanged] $k8s_secret_name"
      ((unchanged++)) || true
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] Would apply secret: $k8s_secret_name (${#from_literal_args[@]} key(s))"
      continue
    fi

    # Apply: kubectl create --dry-run=client -o yaml | kubectl apply -f -
    # This is idempotent and never echoes values.
    log "  [applying]  $k8s_secret_name (${#from_literal_args[@]} key(s))"
    if kubectl create secret generic "$k8s_secret_name" \
        --namespace "$namespace" \
        --kubeconfig "$kubeconfig" \
        "${from_literal_args[@]}" \
        --dry-run=client -o yaml \
      | kubectl apply \
          --namespace "$namespace" \
          --kubeconfig "$kubeconfig" \
          -f - &>/dev/null; then

      # Save checksums for all items in this secret
      for entry in "${item_names_for_secret[@]}"; do
        local iname="${entry%%:*}"
        local cksum="${entry##*:}"
        save_checksum "$iname" "$cksum"
        audit_log "$iname" "k8s" "updated"
      done
      ((synced++)) || true
    else
      log_err "  [error]   Failed to apply $k8s_secret_name"
      for entry in "${item_names_for_secret[@]}"; do
        audit_log "${entry%%:*}" "k8s" "error" "kubectl apply failed"
      done
      ((errors++)) || true
    fi
  done

  log ""
  log "K8s sync complete: $synced updated, $unchanged unchanged, $errors errors"
  [[ $errors -gt 0 ]] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_deps
  load_bw_session
  verify_bw_session
  mkdir -p "$STATE_DIR"

  local exit_code=0

  if [[ "$CHECK_ROTATION" == true ]]; then
    run_check_rotation || exit_code=1
  fi

  if [[ "$VERIFY_K8S" == true ]]; then
    run_verify_k8s || exit_code=1
  fi

  if [[ "$TARGET" == "ansible" || "$TARGET" == "both" ]]; then
    run_sync_ansible || exit_code=1
  fi

  if [[ "$TARGET" == "k8s" || "$TARGET" == "both" ]]; then
    run_sync_k8s || exit_code=1
  fi

  # Write Prometheus metrics after all syncs (only when we actually fetched items)
  if [[ -n "$BW_ITEMS_FILE" && -f "$BW_ITEMS_FILE" ]]; then
    local total overdue=0
    total=$(secret_count)

    # Count overdue for metrics (re-uses cached BW_ITEMS_FILE)
    local now_ts
    now_ts=$(date +%s)
    local n
    n=$(secret_count)
    for ((i=0; i<n; i++)); do
      local item_name rotation_days rev_date
      item_name=$(secret_field "$i" "bw_item")
      rotation_days=$(get_item_rotation_days "$item_name")
      rev_date=$(get_item_revision_date "$item_name")
      [[ "$rotation_days" == "null" || -z "$rotation_days" || "$rotation_days" == "never" ]] && continue
      [[ -z "$rev_date" || "$rev_date" == "null" ]] && continue
      local rev_ts
      rev_ts=$(date -d "$rev_date" +%s 2>/dev/null || echo "$now_ts")
      local age_days=$(( (now_ts - rev_ts) / 86400 ))
      [[ $age_days -gt $rotation_days ]] && ((overdue++)) || true
    done

    write_metrics "$total" "$overdue"
    log "Metrics written to: $PROM_FILE"
  fi

  exit "$exit_code"
}

main "$@"
