#!/usr/bin/env bash
# Docker 安装前环境检测脚本
# 只读:不会安装、修改或删除任何东西;不输出公网 IP 和主机名
# 用法: bash docker-precheck.sh 2>&1 | tee docker-precheck.txt
export LC_ALL=C
set +e

sec() { printf '\n===== %s =====\n' "$1"; }
has() { command -v "$1" >/dev/null 2>&1; }
T=""; has timeout && T="timeout 15"

sec "1. 基本信息"
date -u
echo "user: $(id -un)  uid=$(id -u)"
has sudo && echo "sudo: 有" || echo "sudo: 无"
echo "arch: $(uname -m)"
uname -srv

sec "2. 操作系统"
if [ -f /etc/os-release ]; then
  grep -E '^(PRETTY_NAME|NAME|VERSION_ID|VERSION_CODENAME|ID|ID_LIKE)=' /etc/os-release
else
  echo "/etc/os-release 不存在"
  cat /etc/*release 2>/dev/null | head -5
fi

sec "3. 虚拟化类型 (OpenVZ/LXC 通常无法运行 Docker)"
has systemd-detect-virt && echo "systemd-detect-virt: $(systemd-detect-virt 2>&1)"
[ -f /proc/user_beancounters ] && echo "!! 检测到 /proc/user_beancounters (疑似 OpenVZ)"
[ -f /.dockerenv ] && echo "!! 当前已在 Docker 容器内"
grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && echo "!! 疑似 LXC 容器"
grep -qi -E 'hypervisor' /proc/cpuinfo 2>/dev/null && echo "cpuinfo: 含 hypervisor 标志 (常见于 KVM 等)"

sec "4. 初始化系统 / systemd"
echo "PID 1: $(ps -p 1 -o comm= 2>/dev/null)"
has systemctl && echo "systemd 状态: $($T systemctl is-system-running 2>&1)"

sec "5. 资源"
echo "CPU 核数: $(nproc 2>/dev/null)"
free -m 2>/dev/null
df -h / /var 2>/dev/null
df -i / 2>/dev/null

sec "6. 包管理器"
for p in apt-get dnf yum apk zypper pacman; do has "$p" && echo "有: $p"; done
has pgrep && pgrep -a -f 'apt|dpkg|unattended|yum|dnf' 2>/dev/null | grep -v pgrep | head -5

sec "7. 已有的 Docker / 容器相关组件"
for b in docker dockerd containerd runc podman; do has "$b" && echo "$b: $(command -v $b)"; done
has docker && docker --version 2>&1
if has systemctl; then
  echo "docker 服务: active=$($T systemctl is-active docker 2>&1) enabled=$($T systemctl is-enabled docker 2>&1)"
fi
has dpkg && dpkg -l 2>/dev/null | grep -Ei 'docker|containerd|podman|runc' | awk '{print $1,$2,$3}'
has rpm && rpm -qa 2>/dev/null | grep -Ei 'docker|containerd|podman|runc'
has snap && snap list 2>/dev/null | grep -i docker
echo "--- 已配置的 docker 软件源 ---"
grep -rl -i docker /etc/apt/sources.list /etc/apt/sources.list.d /etc/yum.repos.d 2>/dev/null
echo "--- /etc/docker/daemon.json ---"
[ -f /etc/docker/daemon.json ] && cat /etc/docker/daemon.json || echo "(不存在)"

sec "8. 内核能力"
echo "overlayfs 支持: $(grep -qw overlay /proc/filesystems && echo 是 || echo 否)"
echo "cgroup 类型: $(stat -fc %T /sys/fs/cgroup 2>&1)  (cgroup2fs=v2, tmpfs=v1)"
lsmod 2>/dev/null | grep -E '^(overlay|br_netfilter|bridge|veth|nf_tables|ip_tables|xt_conntrack)\b' | awk '{print $1}' | tr '\n' ' '; echo
has modprobe && modprobe -n -v overlay 2>&1 | head -2
[ -e /dev/net/tun ] && echo "/dev/net/tun: 有" || echo "/dev/net/tun: 无"
echo "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>&1)"

sec "9. 防火墙 / 安全模块"
has iptables && iptables --version 2>&1
has nft && nft --version 2>&1
has update-alternatives && update-alternatives --query iptables 2>/dev/null | grep -E '^(Value|Status):'
has ufw && echo "ufw: $(ufw status 2>&1 | head -1)"
has firewall-cmd && echo "firewalld: $(firewall-cmd --state 2>&1)"
has getenforce && echo "SELinux: $(getenforce 2>&1)"

sec "10. 时间同步"
has timedatectl && timedatectl 2>/dev/null | grep -E 'Time zone|synchronized|NTP'

sec "11. DNS"
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null
has getent && echo "解析 download.docker.com: $(getent hosts download.docker.com | head -1 | awk '{print $1}')"

sec "12. 网络连通性 (HTTP 状态码 耗时)"
if has curl; then
  chk() { r=$($T curl -sS -o /dev/null -m 10 -w '%{http_code} %{time_total}s' "$1" 2>&1 | tail -1); printf '%-58s %s\n' "$1" "$r"; }
  chk https://download.docker.com/linux/ubuntu/gpg
  chk https://get.docker.com
  chk https://registry-1.docker.io/v2/
  chk https://hub.docker.com
  chk https://github.com
  chk https://mirrors.aliyun.com/docker-ce/
  chk https://mirrors.tuna.tsinghua.edu.cn/docker-ce/
  chk https://mirrors.ustc.edu.cn/docker-ce/
  echo "服务器所在国家: $($T curl -s -m 8 https://ipinfo.io/country 2>&1 | head -1)"
else
  echo "!! 未安装 curl"
  has wget && echo "有 wget" || echo "!! 也没有 wget"
fi

sec "完成"
echo "请把以上全部输出复制发给我"
