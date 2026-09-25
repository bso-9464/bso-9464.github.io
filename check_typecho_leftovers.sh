#!/usr/bin/env bash
#
# check_typecho_leftovers.sh
# 用于检查 Typecho 卸载后是否还有残留文件、数据库、nginx 配置、证书、
# cron 任务、php-fpm 池等。只做检测和列出，不做任何删除操作。
#
# 用法: bash check_typecho_leftovers.sh
#

set -uo pipefail

DOMAIN_HINT="${1:-}"   # 可选：传入域名关键字，比如 22.584136.xyz

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

found_any=0

section () {
    echo
    echo "==================== $1 ===================="
}

report_empty () {
    echo -e "${GREEN}[OK] 未发现残留${NC}"
}

report_found () {
    echo -e "${RED}[!] 发现残留:${NC}"
    found_any=1
}

# 1. 网站文件 / 代码残留
section "1. 网站文件残留 (常见 web 根目录)"
paths_found=$(find /var/www /home /srv /usr/share/nginx 2>/dev/null \
    -maxdepth 6 -iname "*typecho*" 2>/dev/null)
if [ -n "$paths_found" ]; then
    report_found
    echo "$paths_found"
else
    report_empty
fi

# 2. 全盘搜索 Typecho 特征文件 (config.inc.php 内含 Typecho 关键字, install.php 等)
section "2. 全盘搜索 Typecho 安装特征文件"
feature_files=$(find / -not -path "/proc/*" -not -path "/sys/*" \
    \( -iname "config.inc.php" -o -iname "install.php" \) 2>/dev/null)
if [ -n "$feature_files" ]; then
    report_found
    for f in $feature_files; do
        if grep -qi "typecho" "$f" 2>/dev/null; then
            echo "$f  <-- 内容含 'Typecho' 关键字"
        else
            echo "$f  (未确认是否为 Typecho, 建议人工查看)"
        fi
    done
else
    report_empty
fi

# 3. 数据库残留
section "3. MySQL/MariaDB 数据库与用户残留"
if command -v mysql >/dev/null 2>&1; then
    echo "尝试以 root 身份检查数据库（可能会提示输入密码，或使用 socket 认证自动通过）..."
    db_list=$(mysql -u root -N -e "SHOW DATABASES LIKE '%typecho%';" 2>/dev/null)
    user_list=$(mysql -u root -N -e "SELECT User FROM mysql.user WHERE User LIKE '%typecho%';" 2>/dev/null)
    if [ -n "$db_list" ] || [ -n "$user_list" ]; then
        report_found
        [ -n "$db_list" ] && echo "残留数据库: $db_list"
        [ -n "$user_list" ] && echo "残留数据库用户: $user_list"
    else
        report_empty
    fi
else
    echo -e "${YELLOW}[跳过] 未检测到 mysql 客户端命令${NC}"
fi

# 4. nginx 配置残留
section "4. nginx 配置残留"
nginx_hits=$(grep -rls "typecho" /etc/nginx/ 2>/dev/null)
if [ -n "$DOMAIN_HINT" ]; then
    nginx_hits="$nginx_hits
$(grep -rls "$DOMAIN_HINT" /etc/nginx/ 2>/dev/null)"
fi
nginx_hits=$(echo "$nginx_hits" | sed '/^$/d' | sort -u)
if [ -n "$nginx_hits" ]; then
    report_found
    echo "$nginx_hits"
else
    report_empty
fi

# 5. Let's Encrypt 证书残留
section "5. Let's Encrypt 证书残留"
cert_hits=""
if [ -n "$DOMAIN_HINT" ]; then
    cert_hits=$(find /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal \
        -iname "*${DOMAIN_HINT}*" 2>/dev/null)
else
    cert_hits=$(find /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal \
        -iname "*typecho*" 2>/dev/null)
fi
if [ -n "$cert_hits" ]; then
    report_found
    echo "$cert_hits"
else
    report_empty
    echo "(提示: 未指定域名时只按 'typecho' 关键字匹配，建议加参数指定域名重新检查，例如:"
    echo " bash $0 22.584136.xyz )"
fi

# 6. php-fpm 池配置残留
section "6. php-fpm 池配置残留"
fpm_hits=$(grep -rls "typecho" /etc/php/*/fpm/pool.d/ 2>/dev/null)
if [ -n "$fpm_hits" ]; then
    report_found
    echo "$fpm_hits"
else
    report_empty
fi

# 7. cron 任务残留
section "7. cron 任务残留"
cron_hits=""
for cf in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
    [ -f "$cf" ] || continue
    if grep -qi "typecho" "$cf" 2>/dev/null; then
        cron_hits="$cron_hits
$cf"
    fi
done
if command -v crontab >/dev/null 2>&1; then
    root_cron=$(crontab -l 2>/dev/null | grep -i "typecho")
    [ -n "$root_cron" ] && cron_hits="$cron_hits
root crontab: $root_cron"
fi
cron_hits=$(echo "$cron_hits" | sed '/^$/d')
if [ -n "$cron_hits" ]; then
    report_found
    echo "$cron_hits"
else
    report_empty
fi

# 8. systemd 自定义服务残留
section "8. systemd 自定义服务残留"
systemd_hits=$(grep -rls "typecho" /etc/systemd/system/ 2>/dev/null)
if [ -n "$systemd_hits" ]; then
    report_found
    echo "$systemd_hits"
else
    report_empty
fi

# 9. 备份文件提醒
section "9. 之前生成的备份文件"
backup_hits=$(find /root -maxdepth 1 -iname "*typecho*" 2>/dev/null)
if [ -n "$backup_hits" ]; then
    echo -e "${YELLOW}[提示] 发现之前的备份文件，确认无需恢复后可自行删除:${NC}"
    echo "$backup_hits"
else
    echo "未发现 /root 下的备份文件"
fi

echo
section "检查完成"
if [ "$found_any" -eq 1 ]; then
    echo -e "${RED}结论: 发现残留项，请根据上方列表逐项确认并手动清理。${NC}"
else
    echo -e "${GREEN}结论: 未发现明显残留，Typecho 已清理干净。${NC}"
fi
