#!/bin/bash
set -euo pipefail

# --- Paths ---
OCSERV_CONF_DIR="/etc/ocserv"
OCSERV_CONF="${OCSERV_CONF_DIR}/ocserv.conf"
OCSERV_PASSWD="${OCSERV_CONF_DIR}/ocpasswd"
OCSERV_NET_ENV="${OCSERV_CONF_DIR}/ocserv-net.env"
OCSERV_SSL_DIR="${OCSERV_CONF_DIR}/ssl"
SYSTEMD_DROP_IN_DIR="/etc/systemd/system/ocserv.service.d"
SYSCTL_CONF="/etc/sysctl.d/60-ocserv-forward.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults (prompted values left empty to trigger interactive prompt) ---
PUBLIC_IP=""
DOMAIN="example.com"
TCP_PORT=""
UDP_PORT=""
VPN_NETWORK=""
DNS_SERVERS=()
EGRESS_IFACE=""
NO_ROUTE_FILE=""
CA_CN=""
CERT_DAYS=3650
MAX_CLIENTS=16
VERBOSE=0
YES=0

# --- Logging ---
log()     { echo "==> $*"; }
verbose() { (( VERBOSE )) && echo "    $*" || true; }
die()     { echo "ERROR: $*" >&2; exit 1; }
warn()    { echo "WARNING: $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy an OpenConnect (ocserv) VPN server on Debian/Ubuntu.

Options:
  --public-ip <ip>       IP ocserv listens on (autodetected if unambiguous)
  --domain <name>        Domain advertised to clients (default: example.com)
  --tcp-port <n>         TCP port (prompted, default: 7443)
  --udp-port <n>         UDP port (prompted, default: 7443)
  --vpn-network <cidr>   Client address pool (prompted, default: 172.16.42.0/24)
  --dns <ip>             DNS pushed to clients; repeatable (default: 8.8.4.4)
  --egress-iface <if>    Interface to NAT through (autodetected from default route)
  --no-route-file <path> File of CIDRs (one per line) to exclude from tunnel
  --ca-cn <name>         CA certificate Common Name (default: <domain> VPN CA)
  --cert-days <n>        Certificate validity in days (default: 3650)
  --max-clients <n>      Maximum simultaneous clients (default: 16)
  -v, --verbose          Show detailed output
  -y, --yes              Non-interactive; accept all defaults/flags without prompting
  -h, --help             Show this help

EOF
    exit 0
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-ip)    PUBLIC_IP="$2";       shift 2 ;;
        --domain)       DOMAIN="$2";          shift 2 ;;
        --tcp-port)     TCP_PORT="$2";        shift 2 ;;
        --udp-port)     UDP_PORT="$2";        shift 2 ;;
        --vpn-network)  VPN_NETWORK="$2";     shift 2 ;;
        --dns)          DNS_SERVERS+=("$2");  shift 2 ;;
        --egress-iface) EGRESS_IFACE="$2";   shift 2 ;;
        --no-route-file) NO_ROUTE_FILE="$2"; shift 2 ;;
        --ca-cn)        CA_CN="$2";           shift 2 ;;
        --cert-days)    CERT_DAYS="$2";       shift 2 ;;
        --max-clients)  MAX_CLIENTS="$2";     shift 2 ;;
        -v|--verbose)   VERBOSE=1;            shift ;;
        -y|--yes)       YES=1;                shift ;;
        -h|--help)      usage ;;
        *) die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# --- Helper functions ---

prompt_value() {
    local prompt="$1" default="$2" result
    if (( YES )); then
        echo "$default"
        return
    fi
    read -rp "${prompt} [${default}]: " result
    echo "${result:-$default}"
}

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

# Convert CIDR prefix to dotted netmask
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

# Return "<network> <mask>" from a CIDR
cidr_to_network_mask() {
    local cidr="$1"
    local net="${cidr%%/*}" prefix="${cidr##*/}"
    echo "$net $(cidr_to_mask "$prefix")"
}

# Return "addr/dotted-mask" from a CIDR (ocserv no-route format)
cidr_to_ocserv() {
    local cidr="$1"
    read -r net mask < <(cidr_to_network_mask "$cidr")
    echo "${net}/${mask}"
}

detect_public_ip() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk 'NR==1 { for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit} }'
}

detect_egress_iface() {
    ip route show default 2>/dev/null \
        | awk 'NR==1 { for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit} }'
}

have_nftables() { command -v nft &>/dev/null; }

# --- Step 1: Preflight ---
preflight() {
    log "Preflight checks"

    [[ $EUID -eq 0 ]] || die "Must be run as root (try: sudo $0)"
    command -v apt-get &>/dev/null || die "apt-get not found; this script requires Debian/Ubuntu"

    # Resolve public IP
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="$(detect_public_ip)"
        [ -n "$PUBLIC_IP" ] || die "Could not autodetect public IP. Pass --public-ip <ip>"
        verbose "Autodetected public IP: $PUBLIC_IP"
    fi
    validate_ip "$PUBLIC_IP" || die "Invalid IP address: $PUBLIC_IP"

    # Resolve egress interface
    if [ -z "$EGRESS_IFACE" ]; then
        EGRESS_IFACE="$(detect_egress_iface)"
        [ -n "$EGRESS_IFACE" ] || die "Could not autodetect egress interface. Pass --egress-iface <iface>"
        verbose "Autodetected egress interface: $EGRESS_IFACE"
    fi
    ip link show "$EGRESS_IFACE" &>/dev/null || die "Interface not found: $EGRESS_IFACE"

    # Validate no-route file if given
    if [ -n "$NO_ROUTE_FILE" ]; then
        [ -f "$NO_ROUTE_FILE" ] || die "no-route file not found: $NO_ROUTE_FILE"
        local lineno=0
        while IFS= read -r line; do
            (( lineno++ ))
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            line="${line%%#*}"; line="${line// /}"
            validate_cidr "$line" || die "$NO_ROUTE_FILE line $lineno: invalid CIDR '$line'"
        done < "$NO_ROUTE_FILE"
    fi

    # Interactive prompts for values not supplied via flags
    [ -z "$TCP_PORT"    ] && TCP_PORT="$(prompt_value "TCP port"           "7443")"
    [ -z "$UDP_PORT"    ] && UDP_PORT="$(prompt_value "UDP port"           "7443")"
    [ -z "$VPN_NETWORK" ] && VPN_NETWORK="$(prompt_value "VPN client network (CIDR)" "172.16.42.0/24")"

    validate_cidr "$VPN_NETWORK" || die "Invalid CIDR: $VPN_NETWORK"
    [[ "$TCP_PORT" =~ ^[0-9]+$ ]] && (( TCP_PORT >= 1 && TCP_PORT <= 65535 )) || die "Invalid TCP port: $TCP_PORT"
    [[ "$UDP_PORT" =~ ^[0-9]+$ ]] && (( UDP_PORT >= 1 && UDP_PORT <= 65535 )) || die "Invalid UDP port: $UDP_PORT"

    # Default DNS
    [ ${#DNS_SERVERS[@]} -eq 0 ] && DNS_SERVERS=("8.8.4.4")

    # Default CA CN
    [ -z "$CA_CN" ] && CA_CN="${DOMAIN} VPN CA"

    # Port conflict check (skip if already used by ocserv — re-deploy scenario)
    for port in "$TCP_PORT" "$UDP_PORT"; do
        local conflict
        conflict=$(ss -tlnp "sport = :${port}" 2>/dev/null | tail -n +2 | grep -v ocserv || true)
        [ -n "$conflict" ] && warn "Port ${port} appears to be in use by another process"
    done

    # Print resolved configuration for confirmation
    echo
    echo "  Public IP        : $PUBLIC_IP"
    echo "  Domain           : $DOMAIN"
    echo "  TCP port         : $TCP_PORT"
    echo "  UDP port         : $UDP_PORT"
    echo "  VPN network      : $VPN_NETWORK"
    echo "  DNS              : ${DNS_SERVERS[*]}"
    echo "  Egress interface : $EGRESS_IFACE"
    echo "  CA CN            : $CA_CN"
    echo "  Cert validity    : ${CERT_DAYS} days"
    echo "  Max clients      : $MAX_CLIENTS"
    [ -n "$NO_ROUTE_FILE" ] && echo "  No-route file    : $NO_ROUTE_FILE"
    echo

    if (( ! YES )); then
        read -rp "Proceed with deployment? [y/N] " ans
        [[ "$ans" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
    fi
}

# --- Step 2: Install packages ---
install_packages() {
    log "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    local pkgs=(ocserv gnutls-bin)
    have_nftables || pkgs+=(nftables)
    apt-get install -y -qq "${pkgs[@]}"
    verbose "Installed: ${pkgs[*]}"
}

# --- Step 3: Generate PKI ---
generate_pki() {
    log "Generating PKI"
    mkdir -p "$OCSERV_SSL_DIR"
    chmod 700 "$OCSERV_SSL_DIR"

    local ca_key="${OCSERV_SSL_DIR}/ca-key.pem"
    local ca_cert="${OCSERV_SSL_DIR}/ca-cert.pem"
    local srv_key="${OCSERV_SSL_DIR}/server-key.pem"
    local srv_cert="${OCSERV_SSL_DIR}/server-cert.pem"
    local crl="${OCSERV_SSL_DIR}/crl.pem"

    # CA key — never overwrite
    if [ -f "$ca_key" ]; then
        warn "CA key already exists; reusing $ca_key"
    else
        verbose "Generating CA private key"
        certtool --generate-privkey --outfile "$ca_key" 2>/dev/null
        chmod 600 "$ca_key"
    fi

    # CA certificate
    if [ -f "$ca_cert" ]; then
        warn "CA certificate already exists; reusing $ca_cert"
    else
        verbose "Generating CA certificate"
        local tmpl; tmpl=$(mktemp)
        cat > "$tmpl" <<EOF
cn = "${CA_CN}"
ca
cert_signing_key
crl_signing_key
expiration_days = ${CERT_DAYS}
EOF
        certtool --generate-self-signed \
            --load-privkey "$ca_key" \
            --template "$tmpl" \
            --outfile "$ca_cert" 2>/dev/null
        rm -f "$tmpl"
        chmod 644 "$ca_cert"
    fi

    # Server key — never overwrite
    if [ -f "$srv_key" ]; then
        warn "Server key already exists; reusing $srv_key"
    else
        verbose "Generating server private key"
        certtool --generate-privkey --outfile "$srv_key" 2>/dev/null
        chmod 600 "$srv_key"
    fi

    # Server certificate
    if [ -f "$srv_cert" ]; then
        warn "Server certificate already exists; reusing $srv_cert"
    else
        verbose "Generating server certificate"
        local tmpl; tmpl=$(mktemp)
        cat > "$tmpl" <<EOF
cn = "${DOMAIN}"
dns_name = "${DOMAIN}"
ip_address = "${PUBLIC_IP}"
signing_key
tls_www_server
encryption_key
expiration_days = ${CERT_DAYS}
EOF
        certtool --generate-certificate \
            --load-privkey "$srv_key" \
            --load-ca-certificate "$ca_cert" \
            --load-ca-privkey "$ca_key" \
            --template "$tmpl" \
            --outfile "$srv_cert" 2>/dev/null
        rm -f "$tmpl"
        chmod 644 "$srv_cert"
    fi

    # Initial empty CRL
    if [ -f "$crl" ]; then
        verbose "CRL already exists; skipping"
    else
        verbose "Generating initial empty CRL"
        local tmpl; tmpl=$(mktemp)
        echo "crl_next_update = 365" > "$tmpl"
        certtool --generate-crl \
            --load-ca-privkey "$ca_key" \
            --load-ca-certificate "$ca_cert" \
            --template "$tmpl" \
            --outfile "$crl" 2>/dev/null
        rm -f "$tmpl"
        chmod 644 "$crl"
    fi

    mkdir -p "${OCSERV_SSL_DIR}/issued" "${OCSERV_SSL_DIR}/revoked"
    chmod 700 "${OCSERV_SSL_DIR}/issued" "${OCSERV_SSL_DIR}/revoked"
}

# --- Step 4: Generate ocserv.conf ---
generate_config() {
    log "Writing ocserv.conf"

    read -r vpn_net vpn_mask < <(cidr_to_network_mask "$VPN_NETWORK")

    # Build variable-length blocks
    local dns_block="" no_route_block=""
    for dns in "${DNS_SERVERS[@]}"; do
        dns_block+="dns = ${dns}"$'\n'
    done

    if [ -n "$NO_ROUTE_FILE" ]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            line="${line%%#*}"; line="${line// /}"
            [ -z "$line" ] && continue
            no_route_block+="no-route = $(cidr_to_ocserv "$line")"$'\n'
        done < "$NO_ROUTE_FILE"
    fi

    local tmp_conf; tmp_conf=$(mktemp)

    cat > "$tmp_conf" <<EOF
### ocserv configuration — generated by deploy.sh
### Options above the SIGHUP marker require a full service restart.
### Options below it reload on: systemctl reload ocserv

auth = "certificate"
enable-auth = "plain[passwd=${OCSERV_PASSWD}]"

listen-host = ${PUBLIC_IP}
tcp-port = ${TCP_PORT}
udp-port = ${UDP_PORT}

run-as-user = ocserv
run-as-group = ocserv

socket-file = ocserv-socket
chroot-dir = /var/lib/ocserv

server-cert = ${OCSERV_SSL_DIR}/server-cert.pem
server-key  = ${OCSERV_SSL_DIR}/server-key.pem
ca-cert     = ${OCSERV_SSL_DIR}/ca-cert.pem

cert-user-oid = 2.5.4.3

tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-TLS1.3"

### All configuration options below this line are reloaded on a SIGHUP.

isolate-workers = true

max-clients = ${MAX_CLIENTS}
max-same-clients = 2
rate-limit-ms = 100
server-stats-reset-time = 604800

keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 25
try-mtu-discovery = false

auth-timeout = 240
min-reauth-time = 300
max-ban-score = 80
ban-reset-time = 1200
cookie-timeout = 300
deny-roaming = false
rekey-time = 172800
rekey-method = ssl

use-occtl = true
pid-file = /run/ocserv.pid
log-level = 2

crl = ${OCSERV_SSL_DIR}/crl.pem

device = vpns
predictable-ips = true
default-domain = ${DOMAIN}

ipv4-network = ${vpn_net}
ipv4-netmask = ${vpn_mask}

tunnel-all-dns = true
${dns_block}
ping-leases = false
mtu = 1420

route = default
${no_route_block}
cisco-client-compat = true
dtls-legacy = true
client-bypass-protocol = false
EOF

    # Backup existing config
    if [ -f "$OCSERV_CONF" ]; then
        local bak="${OCSERV_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$OCSERV_CONF" "$bak"
        verbose "Backed up existing config to $bak"
    fi

    mkdir -p "$OCSERV_CONF_DIR"
    mv "$tmp_conf" "$OCSERV_CONF"
    chmod 640 "$OCSERV_CONF"

    # Create empty ocpasswd if missing
    [ -f "$OCSERV_PASSWD" ] || { touch "$OCSERV_PASSWD"; chmod 640 "$OCSERV_PASSWD"; }
}

# --- Step 5: Networking lifecycle wiring ---
install_networking() {
    log "Installing networking scripts and systemd integration"

    # Write the runtime env file
    cat > "$OCSERV_NET_ENV" <<EOF
VPN_NETWORK=${VPN_NETWORK}
EGRESS_IFACE=${EGRESS_IFACE}
TCP_PORT=${TCP_PORT}
UDP_PORT=${UDP_PORT}
VPN_DEVICE=vpns
EOF
    chmod 640 "$OCSERV_NET_ENV"

    # Install ocserv-net
    install -m 755 "${SCRIPT_DIR}/ocserv-net" /usr/local/sbin/ocserv-net
    verbose "Installed /usr/local/sbin/ocserv-net"

    # Install ocserv-user
    install -m 755 "${SCRIPT_DIR}/ocserv-user" /usr/local/sbin/ocserv-user
    verbose "Installed /usr/local/sbin/ocserv-user"

    # Persist IP forwarding
    echo "net.ipv4.ip_forward = 1" > "$SYSCTL_CONF"
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    verbose "Enabled IP forwarding"

    # Systemd drop-in
    mkdir -p "$SYSTEMD_DROP_IN_DIR"
    cat > "${SYSTEMD_DROP_IN_DIR}/network.conf" <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/ocserv-net up
ExecStopPost=-/usr/local/sbin/ocserv-net down
EOF
    systemctl daemon-reload
    verbose "Installed systemd drop-in"
}

# --- Step 6: Enable and start service ---
enable_service() {
    log "Enabling and starting ocserv"

    if systemctl is-active --quiet ocserv 2>/dev/null; then
        systemctl restart ocserv || {
            echo "ocserv failed to restart. Recent journal:" >&2
            journalctl -u ocserv -n 30 --no-pager >&2
            exit 1
        }
    else
        systemctl enable --now ocserv || {
            echo "ocserv failed to start. Recent journal:" >&2
            journalctl -u ocserv -n 30 --no-pager >&2
            exit 1
        }
    fi

    systemctl is-active --quiet ocserv || {
        echo "ocserv is not running after start attempt. Recent journal:" >&2
        journalctl -u ocserv -n 30 --no-pager >&2
        exit 1
    }
}

# --- Step 7: Summary ---
print_summary() {
    echo
    echo "=========================================="
    echo "  ocserv deployment complete"
    echo "=========================================="
    echo
    echo "  VPN endpoint   : ${PUBLIC_IP}:${TCP_PORT}"
    echo "  CA certificate : ${OCSERV_SSL_DIR}/ca-cert.pem"
    echo
    echo "  First steps:"
    echo "    Add a certificate user:"
    echo "      ocserv-user add-cert <username>"
    echo
    echo "    Add a password user:"
    echo "      ocserv-user add-pass <username>"
    echo
    echo "  Distribute to each client:"
    echo "    - <username>-key.pem  (private key — keep confidential)"
    echo "    - <username>-cert.pem (client certificate)"
    echo "    - ca-cert.pem         (CA — client uses this to trust the server)"
    echo
    echo "  NAT/forwarding is managed by the ocserv service lifecycle."
    echo "  To reload config (below-SIGHUP options): systemctl reload ocserv"
    echo "  To restart fully:                        systemctl restart ocserv"
    echo
}

# --- Main ---
preflight
install_packages
generate_pki
generate_config
install_networking
enable_service
print_summary
