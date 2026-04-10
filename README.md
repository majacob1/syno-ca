# Overview

This project issues and manages private TLS certificates for Synology DSM using:

- **Ed25519** Root CA (modern, compact, secure)  
- **ECDSA P‑256** leaf certificates (Synology-compatible)  
- **Encrypted CA key** with a hybrid unlock model (Option C)  
- **Unattended JSON configuration** for batch issuance  
- **Versioned certificate archive** for safe rollbacks  
- **Certificate linting / validation** after issuance  
- **Optional auto‑renewal via cron** with renewal window control  
- **ACME‑style hooks** (`pre-renew`, `post-renew`, `deploy`) for automation

You can run **manual-only** renewals (maximum security) or enable **fully automated** workflows when desired.


Notes:
- Back up `ca/root.key.enc` and `ca/root.crt`.  
- Do **not** back up `ca/root.key` unless you accept automated unlock on restore.  
- `output/<CN>/archive/` stores previous versions automatically.


# Design summary

- **Root CA**: Ed25519 keypair for the CA certificate.  
- **Leaf certs**: ECDSA P‑256 keys for Synology compatibility.  
- **Hybrid unlock model**: If `ca/root.key` exists, automation works; if only `ca/root.key.enc` exists, the script prompts for the password. You can delete `ca/root.key` to lock the CA.  
- **Hooks**: Pre/post/deploy hooks allow service restarts, Synology API uploads, notifications, or copying certs to other hosts.  
- **Linting**: The script validates structure, chain, and SAN presence after issuance.  
- **Archive**: Old certs/keys are archived with timestamps for rollback.


# Requirements

- `openssl` (1.1.1+ recommended)  
- `jq` (for JSON parsing)  
- Bash shell (Linux, macOS, or WSL)

Install on Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y openssl jq
```

# Hooks (ACME-style)

Hooks are optional executable scripts placed in `hooks/`. If present and executable, the script calls them with parameters.

Hook signatures:
- `hooks/pre-renew.sh CN CERT_DIR` — runs before issuing a certificate.  
- `hooks/post-renew.sh CN CERT_DIR` — runs after issuance and before deployment.  
- `hooks/deploy.sh CN CERT_DIR` — runs after linting; intended for deployment tasks.

Common uses:
- Stop/start services before renewal.  
- Upload certificate to Synology via API.  
- Copy certs to remote hosts (scp/rsync).  
- Reload reverse proxies (nginx, HAProxy).  
- Send notifications (email, Telegram, Signal).

Make hooks executable:

```bash
chmod +x hooks/*.sh
```

# 11 Synology DSM integration

To import a certificate into DSM:

1. Open DSM web UI → **Control Panel → Security → Certificate**.  
2. Click **Add → Import certificate**.  
3. Upload:
   - **Private key:** `output/<CN>/<CN>.key`  
   - **Certificate:** `output/<CN>/<CN>.crt`  
   - **CA certificate:** `output/root.crt`  
4. Assign the certificate to DSM services (HTTPS, WebDAV, Reverse Proxy, etc.).

You can automate this with a `deploy.sh` hook that calls the Synology API.

Conceptual Synology API example (adapt to your DSM version and secure auth):

```bash
curl -k -X POST "https://SYNODOMAIN:5001/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1" \
  -F "key=@/path/to/output/nas.example.com/nas.example.com.key" \
  -F "cert=@/path/to/output/nas.example.com/nas.example.com.crt" \
  -F "ca=@/path/to/output/root.crt" \
  -u "admin:YOUR_PASSWORD"
```

# Encrypted CA key workflow (Hybrid model)

- **Initial creation/import**: The script can create a new Ed25519 CA key or import existing keys. On first creation the script will offer to encrypt the key and write `ca/root.key.enc`.  
- **Locked mode**: Only `ca/root.key.enc` exists. The CA cannot sign certificates until you provide the password. This is the most secure state.  
- **Unlocked mode**: `ca/root.key` exists (decrypted). The script can run unattended (cron, hooks). You can delete `ca/root.key` to return to locked mode.  
- **Hybrid behavior**: Optionally, the script can support a token file or tmpfs-based decrypted key for temporary automation; delete the token to force manual unlock.

**Manual-only renewal workflow (recommended for high security)**

1. Ensure `ca/root.key` is absent (only `root.key.enc` present).  
2. Run:

```bash
./syno-ca.sh --config config.json
```
3. Enter the CA password when prompted.
4. The script decrypts the key, issues/renews certificates, then deletes the decrypted key (if configured) so the CA returns to locked mode.


# Backup & restore recommendations

- **Back up**: `ca/root.key.enc`, `ca/root.crt`, `config.json`.  
- **Do not back up**: `ca/root.key` unless you accept automated unlock on restore.  
- **Restore**: Restore `root.key.enc` and `root.crt`, then run the script and enter the password to unlock when needed.


# Typical workflows

## Manual yearly renewal (maximum security)

```bash
rm -f ca/root.key          # ensure CA is locked
./syno-ca.sh --config config.json
# enter CA password when prompted
# upload new certs to Synology (manual or via deploy hook)
rm -f ca/root.key          # lock CA again if script left it decrypted
```
## Temporary automation (maintenance window)
1. Unlock once and keep ca/root.key in a secure tmpfs or protected directory.
2. Run cron jobs during the maintenance window.
3. Delete ca/root.key after maintenance to lock the CA.
## Fully automated (convenience, lower physical security)
 - Keep ca/root.key on disk with strict permissions (chmod 600) and restricted ownership.
 - Add the suggested cron entry.
 - Implement deploy.sh to push certs to Synology automatically.


# Troubleshooting

- **"Missing SAN extension"** — Ensure `sans` are set in `config.json` or the script adds SANs via CSR config.  
- **"Certificate does not verify"** — Confirm `output/root.crt` matches the CA used to sign.  
- **"Synology rejects certificate"** — Ensure leaf cert is ECDSA P‑256 and SANs are present.  
- **Cron job does nothing** — Verify `ca/root.key` exists for unattended mode or run cron with an environment that can prompt for password (not recommended). Use absolute paths in cron.  
- **Hook fails** — Check hook script permissions (`chmod +x`) and test manually with the same environment variables.


# Security notes

- The encrypted master key (`root.key.enc`) is safe to back up. The decrypted key (`root.key`) must be protected with strict file permissions and limited access.  
- If an attacker obtains `root.key`, they can issue certificates trusted by your environment. Protect the key accordingly.  
- Use tmpfs for temporary decrypted keys if you want them to disappear on reboot.  
- Rotate the root CA only when necessary; plan certificate re-issuance for all dependent systems.


# Extending the system

- **Synology API integration**: Implement `deploy.sh` to call Synology's certificate import API and assign services.  
- **Notification**: Add email/Telegram/Signal notifications in `post-renew.sh`.  
- **HSM / KMS**: Replace file-based keys with an HSM or cloud KMS for higher security.  
- **Docker**: Run the script inside a container with mounted volumes for `ca/` and `output/`.  
- **GUI**: Build a small web UI that calls the script and displays certificate status.


# License & disclaimers

This project and documentation are provided as-is, without warranty. Use at your own risk. Adapt scripts and hooks to your environment and security policies before deploying in production.
