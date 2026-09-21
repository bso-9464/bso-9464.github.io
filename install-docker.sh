#!/usr/bin/env bash
# Docker 一键安装脚本(针对 Debian 13 trixie / x86_64 / KVM VPS)
# - 使用 Docker 官方 apt 源,可重复运行(幂等)
# - 每一步都有检查,失败会明确提示并退出
# 用法: bash install-docker.sh 2>&1 | tee install-docker.log
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$1" >&2; exit 1; }
trap 'die "第 ${LINENO} 行出错,命令: ${BASH_COMMAND}"' ERR

APT="apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3"

# ---------- 0. 环境检查 ----------
step "0/6 环境检查"
[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

[ -r /etc/os-release ] || die "找不到 /etc/os-release"
. /etc/os-release
[ "${ID:-}" = "debian" ] || die "本脚本只适用于 Debian,当前系统: ${PRETTY_NAME:-未知}"
CODENAME="${VERSION_CODENAME:-}"
[ -n "$CODENAME" ] || die "无法识别 Debian 代号"
[ "$CODENAME" = "trixie" ] || warn "当前是 ${CODENAME},本脚本针对 trixie 调优,继续尝试"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "不支持的架构: $ARCH" ;;
esac

if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT="$(systemd-detect-virt || true)"
  case "$VIRT" in
    openvz|lxc|lxc-libvirt) die "虚拟化类型为 $VIRT,通常无法运行 Docker" ;;
  esac
  echo "虚拟化: ${VIRT:-none}"
fi

[ "$(ps -p 1 -o comm= | tr -d ' ')" = "systemd" ] || die "PID 1 不是 systemd"
echo "系统: ${PRETTY_NAME}  架构: ${ARCH}"

# ---------- 1. 依赖 ----------
step "1/6 安装依赖 (ca-certificates curl iptables)"
$APT update
$APT install -y ca-certificates curl iptables

# ---------- 2. GPG 密钥 ----------
step "2/6 导入 Docker 官方 GPG 密钥"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 3 --connect-timeout 10 \
  https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
[ -s /etc/apt/keyrings/docker.asc ] || die "GPG 密钥下载失败或为空"
chmod a+r /etc/apt/keyrings/docker.asc

# ---------- 3. 软件源 ----------
step "3/6 添加 Docker 官方软件源"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
$APT update
CANDIDATE="$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')"
{ [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ]; } \
  || die "软件源里找不到 docker-ce,请检查 /etc/apt/sources.list.d/docker.sources"
echo "将安装 docker-ce 版本: ${CANDIDATE}"

# ---------- 4. 安装 ----------
step "4/6 安装 Docker Engine / Compose / Buildx"
$APT install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# ---------- 5. 配置并启动 ----------
step "5/6 配置并启动 Docker"
modprobe overlay 2>/dev/null || warn "modprobe overlay 失败,稍后由验证步骤确认"
echo overlay > /etc/modules-load.d/overlay.conf

# 限制容器日志大小,避免 20G 小磁盘被日志写满(已有配置则不覆盖)
if [ -e /etc/docker/daemon.json ]; then
  warn "/etc/docker/daemon.json 已存在,不覆盖。建议手动加入日志大小限制"
else
  install -d /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
fi

systemctl enable docker containerd >/dev/null 2>&1
systemctl restart docker

for i in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { journalctl -u docker --no-pager -n 30 || true; die "Docker 守护进程 30 秒内未就绪"; }
  sleep 1
done

# ---------- 6. 验证 ----------
step "6/6 验证安装"
echo "服务状态: $(systemctl is-active docker)"
docker --version
docker compose version
docker info 2>/dev/null | grep -E 'Storage Driver|Cgroup Version|Logging Driver' || true

if docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; then
  printf '\n\033[1;32m✔ Docker 安装成功,hello-world 运行正常\033[0m\n'
else
  die "hello-world 运行失败,请把上面的完整输出发给我"
fi

echo
echo "提示: 用 -p 发布的端口会直接暴露公网并绕过 ufw;仅本机访问请用 -p 127.0.0.1:8080:80"
