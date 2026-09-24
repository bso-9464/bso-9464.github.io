#!/usr/bin/env bash
#
# 一键安装 WordPress (Nginx + MariaDB + PHP-FPM)
# 适配环境: Debian 13 (trixie), 1 vCPU / ~2GB RAM 小内存 VPS
#
# 用法:
#   1. 修改下面"用户配置"区域的变量，或者直接运行脚本按提示输入
#   2. chmod +x install-wordpress.sh
#   3. sudo ./install-wordpress.sh
#
set -euo pipefail

# ==================== 用户配置（可留空，脚本会交互询问）====================
DOMAIN="${DOMAIN:-}"                # 例如 example.com，留空则用服务器 IP 访问
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wp_user}"
DB_PASS="${DB_PASS:-}"              # 留空则自动生成随机密码
ADMIN_EMAIL="${ADMIN_EMAIL:-}"      # 用于申请 SSL 证书，留空则跳过 HTTPS
WEB_ROOT="/var/www/wordpress"
PHP_VERSION=""                      # 留空自动探测 apt 里的默认版本

# ==================== 基础检查 ====================
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行 (当前系统是 root 登录，直接 sudo ./install-wordpress.sh 或 ./install-wordpress.sh 即可)"
  exit 1
fi

if [[ -z "$DOMAIN" ]]; then
  read -rp "请输入你的域名（留空则只用 IP 访问，无法申请 HTTPS 证书）: " DOMAIN
fi
SERVER_IP=$(curl -fsSL -4 ifconfig.me || hostname -I | awk '{print $1}')
SITE_HOST="${DOMAIN:-$SERVER_IP}"

if [[ -z "$DB_PASS" ]]; then
  DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
fi

if [[ -n "$DOMAIN" && -z "$ADMIN_EMAIL" ]]; then
  read -rp "检测到域名 $DOMAIN，输入邮箱以自动申请 Let's Encrypt 证书（留空跳过 HTTPS）: " ADMIN_EMAIL
fi

echo "=================================================="
echo " 站点访问地址 : $SITE_HOST"
echo " 数据库名     : $DB_NAME"
echo " 数据库用户   : $DB_USER"
echo " 数据库密码   : $DB_PASS"
echo " 站点目录     : $WEB_ROOT"
echo "=================================================="
sleep 2

# ==================== 1. 安装依赖 ====================
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx mariadb-server curl unzip wget gnupg lsb-release \
  php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-soap php-bcmath php-imagick

# 探测已安装的 php-fpm 版本 (Debian 13 目前是 8.4)
if [[ -z "$PHP_VERSION" ]]; then
  PHP_VERSION=$(php -v | head -n1 | grep -oP '^PHP \K[0-9]+\.[0-9]+')
fi
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

# ==================== 2. 配置 MariaDB ====================
systemctl enable --now mariadb

# 幂等：如果库/用户已存在则跳过重复创建报错
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# 小内存优化：限制 MariaDB 缓冲池，避免 OOM
cat >/etc/mysql/mariadb.conf.d/60-lowmem.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size = 128M
performance_schema = off
EOF
systemctl restart mariadb

# ==================== 3. 下载并部署 WordPress ====================
mkdir -p "$WEB_ROOT"
TMP_DIR=$(mktemp -d)
curl -fsSL https://wordpress.org/latest.tar.gz -o "$TMP_DIR/wordpress.tar.gz"
tar -xzf "$TMP_DIR/wordpress.tar.gz" -C "$TMP_DIR"
rsync -a --delete "$TMP_DIR/wordpress/" "$WEB_ROOT/"
rm -rf "$TMP_DIR"

# 生成 wp-config.php
cp "$WEB_ROOT/wp-config-sample.php" "$WEB_ROOT/wp-config.php"
sed -i "s/database_name_here/${DB_NAME}/" "$WEB_ROOT/wp-config.php"
sed -i "s/username_here/${DB_USER}/" "$WEB_ROOT/wp-config.php"
sed -i "s/password_here/${DB_PASS}/" "$WEB_ROOT/wp-config.php"

# 插入官方随机安全密钥
SALT=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)
php -r '
$config = file_get_contents($argv[1]);
$salt = $argv[2];
$config = preg_replace(
    "/define\(\s*\x27AUTH_KEY\x27.*?put your unique phrase here.*?\);/s",
    "",
    $config
);
$marker = "/** Authentication unique keys and salts. */";
if (strpos($config, $marker) !== false) {
    $config = str_replace($marker, $marker . "\n" . $salt, $config);
}
file_put_contents($argv[1], $config);
' "$WEB_ROOT/wp-config.php" "$SALT" || true

chown -R www-data:www-data "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;

# ==================== 4. 配置 Nginx ====================
NGINX_CONF="/etc/nginx/sites-available/wordpress"
cat >"$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_HOST};
    root ${WEB_ROOT};
    index index.php index.html;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?)\$ {
        expires 30d;
        access_log off;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/wordpress
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx php${PHP_VERSION}-fpm
systemctl reload nginx

# ==================== 5. 可选：申请 HTTPS 证书 ====================
if [[ -n "$DOMAIN" && -n "$ADMIN_EMAIL" ]]; then
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect || \
    echo "证书申请失败，请检查域名是否已正确解析到本机 IP: ${SERVER_IP}"
fi

# ==================== 完成 ====================
echo ""
echo "=================================================="
echo " WordPress 安装完成！"
echo " 访问地址   : http://${SITE_HOST}/  (如已申请证书则为 https://)"
echo " 数据库名   : ${DB_NAME}"
echo " 数据库用户 : ${DB_USER}"
echo " 数据库密码 : ${DB_PASS}"
echo " 站点目录   : ${WEB_ROOT}"
echo ""
echo " 请打开浏览器访问上面的地址，完成 WordPress 安装向导（设置站点标题、管理员账号密码）。"
echo " 请务必保存好上面的数据库密码！"
echo "=================================================="
