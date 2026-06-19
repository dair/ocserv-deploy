# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal, opinionated deployment of **ocserv** (the OpenConnect VPN server). There is no application code, build, or test suite — the repo holds a ready-to-edit server config plus a helper script for issuing client certificates. Files in `sample/` are templates meant to be copied onto a server under `/etc/ocserv/`.

- `sample/ocserv.conf` → deployed to `/etc/ocserv/ocserv.conf`
- `sample/newuser.sh` → run on the server to mint a client certificate for one user

## Operational commands

```bash
# Issue a client certificate (run on the server, from the dir holding the CA)
./sample/newuser.sh <username>      # writes <username>-key.pem / <username>-cert.pem

# Apply config changes
sudo systemctl restart ocserv       # required for directives ABOVE the SIGHUP line (see below)
sudo kill -HUP $(cat /run/ocserv.pid)   # reloads only directives BELOW the SIGHUP line

# Password-based users (the enable-auth fallback)
sudo ocpasswd -c /etc/ocserv/ocpasswd <username>

# Live server inspection
sudo occtl show users
sudo occtl show status
```

## Architecture & coupling to understand

**Dual authentication.** `auth = "certificate"` is the primary method, but `enable-auth = "plain[passwd=/etc/ocserv/ocpasswd]"` is an OR-alternative — a client can connect with *either* a valid client certificate *or* a username/password from `ocpasswd`. Changing one without considering the other changes who can log in.

**Certificate identity is wired to the config.** `cert-user-oid = 2.5.4.3` (CN) means ocserv derives the VPN username from the certificate's Common Name. `newuser.sh` sets `cn = "${username}"`, so the username passed to the script *is* the VPN identity. The script signs against the CA at `/etc/ocserv/ssl/ca-cert.pem` + `ca-key.pem`, which must match `ca-cert` in the config. Keep these in sync.

**Config reload semantics.** `ocserv.conf` is split by a marker line (`### All configuration options below this line are reloaded on a SIGHUP`). Directives above it (auth, listen-host, ports, certs, chroot) only take effect on a full restart; directives below it reload on SIGHUP. When editing, know which side a directive is on.

**Network shape.** Full-tunnel VPN: `route = default` with `tunnel-all-dns`. The `no-route` block carves specific CIDRs out of the tunnel (they go direct, not through the VPN) — this is intentional split-routing, not dead config. Pool is `172.16.42.0/24`; server binds `185.200.191.125` on tcp/udp `7443`.

**Legacy-client compatibility.** `tls-priorities` explicitly disables TLS 1.3, and `cisco-client-compat` / `dtls-legacy` are on, to support AnyConnect and older openconnect clients. Don't "modernize" these away without confirming the client requirements.

## Notes when editing `newuser.sh`

- The script hardcodes the local account `dair` (it `install`s the issued cert into `~dair/`). Adjust if deploying for a different operator.
- Line 42 (`rm -f "$template"`) references an unset variable; the template file it actually creates is `$tmplfile`. Leaves the `.cfg` template behind.
