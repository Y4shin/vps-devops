# VPS DevOps — Setup Guide

End-to-end walkthrough for provisioning a fresh Ubuntu 24.04 VPS and deploying
the full stack (Traefik + reporting-tool) for the first time.

---

## Prerequisites

Install these on your **local machine** before starting:

| Tool | Install |
|---|---|
| `git` | `brew install git` / distro package |
| `gpg` | pre-installed on most systems / `brew install gnupg` |
| `sops` | `brew install sops` / [GitHub releases](https://github.com/getsops/sops/releases) |
| `ansible` | `brew install ansible` / `pip install ansible` |
| `community.sops` + `community.docker` collections | see below |

```bash
ansible-galaxy collection install community.sops community.docker community.general ansible.posix
```

Verify:
```bash
age --version && sops --version && ansible --version
```

---

## Step 1 — GPG key

SOPS uses your local GPG key for encryption/decryption. Since all decryption happens on your
local machine (via `delegate_to: localhost` in the Ansible playbook), the VPS never needs
access to this key.

The key has already been generated (`vps-devops@local`, fingerprint `1E499701FC8E2CC54A3C5F4CD4627AD9C08F6B94`)
and is stored in your local GPG keyring. It is already set in `.sops.yaml`.

**Back it up** — if you lose it you cannot decrypt the secrets:

```bash
gpg --export-secret-keys --armor vps-devops@local > vps-devops-gpg.key
# Store this somewhere safe (password manager, encrypted drive, etc.)
# Do NOT commit it to the repo
```

---

## Step 2 — Bootstrap the server (Ansible)

The initial bootstrap playbook now does only the first handoff:
it creates the `deploy` user and installs its SSH key so the rest of the setup
can happen over the normal deploy-user path.

### 2a. Configure the inventory

The server IP is stored encrypted in [`ansible/inventory.sops.yaml`](../ansible/inventory.sops.yaml).
To update it:

```bash
task secrets-edit FILE=ansible/inventory.sops.yaml
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

```yaml
creation_rules:
  - path_regex: \.env\.sops\.yaml$
    age: age1xxxxxxxxxx...   # your public key from Step 1
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

sops -e /tmp/traefik.env.yaml > traefik/.env.sops.yaml
rm /tmp/traefik.env.yaml
```

### 3c. Encrypt app secrets

```bash
cat > /tmp/app.env.yaml <<EOF
ORIGIN: https://your-domain.example.com
DATABASE_URL: file:/data/app.db
SESSION_SECRET: $(openssl rand -hex 32)
ADMIN_PASSWORD: your-strong-admin-password
EOF

sops -e /tmp/app.env.yaml > reporting-tool/.env.sops.yaml
rm /tmp/app.env.yaml
```

### 3d. Add the submodule

Already done — `reporting-tool/app` is pinned to the commit at the time this repo was set up.
To update it to a newer commit see the day-to-day operations section below.

### 3e. Commit and push

```bash
git add .sops.yaml traefik/.env.sops.yaml reporting-tool/.env.sops.yaml reporting-tool/app
git commit -m "chore: initial repo setup with encrypted secrets and app submodule"
git push
```

---

## Step 4 — Clone repo and initialise Borg on the VPS

```bash
task ssh

git clone --recurse-submodules git@github.com:your-org/vps-devops.git /opt/vps-devops

borg init --encryption=repokey /opt/borg-backups/reporting-tool
# You will be prompted for a passphrase — store it securely.

exit
```

---

## Step 5 — First deploy

From your local machine:

```bash
task deploy
```

This will:
1. Pull the repo on the server
2. Start Traefik (and obtain a TLS certificate)
3. Detect no previous deploy → backup (first archive) → build and start the app

Verify:

```bash
curl -I https://your-domain.example.com
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
sops reporting-tool/.env.sops.yaml   # opens in $EDITOR, re-encrypts on save
git add reporting-tool/.env.sops.yaml
git commit -m "chore: update app secrets"
git push
task deploy
```

### Add a new age key recipient (e.g. a teammate)

```bash
# In .sops.yaml, add their public key separated by a comma:
# age: age1<your-key>,age1<teammate-key>

sops updatekeys traefik/.env.sops.yaml
sops updatekeys reporting-tool/.env.sops.yaml
git add -A && git commit -m "chore: add teammate age key"
```

### Schedule nightly backups (optional)

```bash
task ssh
# then run:
# crontab -e
# Add:
# 0 3 * * * bash /opt/vps-devops/scripts/backup-reporting-tool.sh >> /var/log/borg-backup.log 2>&1
```
