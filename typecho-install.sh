#!/usr/bin/env bash
#
# typecho-install.sh — one-click Typecho install (always fetches the latest
# GitHub release) on a Debian 13 (trixie) box: nginx + MariaDB + PHP-FPM,
# with optional Let's Encrypt via certbot.
#
# Usage:
#   sudo bash typecho-install.sh --domain blog.example.com --email you@example.com
#   sudo bash typecho-install.sh --domain blog.example.com --no-ssl
#   sudo bash typecho-install.sh                       # no domain: binds :80 to server IP only, no SSL
#
# Options:
#   --domain <domain>     Domain name for the site (sets nginx server_name + enables certbot)
#   --email  <email>      Email for Let's Encrypt registration (required with --domain unless --no-ssl)
#   --no-ssl               Skip certbot / HTTPS even if --domain is given
#   --webroot <path>       Install path (default: /var/www/typecho)
#   --dbname <name>        MariaDB database name (default: typecho)
#   --dbuser <user>        MariaDB user (default: typecho)
#   --dbpass <password>    MariaDB password (default: randomly generated)
#
# curl | bash usage (non-interactive, pass args after --s --):
#   curl -fsSL https://bso-9464.github.io/typecho-install.sh | sudo bash -s -- --domain blog.example.com --email you@example.com
#
set -euo pipefail

DOMAIN=""
EMAIL=""
NO_SSL=0
WEBROOT="/var/www/typecho"
DB_NAME="typecho"
DB_USER="typecho"
DB_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --no-ssl) NO_SSL=1; shift ;;
    --webroot) WEBROOT="$2"; shift 2 ;;
    --dbname) DB_NAME="$2"; shift 2 ;;
    --dbuser) DB_USER="$2"; shift 2 ;;
    --dbpass) DB_PASS="$2"; shift 2 ;;
    --help|-h) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (e.g. sudo bash $0)" >&2
  exit 1
fi

log()  { echo -e "\033[1;36m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

[[ -z "$DB_PASS" ]] && DB_PASS=$(openssl rand -base64 18 | tr -d '=+/')

echo "=============================================="
echo " Typecho install"
echo "   domain:  ${DOMAIN:-<none, IP only>}"
echo "   webroot: $WEBROOT"
echo "   ssl:     $([[ $NO_SSL -eq 1 || -z "$DOMAIN" ]] && echo no || echo yes)"
echo "=============================================="

if [[ -n "$DOMAIN" && $NO_SSL -eq 0 && -z "$EMAIL" ]]; then
  err "--email is required when using --domain with SSL (or pass --no-ssl)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "Installing packages (nginx, MariaDB, PHP-FPM, extensions)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  nginx mariadb-server \
  php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl \
  curl ca-certificates unzip tar openssl jq >/dev/null

if [[ -n "$DOMAIN" && $NO_SSL -eq 0 ]]; then
  apt-get install -y --no-install-recommends certbot python3-certbot-nginx >/dev/null
fi

PHP_VER=$(php -v | head -n1 | grep -oP '^PHP \K[0-9]+\.[0-9]+')
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
log "Detected PHP ${PHP_VER}, socket: $PHP_SOCK"

systemctl enable --now mariadb nginx "php${PHP_VER}-fpm" >/dev/null

# ---------------------------------------------------------------------------
# 2. Fix duplicate server_tokens (bit us last time) & harden nginx.conf
# ---------------------------------------------------------------------------
log "Normalizing /etc/nginx/nginx.conf (dedupe server_tokens)"
sed -i '/server_tokens/d' /etc/nginx/nginx.conf
sed -i '/http {/a\\tserver_tokens off;' /etc/nginx/nginx.conf

# ---------------------------------------------------------------------------
# 3. Database
# ---------------------------------------------------------------------------
log "Creating database '$DB_NAME' and user '$DB_USER'"
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# ---------------------------------------------------------------------------
# 4. Fetch latest Typecho release from GitHub
# ---------------------------------------------------------------------------
log "Looking up the latest Typecho release on GitHub..."
API_JSON=$(curl -fsSL -H "Accept: application/vnd.github+json" https://api.github.com/repos/typecho/typecho/releases/latest)
TAG=$(echo "$API_JSON" | jq -r '.tag_name')
ASSET_URL=$(echo "$API_JSON" | jq -r '.assets[] | select(.name | test("build\\.tar\\.gz$|\\.zip$")) | .browser_download_url' | head -n1)

if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
  warn "No release asset found; falling back to the tagged source tarball."
  ASSET_URL="https://github.com/typecho/typecho/archive/refs/tags/${TAG}.tar.gz"
fi

log "Latest version: $TAG"
log "Downloading: $ASSET_URL"

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
ASSET_NAME=$(basename "$ASSET_URL")
curl -fsSL -o "$ASSET_NAME" "$ASSET_URL"

mkdir -p extracted
if [[ "$ASSET_NAME" == *.zip ]]; then
  unzip -q "$ASSET_NAME" -d extracted
else
  tar -xzf "$ASSET_NAME" -C extracted
fi

# typecho.zip extracts flat (index.php, admin/, usr/ etc. directly under extracted/).
# The source tarball fallback unpacks to a single typecho-<ver>/ subfolder instead.
if [[ -f extracted/index.php ]]; then
  SRC_DIR="extracted"
else
  SRC_DIR=$(find extracted -mindepth 1 -maxdepth 1 -type d \( -iname 'build' -o -iname 'typecho-*' \) | head -n1)
  [[ -z "$SRC_DIR" ]] && SRC_DIR=$(find extracted -mindepth 1 -maxdepth 1 -type d | head -n1)
fi

log "Installing to $WEBROOT"
mkdir -p "$WEBROOT"
rsync -a --delete "$SRC_DIR"/ "$WEBROOT"/ 2>/dev/null || cp -a "$SRC_DIR"/. "$WEBROOT"/
rm -rf "$TMP_DIR"

chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
mkdir -p "$WEBROOT/usr/uploads"
chmod -R 775 "$WEBROOT/usr" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. nginx vhost
# ---------------------------------------------------------------------------
SITE_NAME="${DOMAIN:-typecho}"
SITE_CONF="/etc/nginx/sites-available/${SITE_NAME}.conf"
SERVER_NAME="${DOMAIN:-_}"

log "Writing nginx vhost $SITE_CONF"
cat > "$SITE_CONF" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

    root ${WEBROOT};
    index index.php index.html;

    client_max_body_size 32m;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
    location ~ /\.git {
        deny all;
    }
}
NGINX

ln -sf "$SITE_CONF" "/etc/nginx/sites-enabled/${SITE_NAME}.conf"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 6. Let's Encrypt (optional)
# ---------------------------------------------------------------------------
if [[ -n "$DOMAIN" && $NO_SSL -eq 0 ]]; then
  log "Requesting Let's Encrypt certificate for $DOMAIN"
  if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect; then
    log "SSL enabled for https://$DOMAIN"
  else
    warn "certbot failed (DNS not pointed at this server yet?) — site is still up over HTTP."
  fi
fi

# ---------------------------------------------------------------------------
# 7. Done
# ---------------------------------------------------------------------------
URL="http://${DOMAIN:-$(curl -fsSL ifconfig.me || echo 'YOUR_SERVER_IP')}"
[[ -n "$DOMAIN" && $NO_SSL -eq 0 ]] && URL="https://${DOMAIN}"

echo
echo "=============================================="
echo " Typecho $TAG installed to $WEBROOT"
echo "=============================================="
echo " Finish setup in your browser: ${URL}/install.php"
echo
echo " Database type : MySQL"
echo " Database host : localhost"
echo " Database name : $DB_NAME"
echo " Database user : $DB_USER"
echo " Database pass : $DB_PASS"
echo " Table prefix  : typecho_ (default, or change as you like)"
echo "=============================================="
echo " Save the DB password above — it is not stored anywhere else."
