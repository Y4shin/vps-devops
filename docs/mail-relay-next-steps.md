# Mail Relay Next Steps

This is the practical rollout checklist for enabling the local outbound mail
relay on the VPS and hooking Authentik up to it.

## 1. Add the encrypted mail secrets

Add the `sops_mail_secrets` dict to
`ansible/inventories/prod/group_vars/all.sops.yaml`.

Minimum required content:

```yaml
sops_mail_secrets:
  MAIL_SUBMISSION_PASSWORD: your-strong-random-password
```

Recommended explicit values for your setup:

```yaml
sops_mail_secrets:
  MAIL_DOMAIN: pplattner.de
  MAIL_HOSTNAME: mail.pplattner.de
  MAIL_SUBMISSION_ACCOUNT: authentik@pplattner.de
  MAIL_POSTMASTER_ADDRESS: postmaster@pplattner.de
  MAIL_AUTHENTIK_FROM: authentik@pplattner.de
  MAIL_SUBMISSION_PASSWORD: your-strong-random-password
```

## 2. Create the DNS records

Create these forward DNS records:

```txt
mail.pplattner.de.    A      <your-server-ipv4>
mail.pplattner.de.    AAAA   <your-server-ipv6>
```

Set reverse DNS at your VPS provider:

- IPv4 PTR -> `mail.pplattner.de`
- IPv6 PTR -> `mail.pplattner.de`

### Detailed forward DNS steps

At your DNS provider for `pplattner.de`, create:

1. An `A` record:
   - Name/Host: `mail`
   - Type: `A`
   - Value: your VPS IPv4 address

2. An `AAAA` record:
   - Name/Host: `mail`
   - Type: `AAAA`
   - Value: your VPS IPv6 address

After saving them, verify:

```bash
dig +short A mail.pplattner.de
dig +short AAAA mail.pplattner.de
```

Expected result:

- the `A` lookup returns your VPS IPv4
- the `AAAA` lookup returns your VPS IPv6

### Detailed reverse DNS steps

Reverse DNS is not configured in your normal DNS zone. It must be set where the
IP addresses are assigned, which in your case is the VPS provider.

For Hetzner, the reverse DNS entry should be:

- IPv4 PTR -> `mail.pplattner.de`
- IPv6 PTR -> `mail.pplattner.de`

For IPv4 in the Hetzner UI:

1. Open the server in the Hetzner console
2. Go to the networking or IP section
3. Find the public IPv4
4. Set the reverse DNS / PTR field to:

```txt
mail.pplattner.de
```

For IPv6 in the Hetzner UI:

1. Open the server in the Hetzner console
2. Go to the IPv6 section
3. Find the assigned IPv6 subnet and the specific server address
4. For the server address `2a01:4f8:...::1`, set the reverse DNS field to:

```txt
mail.pplattner.de
```

In Hetzner’s IPv6 UI, this is often entered against the interface identifier
such as `::1`, not the whole expanded IPv6 address.

After saving, verify with public resolvers:

```bash
dig +short -x <your-ipv4> @1.1.1.1
dig +short -x <your-ipv6> @1.1.1.1
dig +short -x <your-ipv4> @8.8.8.8
dig +short -x <your-ipv6> @8.8.8.8
```

Expected result for all PTR lookups:

```txt
mail.pplattner.de.
```

### Forward-confirmed reverse DNS check

You want both of these to be true:

1. Forward DNS:

```txt
mail.pplattner.de -> your IPv4 and/or IPv6
```

2. Reverse DNS:

```txt
your IPv4 -> mail.pplattner.de
your IPv6 -> mail.pplattner.de
```

That is often called forward-confirmed reverse DNS, or FCrDNS, and it is a very
common expectation for mail delivery.

### Apex domain vs mail host

Do not point the PTR to `pplattner.de` for this setup.

Use:

```txt
PTR -> mail.pplattner.de
```

while still sending visible mail from:

```txt
authentik@pplattner.de
```

That keeps the SMTP server identity separate from the domain’s main website
hostname.

## 3. Deploy the mail relay

Run:

```bash
task deploy:mail
```

This will:

1. Create `/opt/vps-devops/mail`
2. Start Docker Mailserver in SMTP-only mode
3. Create the local sender account
4. Generate DKIM keys for `pplattner.de`

## 4. Retrieve the DKIM DNS record

Run:

```bash
task mail:dkim:info
```

Copy the generated DKIM TXT record into your DNS provider.

## 5. Add SPF and DMARC

Recommended starting SPF:

```txt
pplattner.de.         TXT    "v=spf1 a:mail.pplattner.de -all"
```

Recommended starting DMARC:

```txt
_dmarc.pplattner.de.  TXT    "v=DMARC1; p=none; rua=mailto:postmaster@pplattner.de"
```

## 6. Redeploy Authentik with SMTP enabled

Run:

```bash
task deploy:authentik
```

When `sops_mail_secrets` is defined, the Authentik deploy will automatically
inject SMTP settings so Authentik sends through the local relay.

## 7. Test email delivery

SSH into the Authentik directory:

```bash
task ssh:authentik
```

Then run:

```bash
docker compose exec worker ak test_email your-address@example.com
```

## 8. Verify DNS and mail identity

Check forward DNS:

```bash
dig +short A mail.pplattner.de
dig +short AAAA mail.pplattner.de
```

Check reverse DNS:

```bash
dig +short -x <your-ipv4>
dig +short -x <your-ipv6>
```

Both PTR records should return:

```txt
mail.pplattner.de.
```

The mail server should also identify itself with that same hostname in SMTP
`HELO`/`EHLO`.

## 9. Watch for delivery issues

If mail does not arrive:

1. Check whether your VPS provider blocks outbound port `25`
2. Inspect the mail container logs:

```bash
task ssh:mail
docker compose logs --tail=200
```

3. Check whether DKIM, SPF, and PTR are all in place
4. Check whether the VPS IP appears on any blacklist

## Notes

- The SMTP server identity is `mail.pplattner.de`
- The visible sender can still be `authentik@pplattner.de`
- This setup is for outbound app notifications, not for inbox hosting
