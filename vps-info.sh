#!/usr/bin/env bash
# ============================================================
# VPS 信息采集脚本 v2
# 用途：全面采集本机运维相关信息，输出发给 AI 后，
#      AI 无需再反复追问即可理解环境、直接给出可执行操作。
# 用法：curl -fsSL <url> | bash   或   bash vps-info.sh
# 说明：只读取信息，不修改任何配置。容器环境变量只列出变量名，
#      不显示具体值，避免泄露密钥。
# ============================================================

sep() { echo; echo "==================== $1 ===================="; }
has() { command -v "$1" >/dev/null 2>&1; }

sep "基本信息 / Basic"
echo "采集时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')  本机时区: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo "主机名: $(hostname)"
echo "当前用户: $(whoami)"
[ "$(id -u)" = "0" ] && echo "是否 root: 是" || echo "是否 root: 否 (部分信息可能拿不到，建议 sudo 运行)"
echo "locale: $(locale 2>/dev/null | grep LANG=)"

sep "系统版本 / OS"
[ -f /etc/os-release ] && cat /etc/os-release
uname -a

sep "虚拟化类型 / Virtualization"
has systemd-detect-virt && echo "虚拟化: $(systemd-detect-virt 2>/dev/null)"

sep "CPU"
if has lscpu; then lscpu; else grep -m1 "model name" /proc/cpuinfo; fi
nproc --all 2>/dev/null | xargs -I{} echo "核心数: {}"

sep "内存 / Memory"
free -h
echo "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null)"

sep "磁盘 / Disk"
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
echo; echo "--- inode 使用率 ---"
df -i --exclude-type=tmpfs --exclude-type=devtmpfs 2>/dev/null
echo; lsblk 2>/dev/null

sep "系统运行时长 / Uptime & Load"
uptime

sep "资源占用 Top 进程"
echo "--- CPU占用前5 ---"
ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6
echo; echo "--- 内存占用前5 ---"
ps -eo pid,comm,%cpu,%mem --sort=-%mem 2>/dev/null | head -n 6

sep "网络接口 / Network Interfaces"
if has ip; then ip -brief addr; else ifconfig -a; fi

sep "公网 IP / Public IP"
for url in "https://ipv4.icanhazip.com" "https://api.ipify.org"; do
  if has curl; then
    ip_result=$(curl -s -m 5 "$url")
    [ -n "$ip_result" ] && echo "公网 IPv4: $ip_result" && break
  fi
done

sep "DNS 配置"
[ -f /etc/resolv.conf ] && cat /etc/resolv.conf

sep "关键内核网络参数 / sysctl"
for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.tcp_syncookies net.core.somaxconn; do
  v=$(sysctl -n "$k" 2>/dev/null)
  [ -n "$v" ] && echo "$k = $v"
done

sep "防火墙状态 / Firewall"
has ufw && { echo "--- ufw ---"; ufw status verbose 2>/dev/null; }
has firewall-cmd && { echo "--- firewalld ---"; firewall-cmd --list-all 2>/dev/null; }
has iptables && { echo "--- iptables (filter 表) ---"; iptables -L -n -v 2>/dev/null; }
has nft && { echo "--- nftables ---"; nft list ruleset 2>/dev/null; }
has fail2ban-client && { echo "--- fail2ban ---"; fail2ban-client status 2>/dev/null; }

sep "开放监听端口 / Listening Ports"
if has ss; then ss -tulnp 2>/dev/null; elif has netstat; then netstat -tulnp 2>/dev/null; fi

sep "包管理器 / Package Manager"
for pm in apt dnf yum apk pacman; do has "$pm" && echo "检测到: $pm"; done
if has apt; then
  upd=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
  echo "可更新的软件包数量: $upd"
fi

sep "Docker 概况"
if has docker; then
  echo "docker 版本: $(docker --version 2>/dev/null)"
  docker compose version >/dev/null 2>&1 && echo "docker compose 插件: $(docker compose version 2>/dev/null)"
  echo; echo "--- docker info 摘要 ---"
  docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Logging Driver|Cgroup Driver|Total Memory|CPUs"
  echo; echo "--- 磁盘占用 (docker system df) ---"
  docker system df 2>/dev/null
  echo; echo "--- daemon.json 配置 ---"
  [ -f /etc/docker/daemon.json ] && cat /etc/docker/daemon.json || echo "无自定义 daemon.json（使用默认配置，注意：默认无日志轮转限制）"
  echo; echo "--- 正在运行/已停止的容器 ---"
  docker ps -a 2>/dev/null
  echo; echo "--- 镜像列表 ---"
  docker images 2>/dev/null
  echo; echo "--- 网络 ---"
  docker network ls 2>/dev/null
  echo; echo "--- 数据卷 ---"
  docker volume ls 2>/dev/null

  echo; echo "--- 各容器详细信息 ---"
  for cid in $(docker ps -aq 2>/dev/null); do
    name=$(docker inspect --format='{{.Name}}' "$cid" | sed 's#^/##')
    echo "### 容器: $name ($cid) ###"
    docker inspect "$cid" --format '镜像: {{.Config.Image}}
重启策略: {{.HostConfig.RestartPolicy.Name}}
网络模式: {{.HostConfig.NetworkMode}}
端口映射: {{.NetworkSettings.Ports}}
日志驱动: {{.HostConfig.LogConfig.Type}}  日志参数: {{.HostConfig.LogConfig.Config}}
内存限制: {{.HostConfig.Memory}}  CPU限制: {{.HostConfig.NanoCpus}}
挂载: {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}); {{end}}
状态: {{.State.Status}}  启动时间: {{.State.StartedAt}}' 2>/dev/null
    echo "环境变量名(仅名称不含值): $(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | cut -d= -f1 | paste -sd, -)"
    logfile=$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null)
    [ -f "$logfile" ] && echo "日志文件大小: $(du -h "$logfile" 2>/dev/null | cut -f1)"
    echo
  done
else
  echo "未检测到 docker 命令"
fi

sep "常用运行时/语言环境"
for c in python3 python node npm git curl wget nginx caddy; do
  has "$c" && echo "$c: $("$c" --version 2>&1 | head -n1)"
done

sep "systemd 服务状态（已启用的服务列表 + 关键服务）"
if has systemctl; then
  echo "--- 已启用(enabled)的服务，开机自启 ---"
  systemctl list-unit-files --type=service --state=enabled 2>/dev/null | head -n 40
  echo; echo "--- 关键服务当前状态 ---"
  for svc in ssh sshd docker nginx caddy fail2ban ufw firewalld cron; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    [ -n "$state" ] && echo "$svc: $state"
  done
fi

sep "SSH 配置摘要"
if [ -f /etc/ssh/sshd_config ]; then
  grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|Protocol)" /etc/ssh/sshd_config 2>/dev/null | sort -u
fi
[ -f ~/.ssh/authorized_keys ] && echo "root 的 authorized_keys 条目数: $(grep -c '^ssh-' ~/.ssh/authorized_keys 2>/dev/null)"

sep "最近登录记录 (last, 最多10条)"
last -n 10 2>/dev/null

sep "当前登录用户"
who 2>/dev/null

sep "定时任务 / Crontab"
echo "--- root crontab ---"
crontab -l 2>/dev/null || echo "无 root crontab 或无权限查看"
echo; echo "--- /etc/cron.d 目录 ---"
ls -la /etc/cron.d 2>/dev/null

sep "ulimit 限制 (root shell)"
ulimit -a 2>/dev/null

sep "反向代理配置检测"
for f in /etc/nginx/nginx.conf /etc/nginx/sites-enabled /etc/caddy/Caddyfile; do
  [ -e "$f" ] && echo "发现配置: $f"
done

sep "采集完成"
echo "请把以上全部输出复制发给 AI。（容器环境变量只显示了变量名，未显示值，如需排查具体变量可单独提供）"
