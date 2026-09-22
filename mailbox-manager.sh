#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
MAIL_DOMAIN="${MAIL_DOMAIN:-$(postconf -h mydomain 2>/dev/null || true)}"
BACKUP_DIR="/root/mailbox-manager-backups"
LOG_FILE="/var/log/mailbox-manager.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

say(){ echo -e "${BLUE}==>${RESET} $*"; }
ok(){ echo -e "${GREEN}✔${RESET} $*"; }
warn(){ echo -e "${YELLOW}⚠${RESET} $*"; }
die(){ echo -e "${RED}✘ $*${RESET}" >&2; exit 1; }
title(){ echo -e "\n${BOLD}$*${RESET}\n"; }

[[ $EUID -eq 0 ]] || die "Run with sudo/root."
[[ -n "$MAIL_DOMAIN" ]] || die "Could not detect Postfix mydomain. Use MAIL_DOMAIN=example.com."

mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

valid_user(){ [[ "$1" =~ ^[a-z][a-z0-9._-]{0,31}$ ]]; }
exists(){ id "$1" >/dev/null 2>&1; }
addr(){ echo "$1@$MAIL_DOMAIN"; }
maildir(){ echo "/home/$1/Maildir"; }

create_maildir(){
  local u="$1" md
  md="$(maildir "$u")"
  install -d -m 700 -o "$u" -g "$u" "$md" "$md/cur" "$md/new" "$md/tmp"
}

add_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username (e.g. support): " u
  valid_user "$u" || die "Invalid username."
  if exists "$u"; then
    warn "Linux user '$u' already exists; reusing it."
  else
    say "Creating Linux user '$u'..."
    adduser "$u"
  fi
  create_maildir "$u"
  ok "Mailbox ready: $(addr "$u")"
  echo
  echo "Roundcube login username: $u"
  echo "Then set Roundcube -> Settings -> Identities -> Email to: $(addr "$u")"
}

list_boxes(){
  title "Mailboxes on $MAIL_DOMAIN"
  printf "%-20s %-34s %-10s %-8s\n" "USER" "EMAIL" "STATE" "MAILDIR"
  while IFS=: read -r u _ uid _ _ home shell; do
    if [[ "$uid" -ge 1000 && "$home" == /home/* ]]; then
      state="enabled"
      [[ "$shell" == *nologin* || "$shell" == *false* ]] && state="disabled"
      md="missing"; [[ -d "$home/Maildir" ]] && md="ok"
      printf "%-20s %-34s %-10s %-8s\n" "$u" "$(addr "$u")" "$state" "$md"
    fi
  done < /etc/passwd
}

change_pass(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  passwd "$u"
  ok "Password changed for $(addr "$u")"
}

show_info(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  home="$(getent passwd "$u" | cut -d: -f6)"
  shell="$(getent passwd "$u" | cut -d: -f7)"
  md="$home/Maildir"
  count=0; size="0"
  if [[ -d "$md" ]]; then
    count="$(find "$md/cur" "$md/new" -type f 2>/dev/null | wc -l)"
    size="$(du -sh "$md" 2>/dev/null | awk '{print $1}')"
  fi
  title "Mailbox information"
  echo "User     : $u"
  echo "Email    : $(addr "$u")"
  echo "Home     : $home"
  echo "Shell    : $shell"
  echo "Messages : $count"
  echo "Disk use : $size"
}

test_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  md="$(maildir "$u")"
  title "Mailbox test: $(addr "$u")"
  echo -n "Linux user ............ "; exists "$u" && echo OK || echo FAIL
  echo -n "Maildir ............... "; [[ -d "$md/cur" && -d "$md/new" && -d "$md/tmp" ]] && echo OK || echo FAIL
  echo -n "Dovecot auth socket ... "; [[ -S /var/spool/postfix/private/auth ]] && echo OK || echo FAIL
  echo -n "SMTP 25 ............... "; ss -ltn | grep -q ':25 ' && echo OK || echo FAIL
  echo -n "SMTP 587 .............. "; ss -ltn | grep -q ':587 ' && echo OK || echo FAIL
  echo -n "IMAPS 993 ............. "; ss -ltn | grep -q ':993 ' && echo OK || echo FAIL
  echo -n "DKIM milter ........... "; postconf -h smtpd_milters 2>/dev/null | grep -q '8891' && echo OK || echo CHECK
  echo
  echo "Incoming test:"
  echo "  Send Gmail -> $(addr "$u")"
  echo "  sudo find $md/new -type f -ls"
  echo
  echo "Outgoing log:"
  echo "  sudo grep -E '$u@$MAIL_DOMAIN|DKIM-Signature|status=sent|status=bounced' /var/log/mail.log | tail -n 30"
}

repair_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  create_maildir "$u"
  chown -R "$u:$u" "$(maildir "$u")"
  chmod 700 "$(maildir "$u")" "$(maildir "$u")"/{cur,new,tmp}
  ok "Maildir repaired for $(addr "$u")"
}

disable_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  usermod -L "$u"
  usermod -s /usr/sbin/nologin "$u"
  ok "Disabled: $(addr "$u")"
}

enable_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  usermod -U "$u" || true
  usermod -s /bin/bash "$u"
  passwd "$u"
  ok "Enabled: $(addr "$u")"
}

remove_box(){
  local u="${1:-}"
  [[ -n "$u" ]] || read -r -p "Mailbox username: " u
  exists "$u" || die "User '$u' does not exist."
  home="$(getent passwd "$u" | cut -d: -f6)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/${u}-${stamp}.tar.gz"
  warn "This will delete $(addr "$u") after backing up $home."
  read -r -p "Type DELETE to continue: " ans
  [[ "$ans" == "DELETE" ]] || die "Cancelled."
  [[ -d "$home" ]] && tar -czf "$backup" "$home"
  userdel -r "$u"
  ok "Removed: $(addr "$u")"
  [[ -f "$backup" ]] && ok "Backup: $backup"
}

menu(){
  while true; do
    clear || true
    title "Mailbox Manager v$VERSION"
    echo "Domain: $MAIL_DOMAIN"
    echo
    cat <<'EOF'
1) Add mailbox
2) List mailboxes
3) Change mailbox password
4) Show mailbox info
5) Test mailbox
6) Repair Maildir
7) Disable mailbox
8) Enable mailbox
9) Remove mailbox
0) Exit
EOF
    echo
    read -r -p "Choose: " c
    case "$c" in
      1) add_box ;;
      2) list_boxes ;;
      3) change_pass ;;
      4) show_info ;;
      5) test_box ;;
      6) repair_box ;;
      7) disable_box ;;
      8) enable_box ;;
      9) remove_box ;;
      0) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
    echo
    read -r -p "Press Enter to continue..." _
  done
}

cmd="${1:-menu}"; arg="${2:-}"
case "$cmd" in
  menu) menu ;;
  add) add_box "$arg" ;;
  list) list_boxes ;;
  passwd|password) change_pass "$arg" ;;
  info) show_info "$arg" ;;
  test) test_box "$arg" ;;
  repair) repair_box "$arg" ;;
  disable) disable_box "$arg" ;;
  enable) enable_box "$arg" ;;
  remove|delete) remove_box "$arg" ;;
  help|-h|--help)
    cat <<EOF
Mailbox Manager v$VERSION

sudo $0
sudo $0 add support
sudo $0 list
sudo $0 passwd support
sudo $0 info support
sudo $0 test support
sudo $0 repair support
sudo $0 disable support
sudo $0 enable support
sudo $0 remove support

Override domain:
sudo MAIL_DOMAIN=example.com $0 add contact
EOF
    ;;
  *) die "Unknown command. Use --help." ;;
esac
