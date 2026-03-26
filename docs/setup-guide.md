# VPS DevOps — Setup Guide

End-to-end walkthrough for provisioning a fresh Ubuntu 24.04 VPS and deploying
the current stack from this repo.

This guide reflects the Ansible/Taskfile workflow that exists today. For the
current backup design and coverage, also see
[`docs/backup-architecture.md`](./backup-architecture.md).

---

## Prerequisites

Install these on your **local machine** before starting:

| Tool | Install |
|---|---|
| `git` | `brew install git` / distro package |
| `age` | `brew install age` / distro package |
| `sops` | `brew install sops` / [GitHub releases](https://github.com/getsops/sops/releases) |
| `ansible` | `brew install ansible` / `pipx install ansible --include-deps` |
| `go-task` | `brew install go-task/tap/go-task` / distro package |
| `community.sops` + `community.docker` collections | see below |

```bash
ansible-galaxy collection install community.sops community.docker community.general ansible.posix
```

Verify:
```bash
age --version && sops --version && ansible --version && task --version
```

---

## Step 1 — Age key for SOPS

This repo is wired around an Age private key at `./age.key`. The Taskfile and
local helper scripts set `SOPS_AGE_KEY_FILE=./age.key`, and encrypted files are
expected to match the recipient(s) listed in `.sops.yaml`.

Since SOPS decryption happens on your local machine, the VPS does not need this
Age key.

### 1a. Ensure the Age key is present

Place your Age private key at:

```bash
./age.key
```

Then fix permissions and verify it:

```bash
task check:unix:key
```

### 1b. Back up the Age key

If you lose `age.key`, you lose the ability to decrypt the repo secrets.
Back it up somewhere safe outside the repo.

---

## Step 2 — Bootstrap the server (Ansible)

The initial bootstrap playbook now does only the first handoff:
it creates the `deploy` user and installs its SSH key so the rest of the setup
can happen over the normal deploy-user path.

### 2a. Configure the inventory

The server IP is stored encrypted in [`ansible/inventory.sops.yaml`](../ansible/inventory.sops.yaml).
To update it:

```bash
task secrets:edit FILE=ansible/inventory.sops.yaml
```

This inventory file should also contain the privilege-escalation settings used
by the deploy-time playbooks:

```yaml
all:
  hosts:
    vps:
      ansible_host: ...
      ansible_user: deploy
      ansible_become_method: su
      ansible_become_user: root
      ansible_become_password: ...
```

### 2b. Set the deploy public key

Generate a dedicated key pair for the `deploy` user:

```bash
ssh-keygen -t ed25519 -C "vps-deploy" -f ~/.ssh/vps-deploy
```

Store the private key in its own encrypted file, expected at
[`deploy_ssh_private_key.sops`](../deploy_ssh_private_key.sops). The Taskfile
uses `sops exec-file` to decrypt that key to a temporary file only for the
duration of each SSH/Ansible command.

In [`ansible/bootstrap.yml`](../ansible/bootstrap.yml), replace the placeholder:

```yaml
vars:
  deploy_ssh_pubkey: "ssh-ed25519 AAAA..."   # contents of ~/.ssh/vps-deploy.pub
```

### 2c. Run the playbook

```bash
task bootstrap
```

### 2d. Verify SSH access as deploy user

```bash
task ssh
```

### 2e. Apply the base host configuration

This step connects as `deploy`, then escalates to `root` using the privilege
escalation settings stored in the encrypted inventory. It applies packages, Docker, firewall rules, SSH
hardening, fail2ban, unattended upgrades, and the host directories used by the
deploy playbooks.

```bash
task deploy:base
```

---

## Step 3 — Configure the repo (SOPS + secrets)

Do this on your **local machine** inside the `vps-devops` repo.

### 3a. Create `.sops.yaml`

The repo already expects a `.sops.yaml` that contains the Age recipient(s) used
for all `*.sops.yaml` files. If you need to create or update it, use your Age
public key(s), not GPG fingerprints.

Example:

```yaml
creation_rules:
  - path_regex: \.sops\.yaml$
    age: age1xxxxxxxxxx...
```

### 3b. Encrypt Traefik secrets

Generate an htpasswd hash for the dashboard:

```bash
htpasswd -nbB admin 'your-strong-password'
# Output: admin:$2y$05$...
```

```bash
cat > /tmp/traefik.env.yaml <<EOF
TRAEFIK_DASHBOARD_USER: admin
TRAEFIK_DASHBOARD_PASSWORD_HASH: "\$2y\$05\$your-hash-here"
EOF

SOPS_AGE_KEY_FILE=./age.key sops -e /tmp/traefik.env.yaml > traefik/.env.sops.yaml
rm /tmp/traefik.env.yaml
```

### 3c. Encrypt app secrets

```bash
cat > /tmp/app.env.yaml <<EOF
SESSION_SECRET: $(openssl rand -hex 32)
ADMIN_PASSWORD: your-strong-admin-password
S3_ACCESS_KEY_ID: your-object-storage-access-key
S3_SECRET_ACCESS_KEY: your-object-storage-secret-key
borg_path: your-borg-repo-path
borg_passphrase: $(openssl rand -base64 32)
EOF

SOPS_AGE_KEY_FILE=./age.key sops -e /tmp/app.env.yaml > reporting-tool/.env.sops.yaml
rm /tmp/app.env.yaml
```

Witness runtime values such as `ORIGIN`, `DATABASE_URL`, and the S3 endpoint,
bucket, and region are injected by Ansible from `secrets.sops.yaml` and the
playbook itself. They do not need to be stored in `reporting-tool/.env.sops.yaml`.

### 3d. Encrypt global infrastructure secrets

Create or update [`secrets.sops.yaml`](../secrets.sops.yaml) with at least:

```yaml
domain: your-domain.example.com
letsencrypt_email: ops@your-domain.example.com
s3_endpoint: https://your-object-storage-endpoint
s3_bucket: your-object-storage-bucket
s3_region: auto
borg_host: your-borg-host
borg_user: your-borg-user
```

Edit it with:

```bash
task secrets:edit FILE=secrets.sops.yaml
```

### 3e. Create Authentik secrets

The default `task deploy` path includes Authentik, so create
[`authentik/.env.sops.yaml`](../authentik/.env.sops.yaml) with at least:

```yaml
PG_PASS: your-strong-postgres-password
AUTHENTIK_SECRET_KEY: your-long-random-authentik-secret
AUTHENTIK_BOOTSTRAP_PASSWORD: your-strong-bootstrap-password
borg_path: your-authentik-borg-repo-path
borg_passphrase: your-authentik-borg-passphrase
```

Use a different `borg_path` than Witness so Authentik gets its own Borg repo on
the same Hetzner storage box.

Optional keys:

- `AUTHENTIK_BOOTSTRAP_EMAIL`
- `AUTHENTIK_ADMIN_USERNAME`
- `AUTHENTIK_ADMIN_PASSWORD`
- `AUTHENTIK_ADMIN_EMAIL`

Edit it with:

```bash
task secrets:edit FILE=authentik/.env.sops.yaml
```

Generate the two persistent secrets once on your local machine and keep them in
SOPS:

```bash
openssl rand -base64 36   # PG_PASS example
openssl rand -base64 60   # AUTHENTIK_SECRET_KEY example
openssl rand -base64 32   # borg_passphrase example
```

During deploy, Ansible renders these values into a temporary
`/opt/vps-devops/authentik/.env`, performs the Docker Compose operations, and
removes the file again afterward.

### 3f. Add the submodule

Already done — `reporting-tool/app` is pinned to the commit at the time this repo was set up.
To update it to a newer commit see the day-to-day operations section below.

### 3g. Commit and push

```bash
git add .sops.yaml secrets.sops.yaml traefik/.env.sops.yaml authentik/.env.sops.yaml reporting-tool/.env.sops.yaml reporting-tool/app
git commit -m "chore: initial repo setup with encrypted secrets and app submodule"
git push
```

---

## Step 4 — First deploy and Borg initialization

```bash
task deploy
```

This will:
1. Configure or update Traefik
2. Configure or update Authentik
3. Configure Witness
4. Initialize the remote Borg repositories automatically if they do not exist yet
5. Build and start the Witness app

Verify:

```bash
curl -I https://witness.your-domain.example.com
curl -I https://traefik.your-domain.example.com
```

---

## Day-to-day operations

### Deploy a new app version

```bash
cd reporting-tool/app
git fetch origin
git checkout <new-commit-sha>
cd ../..
git add reporting-tool/app
git commit -m "chore: update reporting-tool to <new-commit-sha>"
git push
task deploy
```

### Update infra config (Traefik, firewall, etc.)

Make your changes, commit, push, then:

```bash
task deploy
```

### Update encrypted secrets

```bash
SOPS_AGE_KEY_FILE=./age.key sops reporting-tool/.env.sops.yaml
git add reporting-tool/.env.sops.yaml
git commit -m "chore: update app secrets"
git push
task deploy
```

### Add a new age key recipient (e.g. a teammate)

```bash
# In .sops.yaml, add their public key separated by a comma:
# age: age1<your-key>,age1<teammate-key>

task secrets:updatekeys
git add -A && git commit -m "chore: add teammate age key"
```

### Schedule nightly backups (optional)

```bash
task ssh
# then run:
# crontab -e
# Add:
# 0 3 * * * bash /opt/vps-devops/scripts/backup-reporting-tool.sh >> /var/log/borg-backup.log 2>&1
# 0 4 * * * bash /opt/vps-devops/scripts/backup-authentik.sh >> /var/log/borg-backup.log 2>&1
```

### Inspect available Witness backups

```bash
task witness:backup:info
```

### Inspect available Authentik backups

```bash
task authentik:backup:info
```
