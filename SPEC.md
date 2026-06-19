# ocserv-deploy — Specification

Specification for a set of shell scripts that deploy and operate an
[ocserv](https://ocserv.gitlab.io/www/) (OpenConnect VPN) server on a **fresh
Debian or Debian-derivative** machine, with deployment-specific details supplied
on the command line.

This document describes *what* the scripts must do and how they fit together. No
implementation is included here.

---

## 1. Goals & non-goals

**Goals**

- Take a clean Debian/Ubuntu host from nothing to a working OpenConnect VPN in
  one command.
- Generate the full PKI (CA, server cert/key) locally — no external CA, no DNS
  dependency.
- Support **both** client-certificate auth and username/password auth at the
  same time, OR-composed (either is sufficient to log in).
- Configure OS networking (IP forwarding + NAT) so traffic actually flows, and
  bind that configuration to the **VPN service lifecycle**: applied when ocserv
  starts, removed when it stops.
- Provide a separate, ongoing **user-management** tool for adding/removing both
  certificate users and password users after deployment.
- Be **idempotent**: re-running deployment must not corrupt an existing install;
  it updates config and skips already-created artifacts (especially PKI).

**Non-goals**

- No publicly-trusted (Let's Encrypt) server certificate. Self-signed CA only.
- No high-availability / multi-node / load-balancer setup.
- No web UI. CLI only.
- No automatic client-OS configuration (we produce import bundles, not profiles
  pushed to devices).

---

## 2. Target environment & assumptions

- OS: Debian 12+ or derivative (Ubuntu 22.04+). `apt` available.
- Run as `root` (or via `sudo`). The script must refuse to continue otherwise.
- Network stack: the script prefers **nftables** (default firewall backend on
  modern Debian) and falls back to `iptables` only if nftables is unavailable.
- A working default route exists at deploy time (used to autodetect the egress
  interface unless overridden).
- Fresh install assumption: the scripts may install packages and write under
  `/etc/ocserv`, but must not silently overwrite an existing CA key (see §5).

---

## 3. Deliverables

The repository should contain, after implementation:

| File | Purpose |
|------|---------|
| `deploy.sh` | One-shot deployment: packages, PKI, config, networking, service. |
| `ocserv-user` | Post-deploy user management (add/del/list, cert or password). |
| `ocserv-net`  | Bring NAT/forwarding up/down; invoked by the service lifecycle. |
| `SPEC.md` | This document. |
| `README.md` | Short usage overview pointing at the above. |

The `sample/` directory is reference material only and will be removed; its
`ocserv.conf` is the basis for the generated config and its `newuser.sh` is the
basis for the certificate-issuing path of `ocserv-user`.

---

## 4. `deploy.sh` — deployment script

### 4.1 Command-line interface & interactive prompts

Deployment-specific details come from flags. For values not supplied on the
command line, the script **prompts interactively at runtime**, showing the
default in the prompt and accepting it on empty input (e.g.
`TCP/UDP port [7443]:`, `VPN client network [172.16.42.0/24]:`). Under `--yes`
the prompts are skipped and defaults/flags are used directly. Missing
**required** values that cannot be defaulted (no identity-bearing value is ever
guessed) cause a clear error.

| Flag | Required | Default | Meaning |
|------|----------|---------|---------|
| `--public-ip <ip>` | yes* | autodetect | IP ocserv binds/listens on (`listen-host`). *Required if autodetect finds more than one candidate. |
| `--domain <name>` | no | `example.com` | `default-domain` advertised to clients. |
| `--tcp-port <n>` | no | prompt, default `7443` | `tcp-port`. |
| `--udp-port <n>` | no | prompt, default `7443` | `udp-port`. |
| `--vpn-network <cidr>` | no | prompt, default `172.16.42.0/24` | Client address pool (`ipv4-network`/`ipv4-netmask`). |
| `--dns <ip>` | no | `8.8.4.4` | DNS server pushed to clients (repeatable). |
| `--egress-iface <if>` | no | autodetect from default route | Interface to NAT/masquerade out of. |
| `--no-route-file <path>` | no | none | File with CIDRs (one per line) to exclude from the full tunnel. Empty/absent ⇒ clean full tunnel. |
| `--ca-cn <name>` | no | `<domain> VPN CA` | CA certificate Common Name. |
| `--cert-days <n>` | no | `3650` | Validity for generated certs. |
| `--max-clients <n>` | no | `16` | `max-clients`. |
| `--yes` / `-y` | no | off | Non-interactive; assume yes to prompts. |

The script must print resolved effective values (after defaults/autodetect)
before making changes, and — unless `--yes` — ask for confirmation.

### 4.2 Steps (in order)

1. **Preflight.** Verify root, verify Debian-family (`apt` present), verify the
   chosen ports are free, resolve/validate `--public-ip` and `--egress-iface`,
   validate CIDRs. Abort early on any failure.
2. **Install packages.** `apt-get update` then install `ocserv`, `gnutls-bin`
   (provides `certtool`), and `nftables` (or ensure `iptables`). Quiet,
   non-interactive (`DEBIAN_FRONTEND=noninteractive`).
3. **PKI generation** (see §5). Skip any artifact that already exists.
4. **Config generation** (see §6). Render `/etc/ocserv/ocserv.conf` from the
   resolved parameters. Back up any pre-existing config first.
5. **Networking lifecycle wiring** (see §7). Install `ocserv-net` and the
   systemd drop-in that calls it on start/stop. Persist `net.ipv4.ip_forward`.
6. **Service enablement.** `systemctl enable --now ocserv`; verify it is active;
   on failure, dump the last journal lines and exit non-zero.
7. **Summary.** Print where the CA cert lives, how to add the first user, and
   the connection endpoint (`<public-ip>:<port>`).

### 4.3 Idempotency & safety

- PKI: never overwrite an existing CA key/cert or server key (these are
  identity; clobbering them invalidates every issued client). Warn and reuse.
- Config: overwrite is allowed but the previous file is copied to
  `ocserv.conf.bak.<timestamp>` first.
- Re-running with new flags updates the config and reloads/restarts the service.

---

## 5. PKI layout

All material lives under `/etc/ocserv/ssl/` with strict permissions (keys
`0600`, owned by root). Generated with `certtool` (GnuTLS).

| File | Role |
|------|------|
| `ca-key.pem` | CA private key (never leaves the server). |
| `ca-cert.pem` | CA certificate — `ca-cert` in config; also distributed to clients so they can trust the server and so the server can verify client certs. |
| `server-key.pem` | Server private key (`server-key`). |
| `server-cert.pem` | Server certificate, signed by the CA, with the public IP / domain as SAN (`server-cert`). |
| `crl.pem` | Certificate Revocation List (`crl` in config). Initialized empty at deploy so revocation works later; regenerated by `ocserv-user del` for cert users. |

Notes:

- Server cert SAN must include `--public-ip` and `--domain` so OpenConnect
  clients validate the host correctly.
- The CA cert is the artifact operators hand to clients; the summary output must
  state its path.

---

## 6. Generated `ocserv.conf`

Rendered from `sample/ocserv.conf` with the following decisions baked in.

### 6.1 Authentication (certificate OR password)

```
auth = "certificate"
enable-auth = "plain[passwd=/etc/ocserv/ocpasswd]"
```

- Primary auth is certificate; the plain/`ocpasswd` method is an OR-alternative
  so that either a valid client cert **or** a valid username/password is
  sufficient. This supports the common case (most clients use certs) plus
  appliances/routers whose built-in OpenConnect client only does passwords.
- `cert-user-oid = 2.5.4.3` (CN): the VPN username is taken from the client
  certificate's Common Name. `ocserv-user` must therefore set CN = username when
  issuing certs (see §8).
- `/etc/ocserv/ocpasswd` is created empty at deploy time so the plain method has
  a valid (if empty) backing file.

### 6.2 Networking / routing

- `listen-host`, `tcp-port`, `udp-port`, `ipv4-network`/`ipv4-netmask`,
  `default-domain`, `dns`, `max-clients` come from the resolved CLI values.
- Full tunnel: `route = default`, `tunnel-all-dns = true`.
- `no-route` lines are generated from `--no-route-file` (one CIDR per line),
  converted to ocserv's `ADDR/MASK` form. The hardcoded sample exclusion list is
  **not** carried over; absent a file, there are no exclusions.
- `crl = /etc/ocserv/ssl/crl.pem` is enabled so revocation is effective.

### 6.3 Compatibility & other settings

- Keep the sample's legacy-client compatibility: TLS 1.3 disabled in
  `tls-priorities`, `cisco-client-compat = true`, `dtls-legacy = true`. These
  exist for AnyConnect / older openconnect and router clients; the spec retains
  them deliberately.
- Keep the chroot (`chroot-dir = /var/lib/ocserv`), `isolate-workers`, and the
  run-as `ocserv:ocserv` user/group from the packaged defaults.
- Respect the SIGHUP split in the file: deployment may restart the service, but
  `ocserv-user` should prefer SIGHUP reload for CRL/password changes (§8.4).

---

## 7. Networking lifecycle (`ocserv-net` + systemd)

Per the chosen model, NAT and forwarding are **applied when the VPN service
starts and removed when it stops**, rather than persisted as standalone rules.

### 7.1 `ocserv-net up|down`

- `up`:
  - Ensure `net.ipv4.ip_forward=1` (set live; deploy also persists it via
    `/etc/sysctl.d/`).
  - Add MASQUERADE for the VPN pool (`--vpn-network`) out of `--egress-iface`.
  - Add FORWARD accept rules between the tun device and the egress interface.
  - Add INPUT accept for the configured TCP/UDP port.
  - All rules go in a **dedicated, named nftables table** (or an iptables chain
    with a unique comment marker) so teardown is exact and collision-free.
- `down`: delete exactly that table/chain. Must be safe to run when rules are
  absent (idempotent, no error on missing).
- The interface, ports, and pool are read from a small env/config file written
  by `deploy.sh` (so `ocserv-net` and `ocserv.conf` never disagree).

### 7.2 Systemd integration

A drop-in (`/etc/systemd/system/ocserv.service.d/network.conf`) wires:

- `ExecStartPost=/usr/local/sbin/ocserv-net up`
- `ExecStopPost=/usr/local/sbin/ocserv-net down`

so `systemctl start/stop ocserv` brings the host networking up/down with it.

---

## 8. `ocserv-user` — user management

Single tool for both auth types, usable after deployment.

### 8.1 Subcommands

| Command | Action |
|---------|--------|
| `ocserv-user add-cert <username> [--days N] [--out DIR] [--p12 [--p12-pass PASS]]` | Issue a client certificate (CN=username), signed by the CA. `--p12` additionally bundles a PKCS#12 file. |
| `ocserv-user add-pass <username>` | Create/update a password user via `ocpasswd` (prompt for password unless piped). |
| `ocserv-user del <username>` | Remove the user from both backends: delete from `ocpasswd` if present, and revoke their cert via CRL if a cert was issued. |
| `ocserv-user list` | List password users and issued certificates. |

### 8.2 Certificate issuance (from `sample/newuser.sh`, corrected)

- Generate a private key + a certtool template with `cn = "<username>"`,
  `unit = "users"`, `tls_www_client`, `signing_key`, `encryption_key`.
- Sign with `/etc/ocserv/ssl/ca-cert.pem` + `ca-key.pem`.
- Produce, in the output dir (default a per-user dir, not the operator's home):
  - `<username>-key.pem`, `<username>-cert.pem` (always).
  - a copy of `ca-cert.pem` for the client to trust the server.
  - `<username>.p12` — **only when `--p12` is given** — a PKCS#12 bundle
    (key + cert) for easy import into OpenConnect/AnyConnect clients. The export
    password is taken from `--p12-pass` or prompted (no echo); not emitted by
    default.
- Clean up the temporary template file. (The sample's `rm -f "$template"` bug —
  referencing an unset var and leaving the `.cfg` behind — must be fixed, and
  the hardcoded `install ... ~dair/` step removed in favor of `--out`.)
- Track issued certs (e.g. keep their serials/index under
  `/etc/ocserv/ssl/issued/`) so `del` can revoke precisely.

### 8.3 Password users

- Wrap `ocpasswd -c /etc/ocserv/ocpasswd <username>`.
- Read the password from a TTY prompt (no echo) or stdin; never from argv.

### 8.4 Applying changes

- Password changes take effect without reload (ocserv reads `ocpasswd` per
  auth).
- Cert revocation: after rewriting `crl.pem`, signal the server to reload
  (`SIGHUP` / `systemctl reload ocserv`) since `crl` reloads below the SIGHUP
  line.
- A connected, just-revoked user is not dropped mid-session; revocation blocks
  reconnect. Note this in user-facing help.

---

## 9. On-disk layout (post-deploy)

```
/etc/ocserv/
  ocserv.conf
  ocpasswd                 # password users (may be empty)
  ssl/
    ca-key.pem  ca-cert.pem
    server-key.pem  server-cert.pem
    crl.pem
    issued/                # bookkeeping for issued client certs
/etc/ocserv/ocserv-net.env # iface/ports/pool consumed by ocserv-net
/etc/systemd/system/ocserv.service.d/network.conf
/etc/sysctl.d/60-ocserv-forward.conf
/usr/local/sbin/ocserv-net
/usr/local/sbin/ocserv-user
```

---

## 10. Conventions for all scripts

- `bash`, `set -euo pipefail`; clear `usage()` on `-h`/`--help` and on bad args.
- Fail fast with actionable messages; never leave a half-written config in place
  of a working one (write to temp, validate, move into place).
- Idempotent where stated; safe to re-run.
- Quiet on success by default, verbose with `-v`; all destructive actions
  (overwrite config, revoke, delete user) are logged.
- Validate the produced `ocserv.conf` before restarting (e.g. `ocserv -t` /
  config test) and refuse to restart on a broken config.

---

## 11. Open items / future

- IPv6 support (pool, NAT) — out of scope for v1; note where it would slot in.
- Optional Let's Encrypt server cert — explicitly excluded now; the config's
  `server-cert`/`server-key` indirection leaves room to add it later.
- `--no-route-file` format is plain CIDR-per-line; a richer format (comments,
  per-group routes) could come later.
