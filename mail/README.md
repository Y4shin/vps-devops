# Outbound Mail Relay

This directory contains the repo-managed outbound-only SMTP relay setup based on
Docker Mailserver.

The intent is to let local services such as Authentik send notification emails
without introducing a third-party relay provider and without running a full
public mailbox stack.

## Required secrets

Add the `sops_mail_secrets` dict to
`ansible/inventories/prod/group_vars/all.sops.yaml` before the first deploy with
at least:

```yaml
sops_mail_secrets:
  MAIL_SUBMISSION_PASSWORD: a-strong-random-password
```

Optional keys:

- `MAIL_DOMAIN`
- `MAIL_HOSTNAME`
- `MAIL_SUBMISSION_ACCOUNT`
- `MAIL_POSTMASTER_ADDRESS`
- `MAIL_AUTHENTIK_FROM`

Defaults:

- `MAIL_DOMAIN` defaults to `sops_secrets.domain`
- `MAIL_HOSTNAME` defaults to `mail.<MAIL_DOMAIN>`
- `MAIL_SUBMISSION_ACCOUNT` defaults to `authentik@<MAIL_DOMAIN>`
- `MAIL_POSTMASTER_ADDRESS` defaults to `postmaster@<MAIL_DOMAIN>`
- `MAIL_AUTHENTIK_FROM` defaults to `authentik@<MAIL_DOMAIN>`

## Common commands

```bash
task deploy:mail
task ssh:mail
task mail:dkim:info
```

The deployed relay uses a dedicated Docker network named `mail` and does not
publish SMTP ports publicly by default. Authentik reaches it internally as
`mailserver:25`.
