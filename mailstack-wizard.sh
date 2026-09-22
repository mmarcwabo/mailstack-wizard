#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# MailStack Wizard
# Postfix + Dovecot + OpenDKIM + Let's Encrypt + Fail2ban
# + Roundcube behind Nginx
#
# Target OS: Ubuntu/Debian
# Designed for a VPS that may ALREADY host a website with Nginx.
#
# IMPORTANT:
# - Run with sudo/root.
# - DNS and PTR/rDNS still require manual changes at your DNS/VPS provider.
# - The wizard creates timestamped backups before changing config files.
# ============================================================

VERSION="1.1.0"
BACKUP_ROOT="/root/mailstack-wizard-backups"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TS"
LOG_FILE="/var/log/mailstack-wizard.log"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'

say()   { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
die()   { echo -e "${C_RED}✘ $*${C_RESET}" >&2; exit 1; }
title() { echo -e "\n${C_BOLD}$*${C_RESET}\n"; }

trap 'echo -e "\n${C_RED}Wizard stopped on line $LINENO.${C_RESET} Check: $LOG_FILE"' ERR

exec > >(tee -a "$LOG_FILE") 2>&1

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this wizard with: sudo bash $0"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local prompt="${1:-Continue?}"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

prompt_default() {
  local __var="$1" prompt="$2" default="$3" value
  read -r -p "$prompt [$default]: " value
  printf -v "$__var" '%s' "${value:-$default}"
}

validate_domain() {
  [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
}

set_kv_postconf() {
  postconf -e "$1 = $2"
}

ensure_line() {
  local file="$1" line="$2"
  grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

show_step() {
  title "STEP $1 — $2"
}

require_root
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"

title "MailStack Wizard v$VERSION"
echo "This wizard installs and configures:"
echo "  • Postfix (SMTP)"
echo "  • Dovecot (IMAP)"
echo "  • OpenDKIM"
echo "  • Let's Encrypt TLS"
echo "  • Fail2ban"
echo "  • Roundcube on Nginx"
echo
warn "It is designed not to replace an existing Nginx website configuration."
echo

# ------------------------------------------------------------
# 1. Collect configuration
# ------------------------------------------------------------
show_step 1 "Collect configuration"

DEFAULT_DOMAIN=""
if hostname -f 2>/dev/null | grep -q '\.'; then
  DEFAULT_DOMAIN="$(hostname -f | awk -F. '{if (NF>=2) print $(NF-1)"."$NF}')"
fi
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-example.com}"

prompt_default ROOT_DOMAIN "Main email domain" "$DEFAULT_DOMAIN"
validate_domain "$ROOT_DOMAIN" || die "Invalid domain: $ROOT_DOMAIN"

prompt_default MAIL_HOST "Mail hostname" "mail.$ROOT_DOMAIN"
prompt_default WEBMAIL_HOST "Roundcube hostname" "webmail.$ROOT_DOMAIN"

DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
prompt_default SERVER_IP "Public IPv4 of this VPS" "${DEFAULT_IP:-}"
[[ -n "$SERVER_IP" ]] || die "Server IPv4 is required."

prompt_default MAIL_USER "First mailbox local username" "info"
prompt_default DISPLAY_NAME "Roundcube display/product name" "$(echo "$ROOT_DOMAIN" | awk -F. '{print toupper(substr($1,1,1)) substr($1,2)}') Webmail"
prompt_default SSH_PORT "SSH port" "22"

MAIL_ADDRESS="$MAIL_USER@$ROOT_DOMAIN"

echo
echo "Configuration:"
echo "  Domain       : $ROOT_DOMAIN"
echo "  Mail server  : $MAIL_HOST"
echo "  Webmail      : $WEBMAIL_HOST"
echo "  Server IPv4  : $SERVER_IP"
echo "  First mailbox: $MAIL_ADDRESS"
echo "  SSH port     : $SSH_PORT"
echo
confirm "Proceed with this configuration?" || exit 0

# ------------------------------------------------------------
# 2. Preflight
# ------------------------------------------------------------
show_step 2 "Preflight checks"

source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "Supported OS: ${PRETTY_NAME:-$ID}" ;;
  *) die "This wizard currently supports Ubuntu/Debian only." ;;
esac

if systemctl is-active --quiet nginx; then
  ok "Nginx is already running."
else
  warn "Nginx is not active. It will be installed/enabled."
fi

if systemctl is-active --quiet apache2; then
  warn "Apache is currently active."
  warn "This wizard uses Nginx for Roundcube. Apache may conflict on ports 80/443."
  confirm "Continue anyway?" || exit 1
fi

echo
say "Current listeners:"
ss -ltnp | grep -E ':22|:80|:443|:25|:587|:993' || true

mkdir -p "$BACKUP_DIR"
backup_file /etc/hosts
backup_file /etc/postfix/main.cf
backup_file /etc/postfix/master.cf
backup_file /etc/dovecot/conf.d/10-mail.conf
backup_file /etc/dovecot/conf.d/10-auth.conf
backup_file /etc/dovecot/conf.d/10-master.conf
backup_file /etc/dovecot/conf.d/10-ssl.conf
backup_file /etc/opendkim.conf
backup_file /etc/fail2ban/jail.local
ok "Backups will be stored in $BACKUP_DIR"

# ------------------------------------------------------------
# 3. DNS / PTR checkpoint
# ------------------------------------------------------------
show_step 3 "DNS and reverse DNS checkpoint"

cat <<EOF

At your DNS provider, create/verify:

  A     mail        $SERVER_IP
  A     webmail     $SERVER_IP
  MX    @           $MAIL_HOST.       priority 10

  TXT   @           v=spf1 a mx ip4:$SERVER_IP ~all
  TXT   _dmarc      v=DMARC1; p=none; rua=mailto:$MAIL_ADDRESS

At your VPS provider, set PTR / reverse DNS:

  $SERVER_IP  ->  $MAIL_HOST

Keep your existing website records for:
  $ROOT_DOMAIN
  www.$ROOT_DOMAIN

Do NOT replace your website A records merely to install mail.
EOF

if command_exists dig; then
  echo
  say "Current DNS observations:"
  echo -n "$MAIL_HOST -> "; dig +short A "$MAIL_HOST" | tr '\n' ' '; echo
  echo -n "MX $ROOT_DOMAIN -> "; dig +short MX "$ROOT_DOMAIN" | tr '\n' ' '; echo
  echo -n "PTR $SERVER_IP -> "; dig -x "$SERVER_IP" +short | tr '\n' ' '; echo
fi

confirm "Have you created/verified A, MX and PTR records?" || die "Complete DNS/PTR first, then rerun."

# ------------------------------------------------------------
# 4. Packages
# ------------------------------------------------------------
show_step 4 "Install required packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  nginx \
  postfix \
  dovecot-core dovecot-imapd \
  opendkim opendkim-tools \
  certbot python3-certbot-nginx \
  fail2ban \
  swaks \
  dnsutils \
  ca-certificates \
  mariadb-server \
  roundcube roundcube-core roundcube-mysql \
  php-fpm php-mysql php-intl php-mbstring php-xml php-curl php-zip

ok "Packages installed."

# ------------------------------------------------------------
# 5. Host identity
# ------------------------------------------------------------
show_step 5 "Set server identity"

OLD_HOST="$(hostname -f 2>/dev/null || hostname)"
if nginx -T 2>/dev/null | grep -Fq "$OLD_HOST"; then
  warn "Nginx configuration references old hostname: $OLD_HOST"
  warn "Review before changing the OS hostname."
  confirm "Still change OS hostname to $MAIL_HOST?" || warn "Skipping OS hostname change."
  CHANGE_HOSTNAME=$?
else
  CHANGE_HOSTNAME=0
fi

if [[ "$CHANGE_HOSTNAME" -eq 0 ]]; then
  hostnamectl set-hostname "$MAIL_HOST"
  if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
    sed -i -E "s|^127\.0\.1\.1\s+.*|127.0.1.1 $MAIL_HOST mail|" /etc/hosts
  else
    echo "127.0.1.1 $MAIL_HOST mail" >> /etc/hosts
  fi
  ok "OS hostname set to $MAIL_HOST"
fi

# ------------------------------------------------------------
# 6. Create mailbox user
# ------------------------------------------------------------
show_step 6 "Create first mailbox"

if id "$MAIL_USER" >/dev/null 2>&1; then
  ok "Local user '$MAIL_USER' already exists."
else
  echo "Create password for mailbox $MAIL_ADDRESS:"
  adduser "$MAIL_USER"
fi

install -d -m 700 -o "$MAIL_USER" -g "$MAIL_USER" "/home/$MAIL_USER/Maildir"
install -d -m 700 -o "$MAIL_USER" -g "$MAIL_USER" \
  "/home/$MAIL_USER/Maildir/cur" \
  "/home/$MAIL_USER/Maildir/new" \
  "/home/$MAIL_USER/Maildir/tmp"

# ------------------------------------------------------------
# 7. Postfix
# ------------------------------------------------------------
show_step 7 "Configure Postfix"

set_kv_postconf myhostname "$MAIL_HOST"
set_kv_postconf mydomain "$ROOT_DOMAIN"
set_kv_postconf myorigin '$mydomain'
set_kv_postconf inet_interfaces all
set_kv_postconf inet_protocols ipv4
set_kv_postconf mydestination '$myhostname, localhost.$mydomain, localhost, $mydomain'
set_kv_postconf mynetworks '127.0.0.0/8'
set_kv_postconf home_mailbox 'Maildir/'
set_kv_postconf smtpd_banner '$myhostname ESMTP'
set_kv_postconf smtpd_sasl_type dovecot
set_kv_postconf smtpd_sasl_path private/auth
set_kv_postconf smtpd_sasl_auth_enable yes
set_kv_postconf smtpd_sasl_security_options noanonymous
set_kv_postconf smtpd_recipient_restrictions 'permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
set_kv_postconf smtpd_tls_security_level may
set_kv_postconf smtp_tls_security_level may

# Enable submission on 587 if not already enabled.
if ! grep -qE '^submission\s+inet\s+' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF'

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
EOF
fi

postfix check
systemctl enable postfix
systemctl restart postfix
ok "Postfix configured."

# ------------------------------------------------------------
# 8. Dovecot
# ------------------------------------------------------------
show_step 8 "Configure Dovecot"

sed -i -E 's|^[# ]*mail_location\s*=.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
grep -q '^mail_location = maildir:~/Maildir' /etc/dovecot/conf.d/10-mail.conf || \
  echo 'mail_location = maildir:~/Maildir' >> /etc/dovecot/conf.d/10-mail.conf

sed -i -E 's|^[# ]*disable_plaintext_auth\s*=.*|disable_plaintext_auth = yes|' /etc/dovecot/conf.d/10-auth.conf
sed -i -E 's|^[# ]*auth_mechanisms\s*=.*|auth_mechanisms = plain login|' /etc/dovecot/conf.d/10-auth.conf
if grep -qE '^[# ]*auth_username_format\s*=' /etc/dovecot/conf.d/10-auth.conf; then
  sed -i -E 's|^[# ]*auth_username_format\s*=.*|auth_username_format = %n|' /etc/dovecot/conf.d/10-auth.conf
else
  echo 'auth_username_format = %n' >> /etc/dovecot/conf.d/10-auth.conf
fi

# Own drop-in so we never rewrite Debian's service auth { } block or
# change ownership of /var/spool/postfix/private.
cat > /etc/dovecot/conf.d/99-postfix-auth.conf <<'EOF'
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF
chown postfix:root /var/spool/postfix/private
chmod 700 /var/spool/postfix/private

dovecot -n >/dev/null
systemctl enable dovecot
systemctl restart dovecot
ok "Dovecot configured."

# ------------------------------------------------------------
# 9. TLS certificate for mail hostname
# ------------------------------------------------------------
show_step 9 "Issue TLS certificate for mail"

systemctl enable --now nginx

# certbot --nginx needs a server_name for the mail host.
MAIL_NGINX="/etc/nginx/sites-available/$MAIL_HOST"
if [[ ! -f "$MAIL_NGINX" ]]; then
  cat > "$MAIL_NGINX" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MAIL_HOST;
    location / { return 404; }
}
EOF
  ln -sfn "$MAIL_NGINX" "/etc/nginx/sites-enabled/$MAIL_HOST"
fi
nginx -t
systemctl reload nginx

if certbot certificates 2>/dev/null | grep -q "Certificate Name: $MAIL_HOST"; then
  ok "Existing certificate found for $MAIL_HOST."
else
  certbot certonly --nginx -d "$MAIL_HOST"
fi

CERT_DIR="/etc/letsencrypt/live/$MAIL_HOST"
[[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]] || die "Certificate files not found in $CERT_DIR"

set_kv_postconf smtpd_tls_cert_file "$CERT_DIR/fullchain.pem"
set_kv_postconf smtpd_tls_key_file "$CERT_DIR/privkey.pem"
set_kv_postconf smtpd_tls_security_level may
set_kv_postconf smtpd_tls_auth_only yes
set_kv_postconf smtp_tls_security_level may

sed -i -E 's|^[# ]*ssl\s*=.*|ssl = required|' /etc/dovecot/conf.d/10-ssl.conf
if grep -qE '^[# ]*ssl_cert\s*=' /etc/dovecot/conf.d/10-ssl.conf; then
  sed -i -E "s|^[# ]*ssl_cert\s*=.*|ssl_cert = <$CERT_DIR/fullchain.pem|" /etc/dovecot/conf.d/10-ssl.conf
else
  echo "ssl_cert = <$CERT_DIR/fullchain.pem" >> /etc/dovecot/conf.d/10-ssl.conf
fi
if grep -qE '^[# ]*ssl_key\s*=' /etc/dovecot/conf.d/10-ssl.conf; then
  sed -i -E "s|^[# ]*ssl_key\s*=.*|ssl_key = <$CERT_DIR/privkey.pem|" /etc/dovecot/conf.d/10-ssl.conf
else
  echo "ssl_key = <$CERT_DIR/privkey.pem" >> /etc/dovecot/conf.d/10-ssl.conf
fi

postfix check
dovecot -n >/dev/null
systemctl restart postfix dovecot
ok "TLS configured for Postfix and Dovecot."

# Renewal hook
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh <<'EOF'
#!/bin/sh
systemctl reload postfix || true
systemctl reload dovecot || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh

# ------------------------------------------------------------
# 10. OpenDKIM
# ------------------------------------------------------------
show_step 10 "Configure DKIM signing"

DKIM_DIR="/etc/opendkim/keys/$ROOT_DOMAIN"
install -d -m 750 -o opendkim -g opendkim "$DKIM_DIR"

if [[ ! -f "$DKIM_DIR/default.private" ]]; then
  opendkim-genkey -b 2048 -d "$ROOT_DOMAIN" -D "$DKIM_DIR" -s default
  chown opendkim:opendkim "$DKIM_DIR/default.private" "$DKIM_DIR/default.txt"
  chmod 600 "$DKIM_DIR/default.private"
fi

cat > /etc/opendkim/KeyTable <<EOF
default._domainkey.$ROOT_DOMAIN $ROOT_DOMAIN:default:$DKIM_DIR/default.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
*@$ROOT_DOMAIN default._domainkey.$ROOT_DOMAIN
EOF

cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
$SERVER_IP
$MAIL_HOST
$ROOT_DOMAIN
EOF

# Use localhost TCP to avoid Postfix chroot socket path issues.
# UserID is required: Ubuntu 24 starts the filter as root unless told
# otherwise, then refuses keys owned by the opendkim user.
install -d -m 750 -o opendkim -g opendkim /run/opendkim
chown -R opendkim:opendkim /etc/opendkim
chmod 750 /etc/opendkim /etc/opendkim/keys "$DKIM_DIR"
chmod 600 "$DKIM_DIR/default.private"

cat > /etc/opendkim.conf <<EOF
Syslog                  yes
UMask                   002
UserID                  opendkim
PidFile                 /run/opendkim/opendkim.pid
Mode                    sv
Canonicalization        relaxed/simple
OversignHeaders         From

Socket                  inet:8891@127.0.0.1

KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
EOF

# Ubuntu 24's packaged unit is Type=forking and times out without a pid file.
install -d /etc/systemd/system/opendkim.service.d
cat > /etc/systemd/system/opendkim.service.d/override.conf <<'EOF'
[Service]
Type=simple
User=opendkim
Group=opendkim
PIDFile=
ExecStart=
ExecStart=/usr/sbin/opendkim -x /etc/opendkim.conf -f
EOF
systemctl daemon-reload
systemctl enable opendkim
systemctl restart opendkim
systemctl is-active --quiet opendkim || die "opendkim failed to start. See: journalctl -u opendkim -n 40 --no-pager"

set_kv_postconf milter_protocol 6
set_kv_postconf milter_default_action accept
set_kv_postconf smtpd_milters 'inet:127.0.0.1:8891'
set_kv_postconf non_smtpd_milters 'inet:127.0.0.1:8891'

postfix check
systemctl restart postfix

echo
warn "Publish the following DKIM TXT record at your DNS provider:"
echo
cat "$DKIM_DIR/default.txt"
echo
echo "Host/name should be: default._domainkey"
echo
confirm "Press y after you have published the DKIM TXT record." || warn "Continuing; DKIM verification may fail until DNS propagates."

if dig TXT "default._domainkey.$ROOT_DOMAIN" +short | grep -q 'v=DKIM1'; then
  opendkim-testkey -d "$ROOT_DOMAIN" -s default -vvv || true
else
  warn "DKIM DNS record is not visible yet. Recheck later."
fi

# ------------------------------------------------------------
# 11. Fail2ban
# ------------------------------------------------------------
show_step 11 "Configure Fail2ban"

if [[ -f /etc/fail2ban/jail.local ]]; then
  backup_file /etc/fail2ban/jail.local
fi

cat >> /etc/fail2ban/jail.local <<EOF

# --- MailStack Wizard $TS ---
[postfix]
enabled = true
port = 25,587
filter = postfix
logpath = /var/log/mail.log
maxretry = 5
bantime = 3600

[dovecot]
enabled = true
port = 993
filter = dovecot
logpath = /var/log/mail.log
maxretry = 5
bantime = 3600
EOF

# Only add postfix-sasl if the filter exists.
if [[ -f /etc/fail2ban/filter.d/postfix-sasl.conf ]]; then
  cat >> /etc/fail2ban/jail.local <<'EOF'

[postfix-sasl]
enabled = true
port = 25,587
filter = postfix-sasl
logpath = /var/log/mail.log
maxretry = 5
bantime = 3600
EOF
else
  warn "postfix-sasl Fail2ban filter not present; skipping that jail."
fi

fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2ban configured."

# ------------------------------------------------------------
# 12. Firewall
# ------------------------------------------------------------
show_step 12 "Firewall"

if command_exists ufw; then
  ufw allow "$SSH_PORT/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 25/tcp
  ufw allow 587/tcp
  ufw allow 993/tcp
  if ufw status | grep -q "Status: active"; then
    ufw reload
  else
    warn "UFW is installed but inactive. Rules were added, but the wizard will not enable it automatically."
    warn "Review 'ufw status verbose', then enable manually with 'sudo ufw enable' if desired."
  fi
else
  warn "UFW not installed; skipping firewall configuration."
fi

# ------------------------------------------------------------
# 13. Roundcube
# ------------------------------------------------------------
show_step 13 "Configure Roundcube"

PHP_FPM_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' | sort -V | tail -n1 || true)"
[[ -n "$PHP_FPM_SOCK" ]] || die "Could not locate PHP-FPM socket."

RC_ROOT=""
for candidate in /var/lib/roundcube/public_html /var/lib/roundcube; do
  if [[ -e "$candidate/index.php" ]]; then
    RC_ROOT="$candidate"
    break
  fi
done
[[ -n "$RC_ROOT" ]] || die "Could not determine Roundcube web root."

RC_CONFIG="/etc/roundcube/config.inc.php"
backup_file "$RC_CONFIG"

# Debian/Ubuntu 24 Roundcube 1.6 reads imap_host / smtp_host. The old
# default_host / smtp_server keys are ignored, so webmail talks to
# localhost:587 with no STARTTLS and reports "Authentication failed".
python3 - "$RC_CONFIG" "$MAIL_HOST" "$ROOT_DOMAIN" "$DISPLAY_NAME" <<'PY'
import sys, re
from pathlib import Path
path=Path(sys.argv[1])
mail_host=sys.argv[2]
root_domain=sys.argv[3]
product=sys.argv[4]
s=path.read_text()

settings={
"imap_host": f"ssl://{mail_host}:993",
"smtp_host": f"tls://{mail_host}:587",
"default_host": f"ssl://{mail_host}",
"default_port": "993",
"smtp_server": f"tls://{mail_host}",
"smtp_port": "587",
"smtp_user": "%u",
"smtp_pass": "%p",
"mail_domain": root_domain,
"product_name": product,
}

for key,val in settings.items():
    if val.isdigit():
        line=f"$config['{key}'] = {val};"
    else:
        safe=val.replace("\\","\\\\").replace("'","\\'")
        line=f"$config['{key}'] = '{safe}';"
    pat=re.compile(rf"^\s*\$config\['{re.escape(key)}'\]\s*=.*?;\s*$", re.M)
    if pat.search(s):
        s=pat.sub(line,s)
    else:
        s += "\n"+line+"\n"
path.write_text(s)
PY

# Roundcube's MySQL database is not created unless dbconfig-common ran.
systemctl enable --now mariadb
python3 <<'PY'
from pathlib import Path
import re, secrets, subprocess, sys
debian_db = Path("/etc/roundcube/debian-db.php")
if not debian_db.exists():
    raise SystemExit("missing /etc/roundcube/debian-db.php")
text = debian_db.read_text()
def read_var(name, default=""):
    m = re.search(rf"\${name}\s*=\s*'([^']*)'", text)
    return m.group(1) if m else default
dbname = read_var("dbname", "roundcube")
dbuser = read_var("dbuser", "roundcube")
dbpass = read_var("dbpass", "")
if not re.fullmatch(r"[A-Za-z0-9_]+", dbname) or not re.fullmatch(r"[A-Za-z0-9_]+", dbuser):
    raise SystemExit("unexpected Roundcube database identifiers")
if dbpass == "":
    dbpass = secrets.token_hex(18)
    assign = "$dbpass='" + dbpass + "';"
    if re.search(r"\$dbpass\s*=\s*'[^']*'", text):
        text = re.sub(r"\$dbpass\s*=\s*'[^']*';", assign, text, count=1)
    else:
        text += "\n" + assign + "\n"
    debian_db.write_text(text)
sql = (
    f"CREATE DATABASE IF NOT EXISTS `{dbname}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n"
    f"CREATE USER IF NOT EXISTS '{dbuser}'@'localhost' IDENTIFIED BY '{dbpass}';\n"
    f"ALTER USER '{dbuser}'@'localhost' IDENTIFIED BY '{dbpass}';\n"
    f"GRANT ALL PRIVILEGES ON `{dbname}`.* TO '{dbuser}'@'localhost';\n"
    "FLUSH PRIVILEGES;\n"
)
subprocess.run(["mysql"], input=sql, text=True, check=True)
tables = subprocess.check_output(["mysql", dbname, "-N", "-e", "SHOW TABLES LIKE 'session'"], text=True)
schema = Path("/usr/share/roundcube/SQL/mysql.initial.sql")
if "session" not in tables and schema.exists():
    subprocess.run(["mysql", dbname], input=schema.read_text(), text=True, check=True)
print("roundcube-db-ready")
PY
systemctl reload "$(basename "${PHP_FPM_SOCK%.sock}")" 2>/dev/null || \
  systemctl reload php8.3-fpm 2>/dev/null || \
  systemctl reload php-fpm 2>/dev/null || true

NGINX_SITE="/etc/nginx/sites-available/$WEBMAIL_HOST"
backup_file "$NGINX_SITE"

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $WEBMAIL_HOST;

    root $RC_ROOT;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/$WEBMAIL_HOST"
nginx -t
systemctl reload nginx

if certbot certificates 2>/dev/null | grep -q "Certificate Name: $WEBMAIL_HOST"; then
  ok "Existing certificate found for $WEBMAIL_HOST."
else
  certbot --nginx -d "$WEBMAIL_HOST"
fi

nginx -t
systemctl reload nginx

# ------------------------------------------------------------
# 14. Final validation
# ------------------------------------------------------------
show_step 14 "Final validation"

echo "Server identity:"
hostname -f || true
postconf myhostname
echo

echo "Listening services:"
ss -ltnp | grep -E ':25|:80|:443|:587|:993|:8891' || true
echo

echo "DNS:"
echo -n "A $MAIL_HOST: "; dig +short A "$MAIL_HOST" | tr '\n' ' '; echo
echo -n "A $WEBMAIL_HOST: "; dig +short A "$WEBMAIL_HOST" | tr '\n' ' '; echo
echo -n "MX $ROOT_DOMAIN: "; dig +short MX "$ROOT_DOMAIN" | tr '\n' ' '; echo
echo -n "PTR $SERVER_IP: "; dig -x "$SERVER_IP" +short | tr '\n' ' '; echo
echo -n "SPF: "; dig TXT "$ROOT_DOMAIN" +short | grep 'v=spf1' || true
echo -n "DMARC: "; dig TXT "_dmarc.$ROOT_DOMAIN" +short || true
echo -n "DKIM: "; dig TXT "default._domainkey.$ROOT_DOMAIN" +short | head -c 120; echo "..."
echo

if [[ -f "$DKIM_DIR/default.private" ]]; then
  opendkim-testkey -d "$ROOT_DOMAIN" -s default -vvv || true
fi

echo
ok "Core installation finished."

cat <<EOF

============================================================
NEXT: LOGIN TO ROUNDCUBE
============================================================

Open:
  https://$WEBMAIL_HOST

For this simple system-user mailbox model, log in with:
  Username: $MAIL_USER
  Password: the password you created with adduser

Then go to:
  Settings -> Identities

Make sure the email identity is:
  $MAIL_ADDRESS

NOT:
  $MAIL_USER@$MAIL_HOST

This is important for SPF/DKIM/DMARC alignment.

============================================================
FINAL GMAIL TEST
============================================================

Send from Roundcube to a Gmail address.

Then in Gmail -> Show original, verify:
  SPF   PASS
  DKIM  PASS
  DMARC PASS

Useful commands:

  sudo grep -E 'DKIM-Signature|status=sent|status=bounced|status=deferred' /var/log/mail.log | tail -n 50
  sudo postqueue -p
  sudo fail2ban-client status
  sudo certbot renew --dry-run

Backups:
  $BACKUP_DIR

Log:
  $LOG_FILE

EOF
