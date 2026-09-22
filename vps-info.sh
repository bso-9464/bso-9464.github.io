#!/usr/bin/env bash
# ============================================================
# VPS 信息采集脚本
# 用途：一键收集本机关键信息，把输出完整发给 AI，
#      方便 AI 在不用反复追问的情况下了解环境并给出操作建议。
# 用法：bash vps-info.sh   (建议用 root 或 sudo 运行)
# 说明：只读取信息，不修改任何配置，可放心运行。
# ============================================================

sep() { echo; echo "==================== $1 ===================="; }
has() { command -v "$1" >/dev/null 2>&1; }

sep "基本信息 / Basic"
echo "采集时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "主机名: $(hostname)"
whoami | xargs -I{} echo "当前用户: {}"
[ "$(id -u)" = "0" ] && echo "是否 root: 是" || echo "是否 root: 否 (部分信息可能拿不到，建议 sudo 运行)"

sep "系统版本 / OS"
if [ -f /etc/os-release ]; then cat /etc/os-release; fi
uname -a

sep "虚拟化类型 / Virtualization"
if has systemd-detect-virt; then
  echo "虚拟化: $(systemd-detect-virt 2>/dev/null)"
fi

sep "CPU"
if has lscpu; then lscpu; else grep -m1 "model name" /proc/cpuinfo; fi
nproc --all 2>/dev/null | xargs -I{} echo "核心数: {}"

sep "内存 / Memory"
free -h

sep "磁盘 / Disk"
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
echo
lsblk 2>/dev/null

sep "系统运行时长 / Uptime & Load"
uptime

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

sep "防火墙状态 / Firewall"
if has ufw; then echo "--- ufw ---"; ufw status verbose 2>/dev/null; fi
if has firewall-cmd; then echo "--- firewalld ---"; firewall-cmd --list-all 2>/dev/null; fi
if has iptables; then echo "--- iptables (filter 表) ---"; iptables -L -n -v 2>/dev/null; fi
if has nft; then echo "--- nftables ---"; nft list ruleset 2>/dev/null; fi

sep "开放监听端口 / Listening Ports"
if has ss; then ss -tulnp 2>/dev/null; elif has netstat; then netstat -tulnp 2>/dev/null; fi

sep "包管理器 / Package Manager"
for pm in apt dnf yum apk pacman; do
  has "$pm" && echo "检测到: $pm"
done

sep "Docker 相关"
if has docker; then
  echo "docker 版本: $(docker --version 2>/dev/null)"
  has docker-compose && echo "docker-compose 版本: $(docker-compose --version 2>/dev/null)"
  docker compose version >/dev/null 2>&1 && echo "docker compose 插件: $(docker compose version 2>/dev/null)"
  echo; echo "--- 正在运行的容器 ---"
  docker ps -a 2>/dev/null
  echo; echo "--- 镜像列表 ---"
  docker images 2>/dev/null
  echo; echo "--- 网络 ---"
  docker network ls 2>/dev/null
else
  echo "未检测到 docker 命令"
fi

sep "常用运行时/语言环境"
for c in python3 python node npm git curl wget nginx caddy; do
  if has "$c"; then
    ver=$("$c" --version 2>&1 | head -n1)
    echo "$c: $ver"
  fi
done

sep "systemd 关键服务状态"
for svc in ssh sshd docker nginx caddy fail2ban ufw firewalld; do
  if has systemctl; then
    state=$(systemctl is-active "$svc" 2>/dev/null)
    [ -n "$state" ] && echo "$svc: $state"
  fi
done

sep "SSH 配置摘要"
if [ -f /etc/ssh/sshd_config ]; then
  grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" /etc/ssh/sshd_config 2>/dev/null
fi

sep "定时任务 / Crontab (root)"
crontab -l 2>/dev/null || echo "无 root crontab 或无权限查看"

sep "采集完成"
echo "请把以上全部输出复制发给 AI。"
