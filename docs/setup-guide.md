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

### 2a. Configure the connection

The server IP is stored encrypted in the `sops_connection` dict inside
[`ansible/inventories/prod/group_vars/all.sops.yaml`](../ansible/inventories/prod/group_vars/all.sops.yaml).
To update it:

```bash
sops ansible/inventories/prod/group_vars/all.sops.yaml
```

That `sops_connection` dict should also contain the privilege-escalation
settings used by the deploy-time playbooks:

```yaml
sops_connection:
  ansible_host: ...
  ansible_become_password: ...
```

The remaining connection settings (`ansible_user: deploy`,
`ansible_become_method: su`, `ansible_become_user: root`) are configured by the
inventory itself.

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
escalation settings stored in the encrypted `sops_connection` dict. It applies packages, Docker, firewall rules, SSH
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

### 3b. Plan Traefik dashboard access in Authentik

The Traefik dashboard is protected by Authentik group membership, not by a
separate Traefik basic-auth password file.

During `task deploy`, the Authentik blueprints in this repo create:

- the group `traefik-dashboard-access`
- an Authentik application/provider for `https://traefik.<domain>`

On migration from the old basic-auth setup, the deploy also seeds the new group
from the current Authentik superusers if the group is still empty, so existing
admins do not lose access on cutover.

After deploy, manage dashboard access by adding or removing users from
`traefik-dashboard-access` in Authentik.

If you still have an old local `traefik/.env.sops.yaml` from the basic-auth
setup, it is no longer used and can be removed.

### 3c. Encrypt app secrets

Add the `sops_reporting_tool_secrets` dict to
[`ansible/inventories/prod/group_vars/all.sops.yaml`](../ansible/inventories/prod/group_vars/all.sops.yaml)
with at least:

```yaml
sops_reporting_tool_secrets:
  SESSION_SECRET: a-long-random-secret
  ADMIN_AUTH_MODE: oidc
  ADMIN_OIDC_CLIENT_SECRET: a-long-random-secret
  S3_ACCESS_KEY_ID: your-object-storage-access-key
  S3_SECRET_ACCESS_KEY: your-object-storage-secret-key
  borg_path: your-borg-repo-path
  borg_passphrase: a-long-random-passphrase
```

Edit the file with:

```bash
sops ansible/inventories/prod/group_vars/all.sops.yaml
```

Generate the random secrets locally, for example:

```bash
openssl rand -hex 32     # SESSION_SECRET / ADMIN_OIDC_CLIENT_SECRET example
openssl rand -base64 32  # borg_passphrase example
```

Witness runtime values such as `ORIGIN`, `DATABASE_URL`, and the S3 endpoint,
bucket, and region are injected by Ansible from `sops_secrets` and the
playbook itself. They do not need to be stored in `sops_reporting_tool_secrets`.

Witness admin login is now intended to use Authentik OIDC instead of a local
`ADMIN_PASSWORD`.

During deploy, this repo will create:

- the Authentik group `reporting-tool-admin-access`
- an Authentik OIDC application/provider for `https://witness.<domain>/admin/login`

Access to the Authentik application is restricted to members of
`reporting-tool-admin-access`.

The Witness deploy injects `ADMIN_OIDC_ALLOWED_GROUPS=reporting-tool-admin-access`
at runtime, so admin membership is managed centrally in Authentik instead of by
per-user email or subject lists in `sops_reporting_tool_secrets`.

### 3d. Encrypt global infrastructure secrets

Add or update the `sops_secrets` dict in
[`ansible/inventories/prod/group_vars/all.sops.yaml`](../ansible/inventories/prod/group_vars/all.sops.yaml)
with at least:

```yaml
sops_secrets:
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
sops ansible/inventories/prod/group_vars/all.sops.yaml
```

### 3e. Create Authentik secrets

The default `task deploy` path includes Authentik, so add the
`sops_authentik_secrets` dict to
[`ansible/inventories/prod/group_vars/all.sops.yaml`](../ansible/inventories/prod/group_vars/all.sops.yaml)
with at least:

```yaml
sops_authentik_secrets:
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
sops ansible/inventories/prod/group_vars/all.sops.yaml
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

### 3f. Optional: create outbound mail relay secrets

If you want Authentik to send email through a local outbound relay on this VPS,
add the `sops_mail_secrets` dict to
[`ansible/inventories/prod/group_vars/all.sops.yaml`](../ansible/inventories/prod/group_vars/all.sops.yaml)
with at least:

```yaml
sops_mail_secrets:
  MAIL_SUBMISSION_PASSWORD: your-strong-random-password
```

Optional values:

```yaml
sops_mail_secrets:
  MAIL_DOMAIN: your-domain.example.com
  MAIL_HOSTNAME: mail.your-domain.example.com
  MAIL_SUBMISSION_ACCOUNT: authentik@your-domain.example.com
  MAIL_POSTMASTER_ADDRESS: postmaster@your-domain.example.com
  MAIL_AUTHENTIK_FROM: authentik@your-domain.example.com
```

Deploy it later with:

```bash
task deploy:mail
task deploy:authentik
```

### 3g. Add the submodule

Already done — `reporting-tool/app` is pinned to the commit at the time this repo was set up.
To update it to a newer commit see the day-to-day operations section below.

### 3h. Commit and push

```bash
git add .sops.yaml ansible/inventories/prod/group_vars/all.sops.yaml reporting-tool/app
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

For `https://traefik.your-domain.example.com`, expect an Authentik-driven
redirect/login flow rather than an HTTP basic-auth prompt.

After deploy, add your Witness admins to the Authentik group
`reporting-tool-admin-access`. That group gates the Authentik OIDC application
used by `https://witness.<domain>/admin/login`.

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

All secrets live in a single SOPS-encrypted file. Edit the relevant
`sops_<svc>_secrets` dict inside it:

```bash
SOPS_AGE_KEY_FILE=./age.key sops ansible/inventories/prod/group_vars/all.sops.yaml
git add ansible/inventories/prod/group_vars/all.sops.yaml
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

### Scheduled nightly backups

Backup scheduling is managed by the service playbooks.

- `task deploy:authentik` installs and enables `authentik-backup.timer` for `04:00`
- `task deploy:witness` installs and enables `reporting-tool-backup.timer` for `04:30`

To inspect them on the server:

```bash
systemctl status authentik-backup.timer
systemctl status reporting-tool-backup.timer
systemctl list-timers --all | grep backup
```

### Inspect available Witness backups

```bash
task witness:backup:info
```

### Inspect available Authentik backups

```bash
task authentik:backup:info
```
