#!/bin/bash
set -euo pipefail

# add-profiles.sh — enable per-group routing profiles (split tunnel) on an
# ocserv server that was deployed before this feature existed.
#
# Idempotent: safe to run repeatedly. It only adds what is missing —
#   1. cert-group-oid + config-per-group directives in ocserv.conf
#   2. the /etc/ocserv/config-per-group/ directory
#   3. any routing profiles passed via --group-routes
#   4. the updated ocserv-user tool (so add-cert --group works), if available
# then restarts ocserv (the new directives are parse-time). Existing users keep
# the full tunnel until you re-issue their cert with --group.

# --- Paths ---
OCSERV_CONF_DIR="/etc/ocserv"
OCSERV_CONF="${OCSERV_CONF_DIR}/ocserv.conf"
GROUP_DIR="${OCSERV_CONF_DIR}/config-per-group"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Options ---
GROUP_ROUTES=()
DO_RESTART=1
VERBOSE=0

# --- State (set as we go) ---
WORK=""
CONF_CHANGED=0
CONF_BAK=""
PROFILES_CHANGED=0

# --- Logging ---
log()     { echo "==> $*"; }
verbose() { (( VERBOSE )) && echo "    $*" || true; }
die()     { echo "ERROR: $*" >&2; exit 1; }
warn()    { echo "WARNING: $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Enable per-group routing profiles (split tunnel) on an already-deployed ocserv.
Idempotent: only adds what is missing.

Options:
  --group-routes <n>:<f> Create/replace split-tunnel profile <n> from file <f>
                         (CIDRs one per line; # comments allowed). Repeatable.
                         May be omitted to just enable the mechanism.
  --no-restart           Make the changes but do not restart ocserv (apply
                         later with: systemctl restart ocserv).
  -v, --verbose          Show detailed output.
  -h, --help             Show this help.

Examples:
  # Enable the mechanism and create a 'split' profile, then restart:
  sudo $0 --group-routes split:./split-nets.txt

  # Just enable per-group config without creating any profile yet:
  sudo $0

After this, issue users into a profile with:
  ocserv-user add-cert <username> --group <profile>
EOF
    exit 0
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --group-routes) GROUP_ROUTES+=("$2"); shift 2 ;;
        --no-restart)   DO_RESTART=0;         shift ;;
        -v|--verbose)   VERBOSE=1;            shift ;;
        -h|--help)      usage ;;
        *) die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# --- CIDR helpers (mirrors deploy.sh) ---
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octs <<< "$ip"
    for o in "${octs[@]}"; do (( o <= 255 )) || return 1; done
    return 0
}

validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local prefix="${cidr##*/}"
    (( prefix <= 32 )) || return 1
    validate_ip "${cidr%%/*}"
}

cidr_to_mask() {
    local prefix="$1" mask="" full=$(( prefix / 8 )) rem=$(( prefix % 8 ))
    for (( i=0; i<4; i++ )); do
        local octet
        if   (( i < full ));  then octet=255
        elif (( i == full )); then octet=$(( 256 - (1 << (8 - rem)) ))
        else                       octet=0
        fi
        mask="${mask}${octet}"
        (( i < 3 )) && mask="${mask}."
    done
    echo "$mask"
}

cidr_to_ocserv() {
    local cidr="$1"
    local net="${cidr%%/*}" prefix="${cidr##*/}"
    echo "${net}/$(cidr_to_mask "$prefix")"
}

ocserv_supports_test() {
    ocserv --help 2>&1 | grep -qE -- '--test-config|[[:space:]]-t[[:space:],]'
}

# --- Preflight ---
preflight() {
    [[ $EUID -eq 0 ]] || die "Must be run as root (try: sudo $0)"
    command -v ocserv &>/dev/null || die "ocserv binary not found; is ocserv installed?"
    [ -f "$OCSERV_CONF" ] || die "$OCSERV_CONF not found. For a fresh install run deploy.sh instead."

    for spec in "${GROUP_ROUTES[@]}"; do
        [[ "$spec" == *:* ]] || die "--group-routes must be NAME:FILE (got '$spec')"
        local gname="${spec%%:*}" gfile="${spec#*:}"
        [[ "$gname" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid group name '$gname' (allowed: a-z A-Z 0-9 . _ -)"
        [ -n "$gfile" ] || die "--group-routes '$spec' has an empty file path"
        [ -f "$gfile" ] || die "group-routes file not found: $gfile"
        local lineno=0 has_route=0
        while IFS= read -r line; do
            (( lineno++ ))
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            line="${line%%#*}"; line="${line// /}"
            [ -z "$line" ] && continue
            validate_cidr "$line" || die "$gfile line $lineno: invalid CIDR '$line'"
            has_route=1
        done < "$gfile"
        (( has_route )) || die "group-routes file '$gfile' (group '$gname') contains no networks"
    done
}

# --- Stage ocserv.conf directive changes on a temp copy ---
stage_directives() {
    WORK=$(mktemp)
    cp "$OCSERV_CONF" "$WORK"
    local before after
    before=$(cksum "$WORK" | awk '{print $1}')

    # cert-group-oid (group from certificate OU) — parse-time, above SIGHUP
    if grep -qE '^[[:space:]]*cert-group-oid' "$WORK"; then
        verbose "cert-group-oid already present"
    else
        if grep -qE '^[[:space:]]*cert-user-oid' "$WORK"; then
            sed -i '/^[[:space:]]*cert-user-oid/a cert-group-oid = 2.5.4.11' "$WORK"
        elif grep -q 'reloaded on a SIGHUP' "$WORK"; then
            sed -i '/reloaded on a SIGHUP/i cert-group-oid = 2.5.4.11' "$WORK"
        else
            printf '\ncert-group-oid = 2.5.4.11\n' >> "$WORK"
        fi
        log "Added cert-group-oid = 2.5.4.11 (routing profile taken from cert OU)"
    fi

    # config-per-group directory
    if grep -qE '^[[:space:]]*config-per-group' "$WORK"; then
        verbose "config-per-group already present"
    else
        if grep -qE '^[[:space:]]*route[[:space:]]*=[[:space:]]*default' "$WORK"; then
            sed -i '/^[[:space:]]*route[[:space:]]*=[[:space:]]*default/i config-per-group = '"${GROUP_DIR}"'/' "$WORK"
        else
            printf '\nconfig-per-group = %s/\n' "$GROUP_DIR" >> "$WORK"
        fi
        log "Added config-per-group = ${GROUP_DIR}/"
    fi

    after=$(cksum "$WORK" | awk '{print $1}')
    [ "$before" != "$after" ] && CONF_CHANGED=1 || true
}

# --- Validate and commit the staged config ---
commit_directives() {
    if (( ! CONF_CHANGED )); then
        verbose "ocserv.conf already has the required directives; leaving it unchanged"
        rm -f "$WORK"
        return
    fi

    if ocserv_supports_test; then
        local out
        if ! out=$(ocserv -t -c "$WORK" 2>&1); then
            echo "$out" >&2
            rm -f "$WORK"
            die "Config test failed; no changes applied to $OCSERV_CONF."
        fi
        verbose "ocserv config test passed on staged file"
    fi

    CONF_BAK="${OCSERV_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$OCSERV_CONF" "$CONF_BAK"
    log "Backed up existing config to $CONF_BAK"

    chmod --reference="$OCSERV_CONF" "$WORK" 2>/dev/null || chmod 640 "$WORK"
    chown --reference="$OCSERV_CONF" "$WORK" 2>/dev/null || true
    mv "$WORK" "$OCSERV_CONF"
}

# --- Ensure the profile directory exists (so the directive is always valid) ---
ensure_group_dir() {
    mkdir -p "$GROUP_DIR"
    chmod 755 "$GROUP_DIR"
}

# --- Write requested routing profiles ---
write_profiles() {
    [ ${#GROUP_ROUTES[@]} -gt 0 ] || return 0
    log "Writing routing profiles"

    local spec name file
    for spec in "${GROUP_ROUTES[@]}"; do
        name="${spec%%:*}"
        file="${spec#*:}"

        local route_block=""
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            line="${line%%#*}"; line="${line// /}"
            [ -z "$line" ] && continue
            route_block+="route = $(cidr_to_ocserv "$line")"$'\n'
        done < "$file"

        local gfile="${GROUP_DIR}/${name}"
        if [ -f "$gfile" ]; then
            cp "$gfile" "${gfile}.bak.$(date +%Y%m%d%H%M%S)"
            verbose "Backed up existing profile to ${gfile}.bak.*"
        fi

        cat > "$gfile" <<EOF
# Routing profile '${name}' — managed by add-profiles.sh / deploy.sh
#
# Split tunnel: ONLY the networks listed below are routed through the VPN.
# All other client traffic uses the client's normal default route.
# Assign a user to this profile by issuing their certificate with:
#     ocserv-user add-cert <username> --group ${name}
#
# DNS is deliberately NOT forced through the tunnel here (split-tunnel intent);
# set this to true if you want client DNS to resolve via the VPN.
tunnel-all-dns = false

${route_block}
EOF
        chmod 644 "$gfile"
        PROFILES_CHANGED=1
        log "Wrote routing profile '${name}' (${gfile})"
    done
}

# --- Install the updated ocserv-user (needed for add-cert --group) ---
install_user_tool() {
    local src="${SCRIPT_DIR}/ocserv-user" dst="/usr/local/sbin/ocserv-user"

    if [ ! -f "$src" ]; then
        warn "ocserv-user not found next to this script; the add-cert --group flag needs the updated tool."
        warn "Copy the updated ocserv-user to this server, then: install -m 755 ocserv-user $dst"
        return
    fi
    if ! grep -q -- '--group)' "$src"; then
        warn "Local ocserv-user lacks --group support; not installing it."
        return
    fi
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        verbose "Installed ocserv-user is already up to date"
        return
    fi
    install -m 755 "$src" "$dst"
    log "Installed updated ocserv-user (supports --group) to $dst"
}

# --- Restart/reload, with rollback on a failed restart ---
journal_dump() {
    echo "Recent ocserv journal:" >&2
    journalctl -u ocserv -n 30 --no-pager >&2 || true
}

apply_changes() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^ocserv\.service'; then
        warn "ocserv systemd unit not found; restart ocserv manually to apply."
        return
    fi

    if (( ! DO_RESTART )); then
        log "Skipping service restart (--no-restart)."
        (( CONF_CHANGED )) && echo "    Apply the new directives with: systemctl restart ocserv"
        (( PROFILES_CHANGED && ! CONF_CHANGED )) && echo "    New connections pick up profiles; or: systemctl reload ocserv"
        return
    fi

    if ! systemctl is-active --quiet ocserv 2>/dev/null; then
        log "Starting ocserv"
        systemctl start ocserv || { journal_dump; die "ocserv failed to start"; }
    elif (( CONF_CHANGED )); then
        log "Restarting ocserv (new parse-time directives require a full restart)"
        if ! systemctl restart ocserv; then
            journal_dump
            if [ -n "$CONF_BAK" ] && [ -f "$CONF_BAK" ]; then
                warn "Restoring previous config from $CONF_BAK and restarting"
                cp "$CONF_BAK" "$OCSERV_CONF"
                systemctl restart ocserv || warn "Rollback restart also failed; investigate manually"
            fi
            die "Aborted after failed restart"
        fi
    elif (( PROFILES_CHANGED )); then
        log "Reloading ocserv (profile changes only)"
        systemctl reload ocserv
    else
        verbose "Nothing to apply to the running service"
    fi

    systemctl is-active --quiet ocserv || { journal_dump; die "ocserv is not active after apply"; }
}

print_summary() {
    echo
    echo "=========================================="
    echo "  Per-group routing profiles enabled"
    echo "=========================================="
    echo
    if [ ${#GROUP_ROUTES[@]} -gt 0 ]; then
        echo "  Profiles written:"
        for spec in "${GROUP_ROUTES[@]}"; do
            echo "      ${spec%%:*}  — ${GROUP_DIR}/${spec%%:*}"
        done
    else
        echo "  Mechanism enabled; no profiles created yet."
        echo "  Add one later: sudo $0 --group-routes <name>:<file>"
    fi
    echo
    echo "  Issue a user into a profile:"
    echo "      ocserv-user add-cert <username> --group <profile>"
    echo
    echo "  Existing users keep the full tunnel (cert OU=users). To move one to a"
    echo "  profile, re-issue their cert with --group (this revokes the old cert)."
    echo
}

# --- Main ---
preflight
stage_directives
commit_directives
ensure_group_dir
write_profiles
install_user_tool
apply_changes
print_summary
