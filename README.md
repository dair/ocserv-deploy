# ocserv-deploy

Deploy and manage an [OpenConnect VPN](https://ocserv.gitlab.io/www/) server on Debian 12+ or Ubuntu 22.04+.

## Quick start

```bash
sudo ./deploy.sh
```

The script prompts for any values not supplied as flags and asks for confirmation before making changes.

## Scripts

### `deploy.sh` — one-shot deployment

Installs packages, generates the CA and server certificates, writes `ocserv.conf`, wires NAT/forwarding to the service lifecycle, and starts ocserv.

```
sudo ./deploy.sh [OPTIONS]

  --public-ip <ip>         IP ocserv listens on (autodetected if unambiguous)
  --domain <name>          Domain advertised to clients (default: example.com)
  --tcp-port <n>           TCP port (prompted; default 7443)
  --udp-port <n>           UDP port (prompted; default 7443)
  --vpn-network <cidr>     Client address pool (prompted; default 172.16.42.0/24)
  --dns <ip>               DNS pushed to clients; repeatable (default 8.8.4.4)
  --egress-iface <if>      Interface to NAT through (autodetected)
  --no-route-file <path>   File of CIDRs to exclude from the tunnel (one per line)
  --ca-cn <name>           CA Common Name (default: "<domain> VPN CA")
  --cert-days <n>          Certificate validity in days (default: 3650)
  --max-clients <n>        Maximum simultaneous clients (default: 16)
  -y, --yes                Non-interactive mode
  -v, --verbose            Verbose output
```

Re-running `deploy.sh` is safe: the CA key and server key are never overwritten, and the existing config is backed up before replacement.

### `ocserv-user` — user management

Installed to `/usr/local/sbin/ocserv-user` by `deploy.sh`.

```bash
# Issue a client certificate
ocserv-user add-cert alice

# Issue a certificate with PKCS#12 bundle for easy import
ocserv-user add-cert alice --p12

# Add a password user (for routers/appliances with built-in OpenConnect)
ocserv-user add-pass alice

# Remove a user (revokes cert if issued, removes password if set)
ocserv-user del alice

# List all users and certificates
ocserv-user list
```

`add-cert` writes to the current directory by default (`--out DIR` to override):
- `<username>-key.pem` — private key (transfer to client; not kept on server)
- `<username>-cert.pem` — client certificate
- `ca-cert.pem` — CA certificate (client uses this to trust the server)

Certificate revocation blocks reconnection but does not terminate active sessions.

### `ocserv-net` — networking lifecycle

Installed to `/usr/local/sbin/ocserv-net` by `deploy.sh`. Called automatically by the ocserv systemd service — not normally invoked directly.

```bash
ocserv-net up    # apply NAT/forwarding rules (called on service start)
ocserv-net down  # remove NAT/forwarding rules (called on service stop)
```

## Authentication

Both methods are active simultaneously — a client needs either a valid certificate **or** a username/password:

| Method | Tool | Typical use |
|--------|------|-------------|
| Certificate | `ocserv-user add-cert` | Laptops, phones |
| Password | `ocserv-user add-pass` | Routers, appliances |

## Service management

```bash
systemctl restart ocserv   # full restart (required for listen-host, ports, certs)
systemctl reload ocserv    # reload below-SIGHUP options (CRL, routing, DNS, limits)
systemctl status ocserv
journalctl -u ocserv -f
occtl show users
occtl show status
```

## On-disk layout

```
/etc/ocserv/
  ocserv.conf
  ocpasswd
  ocserv-net.env         # networking parameters for ocserv-net
  ssl/
    ca-key.pem           # CA private key — never distribute
    ca-cert.pem          # CA certificate — distribute to clients
    server-key.pem
    server-cert.pem
    crl.pem
    issued/              # copy of each issued client cert (for revocation)
    revoked/             # revoked certs used to rebuild the CRL
```

See [SPEC.md](SPEC.md) for the full design specification.
