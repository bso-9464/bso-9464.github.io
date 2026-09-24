#!/usr/bin/env bash
#
# wp-uninstall.sh — one-click WordPress removal for the Debian 13 (trixie)
# nginx + PHP-FPM + MariaDB + WP-CLI + certbot stack.
#
# By default this ONLY removes the WordPress site itself:
#   - webroot files
#   - its MariaDB database + DB user
#   - its nginx vhost config
#   - its Let's Encrypt certificate (if any)
#
# It leaves nginx / MariaDB / PHP-FPM / certbot / WP-CLI installed so you can
# reuse the stack for something else. Pass --purge-stack to also remove the
# whole LEMP stack and WP-CLI (see usage below).
#
# It does NOT touch sing-box or anything unrelated to the WordPress install.
#
# Usage:
#   sudo bash wp-uninstall.sh                # interactive, asks before each destructive step
#   sudo bash wp-uninstall.sh --yes          # non-interactive, assumes "yes" to all prompts
#   sudo bash wp-uninstall.sh --purge-stack  # also remove nginx/mariadb/php-fpm/certbot/wp-cli
#   sudo bash wp-uninstall.sh --dry-run      # show what would happen, change nothing
#
set -uo pipefail

YES=0
DRY_RUN=0
PURGE_STACK=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --purge-stack) PURGE_STACK=1 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^#//'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (e.g. sudo bash $0)" >&2
  exit 1
fi

log()  { echo -e "\033[1;36m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
run()  {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  (dry-run) $*"
  else
    eval "$@"
  fi
}
confirm() {
  local prompt="$1"
  [[ $YES -eq 1 ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

echo "=============================================="
echo " WordPress uninstall  (dry-run: $DRY_RUN, purge-stack: $PURGE_STACK)"
echo "=============================================="

# ---------------------------------------------------------------------------
# 1. Find WordPress installs (any wp-config.php under common webroots)
# ---------------------------------------------------------------------------
log "Scanning for WordPress installs..."
mapfile -t WP_CONFIGS < <(find /var/www /srv /home -maxdepth 6 -name wp-config.php 2>/dev/null)

if [[ ${#WP_CONFIGS[@]} -eq 0 ]]; then
  warn "No wp-config.php found under /var/www, /srv, /home."
  warn "If WordPress lives elsewhere, tell me the webroot path and I can re-target this script."
  if [[ $PURGE_STACK -eq 0 ]]; then
    exit 0
  fi
else
  for CFG in "${WP_CONFIGS[@]}"; do
    WEBROOT=$(dirname "$CFG")
    echo
    log "Found WordPress at: $WEBROOT"

    DB_NAME=$(grep -oP "define\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$CFG" 2>/dev/null)
    DB_USER=$(grep -oP "define\(\s*'DB_USER'\s*,\s*'\K[^']+" "$CFG" 2>/dev/null)
    echo "    DB name: ${DB_NAME:-<not found>}"
    echo "    DB user: ${DB_USER:-<not found>}"

    # Try to find the matching nginx vhost by grepping for this webroot
    NGINX_SITE=$(grep -rlF "$WEBROOT" /etc/nginx/sites-enabled/ /etc/nginx/sites-available/ 2>/dev/null | head -n1)
    if [[ -n "${NGINX_SITE:-}" ]]; then
      echo "    nginx vhost: $NGINX_SITE"
      DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' "$NGINX_SITE" 2>/dev/null | head -n1 | awk '{print $1}')
      echo "    domain: ${DOMAIN:-<not found>}"
    else
      NGINX_SITE=""
      DOMAIN=""
      echo "    nginx vhost: <not found>"
    fi

    echo
    if ! confirm "Remove this site (files + DB + nginx vhost + cert)?"; then
      warn "Skipping $WEBROOT"
      continue
    fi

    # --- webroot ---
    log "Removing webroot $WEBROOT"
    run "rm -rf -- '$WEBROOT'"

    # --- database ---
    if [[ -n "${DB_NAME:-}" ]]; then
      log "Dropping database '$DB_NAME'"
      run "mysql -e \"DROP DATABASE IF EXISTS \\\`$DB_NAME\\\`;\""
    fi
    if [[ -n "${DB_USER:-}" && "$DB_USER" != "root" ]]; then
      log "Dropping DB user '$DB_USER'@'localhost'"
      run "mysql -e \"DROP USER IF EXISTS '$DB_USER'@'localhost';\""
      run "mysql -e 'FLUSH PRIVILEGES;'"
    fi

    # --- nginx vhost ---
    if [[ -n "$NGINX_SITE" ]]; then
      BASENAME=$(basename "$NGINX_SITE")
      log "Removing nginx vhost $BASENAME"
      run "rm -f '/etc/nginx/sites-enabled/$BASENAME' '/etc/nginx/sites-available/$BASENAME'"
    fi

    # --- Let's Encrypt cert ---
    if [[ -n "$DOMAIN" ]] && command -v certbot >/dev/null 2>&1; then
      if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
        if confirm "Also delete the Let's Encrypt certificate for $DOMAIN?"; then
          log "Deleting certificate for $DOMAIN"
          run "certbot delete --cert-name '$DOMAIN' --non-interactive"
        fi
      fi
    fi
  done

  log "Testing and reloading nginx config"
  run "nginx -t"
  run "systemctl reload nginx"
fi

# ---------------------------------------------------------------------------
# 2. Optional: purge the whole LEMP stack + WP-CLI
# ---------------------------------------------------------------------------
if [[ $PURGE_STACK -eq 1 ]]; then
  echo
  warn "About to purge the ENTIRE stack: nginx, mariadb-server, php-fpm and"
  warn "related php modules, certbot, python3-certbot-nginx, and /usr/local/bin/wp."
  warn "This will affect anything else running on nginx/MariaDB/PHP on this VPS."
  if confirm "Really purge the whole stack?"; then
    log "Stopping services"
    run "systemctl stop nginx mariadb php8.4-fpm certbot.timer 2>/dev/null"

    log "Purging packages"
    run "apt-get purge -y nginx nginx-common mariadb-server mariadb-server-core* mariadb-client mariadb-client-core* php-fpm php8.4-fpm php-bcmath php-cli php-curl php-gd php-imagick php-intl php-mbstring php-mysql php-xml php-zip certbot python3-certbot-nginx"
    run "apt-get autoremove -y"

    log "Removing leftover data/config directories"
    run "rm -rf /etc/nginx /var/lib/mysql /etc/mysql /var/log/mysql /etc/letsencrypt /var/log/letsencrypt"

    log "Removing WP-CLI"
    run "rm -f /usr/local/bin/wp"

    log "Done. sing-box, ssh and everything else on this VPS is untouched."
  else
    warn "Stack purge cancelled."
  fi
fi

echo
log "Finished. Review the output above for anything skipped."
