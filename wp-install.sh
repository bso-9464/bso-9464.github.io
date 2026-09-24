#!/usr/bin/env bash
# ==============================================================================
# WordPress 一键安装脚本（v2，修复版）
# 目标环境：Debian 12/13、Ubuntu 22.04+ / 1 vCPU / ~2GB RAM / root
# 技术栈：  nginx + PHP-FPM + MariaDB + WP-CLI + Let's Encrypt（可选）
#
# 用法：
#   curl -fsSL https://bso-9464.github.io/wp-install.sh | DOMAIN=blog.example.com EMAIL=you@example.com bash
#
# 可选环境变量：
#   DOMAIN          站点域名（需已解析到本机 IP；不填则仅用 IP + HTTP）
#   EMAIL           证书通知邮箱 / 管理员邮箱
#   WP_TITLE        站点标题（默认 My Blog）
#   WP_LOCALE       语言（默认 zh_CN）
#   WP_ADMIN_USER   管理员用户名（默认随机 admin_xxxx）
#   WP_ADMIN_EMAIL  管理员邮箱（默认取 EMAIL）
#   WP_DIR          安装目录（默认 /var/www/wordpress）
#   FORCE=1         检测到已有 wp-config.php 时仍继续（用于上次安装中途失败后重跑）
#
# v2 修复：
#   1. server_tokens 重复指令导致 nginx -t 失败：写入前先检测，已有则不再重复添加
#   2. uploads 目录禁 PHP 的规则被 \.php$ 抢先匹配而失效：调整 location 顺序
#   3. 整个脚本包进 main()，避免 curl|bash 下载中断时执行半截脚本
#   4. wp-cli 以 www-data 运行时工作目录为 /root 无权限：切到 /tmp 并指定 HOME
#   5. 支持中途失败后重跑（config/core download 加 --force，FORCE=1 跳过已存在检查）
# ==============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[31m[错误]\033[0m 脚本在第 $LINENO 行失败，请把上面的输出发给我排查" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

main() {
  local DOMAIN="${DOMAIN:-}"
  local EMAIL="${EMAIL:-}"
  local WP_TITLE="${WP_TITLE:-My Blog}"
  local WP_LOCALE="${WP_LOCALE:-zh_CN}"
  local WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-}"
  local WP_DIR="${WP_DIR:-/var/www/wordpress}"
  local DB_NAME="${DB_NAME:-wordpress}"
  local DB_USER="${DB_USER:-wpuser}"
  local FORCE="${FORCE:-0}"
  local CRED_FILE="/root/wordpress-credentials.txt"
  local POOL_SOCK="/run/php/wordpress-fpm.sock"

  # ------------------------------- 预检 ---------------------------------------
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" =~ ^(debian|ubuntu)$ ]] || die "仅支持 Debian / Ubuntu（当前：${PRETTY_NAME:-unknown}）"

  if [[ -f "$WP_DIR/wp-config.php" && "$FORCE" != "1" ]]; then
    die "$WP_DIR 已存在 wp-config.php，为避免覆盖已中止。若是上次安装中途失败，可加 FORCE=1 重跑"
  fi

  if ss -ltnH 'sport = :80 or sport = :443' | grep -q . && ! systemctl is-active --quiet nginx; then
    die "80/443 端口已被其他程序占用，请先处理（ss -ltnp | grep -E ':(80|443)\\b'）"
  fi

  if [[ -z "$DOMAIN" ]]; then
    { read -r -p "请输入域名（已解析到本机；直接回车=仅用 IP 走 HTTP）: " DOMAIN </dev/tty; } 2>/dev/null || true
  fi
  DOMAIN="${DOMAIN,,}"
  if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    die "域名格式不正确：$DOMAIN"
  fi

  # ------------------------------- 安装软件包 ---------------------------------
  log "更新软件源并安装 nginx / MariaDB / PHP..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    nginx mariadb-server \
    php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-bcmath php-imagick \
    curl ca-certificates openssl unzip

  rand() { openssl rand -hex "$1"; }
  local WP_ADMIN_USER="${WP_ADMIN_USER:-admin_$(rand 2)}"

  local PHP_VER
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  log "检测到 PHP ${PHP_VER}"

  systemctl enable --now mariadb nginx "php${PHP_VER}-fpm"

  # ------------------------------- 低内存调优 ---------------------------------
  log "针对 1 核 / 2GB 内存做调优..."

  cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-wordpress.ini" <<'EOF'
expose_php = Off
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
opcache.enable = 1
opcache.memory_consumption = 96
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
EOF

  # 独立 FPM 进程池：ondemand，最多 6 个进程（每个约 50-80MB）
  if [[ -f "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" ]]; then
    mv "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" "/etc/php/${PHP_VER}/fpm/pool.d/www.conf.disabled"
  fi
  cat > "/etc/php/${PHP_VER}/fpm/pool.d/wordpress.conf" <<EOF
[wordpress]
user = www-data
group = www-data
listen = ${POOL_SOCK}
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 6
pm.process_idle_timeout = 30s
pm.max_requests = 500
EOF

  # MariaDB 精简配置
  mkdir -p /etc/mysql/mariadb.conf.d
  cat > /etc/mysql/mariadb.conf.d/99-lowmem.cnf <<'EOF'
[mysqld]
performance_schema = OFF
innodb_buffer_pool_size = 128M
max_connections = 50
key_buffer_size = 8M
tmp_table_size = 32M
max_heap_table_size = 32M
skip-name-resolve
EOF

  systemctl restart mariadb "php${PHP_VER}-fpm"

  # ------------------------------- 数据库 -------------------------------------
  log "创建数据库与用户..."
  local DB_PASS
  DB_PASS="$(rand 16)"
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  # ------------------------------- nginx --------------------------------------
  log "配置 nginx..."
  mkdir -p "$WP_DIR"
  chown www-data:www-data "$WP_DIR"

  # 先只写限速 zone；server_tokens 仅在全局配置里没有时才补，避免 "directive is duplicate"
  cat > /etc/nginx/conf.d/wp-global.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=wplogin:10m rate=10r/m;
EOF
  if ! grep -Eqs '^[[:space:]]*server_tokens[[:space:]]' /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf; then
    echo 'server_tokens off;' >> /etc/nginx/conf.d/wp-global.conf
  fi

  local SERVER_NAME="${DOMAIN:-_}"
  cat > /etc/nginx/sites-available/wordpress <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    root __WP_DIR__;
    index index.php;
    client_max_body_size 64M;

    # 隐藏文件禁止访问（保留 .well-known 供证书验证）
    location ~ /\.(?!well-known) { deny all; }

    # 上传目录禁止执行 PHP（必须放在 \.php$ 之前，否则会被后者抢先匹配）
    location ~* ^/wp-content/uploads/.*\.php$ { deny all; }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # 屏蔽 xmlrpc；限速登录页（防爆破）
    location = /xmlrpc.php { deny all; }
    location = /wp-login.php {
        limit_req zone=wplogin burst=5 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__POOL_SOCK__;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__POOL_SOCK__;
    }

    location ~* \.(?:css|js|jpe?g|gif|png|svg|ico|webp|avif|woff2?)$ {
        expires 30d;
        access_log off;
        try_files $uri =404;
    }
}
EOF
  sed -i \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    -e "s|__WP_DIR__|${WP_DIR}|g" \
    -e "s|__POOL_SOCK__|${POOL_SOCK}|g" \
    /etc/nginx/sites-available/wordpress

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/wordpress
  nginx -t
  systemctl reload nginx

  # ------------------------------- HTTPS --------------------------------------
  local PUBLIC_IP SCHEME="http" DNS_IP
  PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

  if [[ -n "$DOMAIN" ]]; then
    DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
    if [[ "$DNS_IP" != "$PUBLIC_IP" ]]; then
      warn "域名 ${DOMAIN} 解析为 '${DNS_IP:-无}'，本机 IP 为 ${PUBLIC_IP}。"
      warn "如果开了 Cloudflare 橙云属正常；否则证书申请很可能失败。"
    fi

    log "申请 Let's Encrypt 证书..."
    apt-get install -y --no-install-recommends certbot python3-certbot-nginx
    local CB_ARGS=(--nginx -d "$DOMAIN" --agree-tos --no-eff-email --redirect -n)
    if [[ -n "$EMAIL" ]]; then CB_ARGS+=(-m "$EMAIL"); else CB_ARGS+=(--register-unsafely-without-email); fi
    if certbot "${CB_ARGS[@]}"; then
      SCHEME="https"
    else
      warn "证书申请失败，先以 HTTP 完成安装。确认解析生效并放行 80/443 后可手动执行：certbot --nginx -d ${DOMAIN}"
    fi
  fi

  # ------------------------------- WP-CLI + WordPress -------------------------
  log "安装 WP-CLI..."
  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
  php /usr/local/bin/wp --allow-root --info >/dev/null || die "WP-CLI 无法运行，请检查下载是否完整"

  # 以 www-data 身份运行：切到 /tmp（避免 /root 无权限）并指定 HOME
  wpc() {
    ( cd /tmp && runuser -u www-data -- env HOME=/tmp WP_CLI_CACHE_DIR=/tmp/wp-cli-cache \
        php -d memory_limit=512M /usr/local/bin/wp --path="$WP_DIR" "$@" )
  }

  log "下载 WordPress (${WP_LOCALE})..."
  wpc core download --force --locale="$WP_LOCALE" || wpc core download --force --locale=en_US

  log "生成 wp-config.php..."
  wpc config create --force \
    --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
    --dbhost=localhost --dbcharset=utf8mb4 \
    --dbprefix="wp$(rand 2)_" --extra-php <<'PHP'
define('WP_MEMORY_LIMIT', '256M');
define('DISALLOW_FILE_EDIT', true);
define('FS_METHOD', 'direct');
PHP

  local WP_ADMIN_PASS SITE_HOST SITE_URL ADMIN_EMAIL
  WP_ADMIN_PASS="$(rand 12)"
  SITE_HOST="${DOMAIN:-$PUBLIC_IP}"
  SITE_URL="${SCHEME}://${SITE_HOST}"
  ADMIN_EMAIL="${WP_ADMIN_EMAIL:-${EMAIL:-admin@example.com}}"

  log "执行 WordPress 安装 (${SITE_URL})..."
  wpc core install \
    --url="$SITE_URL" --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" --skip-email

  wpc rewrite structure '/%postname%/' >/dev/null || true
  wpc plugin delete hello akismet >/dev/null 2>&1 || true
  wpc post delete 1 2 --force >/dev/null 2>&1 || true

  chown -R www-data:www-data "$WP_DIR"
  find "$WP_DIR" -type d -exec chmod 755 {} +
  find "$WP_DIR" -type f -exec chmod 644 {} +
  chmod 640 "$WP_DIR/wp-config.php"

  # ------------------------------- 收尾 ---------------------------------------
  ( umask 077
    cat > "$CRED_FILE" <<EOF
站点地址:   ${SITE_URL}
后台地址:   ${SITE_URL}/wp-admin
管理员账号: ${WP_ADMIN_USER}
管理员密码: ${WP_ADMIN_PASS}
数据库名:   ${DB_NAME}
数据库用户: ${DB_USER}
数据库密码: ${DB_PASS}
安装目录:   ${WP_DIR}
EOF
  )
  chmod 600 "$CRED_FILE"

  local CODE
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" http://127.0.0.1/ || true)"

  echo
  echo "=============================================================="
  echo " WordPress 安装完成（本机 HTTP 自检返回码：${CODE}，200/301/302 均正常）"
  echo "=============================================================="
  cat "$CRED_FILE"
  echo "--------------------------------------------------------------"
  echo " 以上信息已保存到 ${CRED_FILE}（仅 root 可读）"
  if [[ -z "$DOMAIN" ]]; then
    echo " 当前为 IP + HTTP 模式；正式使用建议绑定域名并启用 HTTPS。"
  elif [[ "$SCHEME" == "http" ]]; then
    echo " HTTPS 未启用：确认域名解析、放行 80/443 后执行 certbot --nginx -d ${DOMAIN}，"
    echo " 再执行 wp --allow-root --path=${WP_DIR} search-replace http://${DOMAIN} https://${DOMAIN} --all-tables"
  fi
  echo "=============================================================="
}

main "$@"
