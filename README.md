# MailStack Wizard

A beginner-friendly interactive installer for a small self-hosted email server on Ubuntu/Debian.

It was designed from a real deployment where the **website and mail server live on the same VPS**:

- `example.com` → existing website on Nginx
- `mail.example.com` → Postfix + Dovecot
- `webmail.example.com` → Roundcube
- Same public IPv4 can serve all three.

## What it installs

- Postfix - SMTP receiving/sending
- Dovecot - IMAP
- OpenDKIM - DKIM signing
- Let's Encrypt / Certbot - TLS
- Fail2ban - basic protection
- Roundcube - webmail
- Nginx - Roundcube vhost
- Swaks - SMTP testing tools

## Important design decisions

The wizard does **not** replace your existing website Nginx virtual host.

Mail uses separate ports:

- 25 - server-to-server SMTP
- 587 - authenticated SMTP submission
- 993 - IMAPS
- 8891 - OpenDKIM, localhost only

Website ports stay:

- 80 - HTTP
- 443 - HTTPS

## Before running

You need:

1. Ubuntu/Debian VPS.
2. Root or sudo access.
3. A domain whose DNS you control.
4. A public IPv4.
5. Ability to configure PTR/reverse DNS at the VPS provider.
6. Ports 25, 587 and 993 permitted by the hosting provider.

## Recommended DNS

For `example.com` and server IPv4 `203.0.113.10`:

```text
A     mail        203.0.113.10
A     webmail     203.0.113.10
MX    @           mail.example.com.       priority 10
TXT   @           v=spf1 a mx ip4:203.0.113.10 ~all
TXT   _dmarc      v=DMARC1; p=none; rua=mailto:dmarc@example.com
```

PTR at the VPS provider:

```text
203.0.113.10 -> mail.example.com
```

Keep the website records (`@`, `www`) unchanged.

## Run

```bash
chmod +x mailstack-wizard.sh
sudo ./mailstack-wizard.sh
```

The wizard will pause at DNS/DKIM checkpoints.

## First mailbox model

This version intentionally uses a simple system-user mailbox model.

For example:

```text
Linux username: info
Public email:   info@example.com
```

Roundcube login:

```text
Username: info
Password: Linux user's password
```

Inside Roundcube, go to:

**Settings → Identities**

and ensure the sender identity is:

```text
info@example.com
```

not:

```text
info@mail.example.com
```

That distinction is essential for SPF/DKIM/DMARC alignment.

## Deliverability validation

After sending a test message to Gmail, use **Show original**.

Expected:

```text
SPF: PASS
DKIM: PASS
DMARC: PASS
```

Useful diagnostics:

```bash
sudo postqueue -p
sudo grep -E 'DKIM-Signature|status=sent|status=bounced|status=deferred' /var/log/mail.log | tail -n 50
sudo opendkim-testkey -d example.com -s default -vvv
sudo fail2ban-client status
sudo certbot renew --dry-run
```

## Mailbox Manager

An optional utility to manage Linux-user-backed mailboxes (create, list, change passwords, test, repair, disable/enable, remove). It assumes a simple Postfix+Dovecot setup where each mailbox maps to a system user and Maildir under `/home/<user>/Maildir`.

Install:

```bash
chmod +x mailbox-manager.sh
sudo mv mailbox-manager.sh /usr/local/sbin/mailbox-manager
```

Run interactively:

```bash
sudo mailbox-manager
```

Direct commands:

```bash
sudo mailbox-manager add support
sudo mailbox-manager list
sudo mailbox-manager passwd support
sudo mailbox-manager info support
sudo mailbox-manager test support
sudo mailbox-manager repair support
sudo mailbox-manager disable support
sudo mailbox-manager enable support
sudo mailbox-manager remove support
```

Domain detection can be overridden with `MAIL_DOMAIN=example.com`.

## Notes

- SPF/DKIM/DMARC passing does not guarantee Gmail Inbox placement. A new VPS IP may have little reputation and initially land in spam.
- Do not send bulk email from a fresh VPS.
- For business-critical outbound delivery, consider using a reputable SMTP relay while keeping Dovecot/Roundcube for mailbox hosting.
- This script is aimed at a small single-domain deployment. For many domains/users, move to virtual mailboxes backed by a database rather than Linux system users.
