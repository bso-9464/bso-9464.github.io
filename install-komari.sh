#!/usr/bin/env bash
# =====================================================================
# Komari 探针面板 一键安装脚本 (Docker Compose 版)
# 适配环境: Debian 13 / KVM / 已装 Docker + compose 插件 / root
#
# 用法:
#   bash install-komari.sh                     安装 / 升级
#   PORT=25775 bash install-komari.sh          换面板端口(仅首次安装生效)
#   BIND_IP=127.0.0.1 bash install-komari.sh   只监听本机(配合反代/SSH 隧道)
#   bash install-komari.sh uninstall           卸载(保留数据)
#   bash install-komari.sh uninstall --purge   卸载并删除数据
# =====================================================================
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/komari}"
PORT="${PORT:-25774}"
BIND_IP="${BIND_IP:-0.0.0.0}"
ADMIN_USER="${ADMIN_USER:-admin}"
IMAGE="ghcr.io/komari-monitor/komari:latest"

G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
info() { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[✗]${N} $*" >&2; exit 1; }
trap 'die "第 $LINENO 行出错,已中止: $BASH_COMMAND"' ERR

[[ $EUID -eq 0 ]] || die "请使用 root 运行"

# ---------------------------- 卸载 ----------------------------
if [[ "${1:-}" == "uninstall" ]]; then
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    (cd "$INSTALL_DIR" && docker compose down)
    info "容器已移除"
  fi
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  if [[ "${2:-}" == "--purge" ]]; then
    rm -rf "$INSTALL_DIR"
    info "已删除 $INSTALL_DIR(含数据)"
  else
    info "数据仍保留在 $INSTALL_DIR/data"
  fi
  exit 0
fi

# ---------------------------- 环境检查 ----------------------------
command -v docker >/dev/null        || die "未检测到 docker"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"
docker info >/dev/null 2>&1         || die "docker 守护进程未运行"
command -v openssl >/dev/null       || die "缺少 openssl"
info "Docker $(docker version --format '{{.Server.Version}}') / $(docker compose version --short) 就绪"

# ---------------------------- 目录与配置 ----------------------------
mkdir -p "$INSTALL_DIR/data"
chmod 700 "$INSTALL_DIR"
ENV_FILE="$INSTALL_DIR/.env"
NEW_INSTALL=0

if [[ -f "$ENV_FILE" ]]; then
  info "沿用已有配置 $ENV_FILE(账号密码不会改动)"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口不合法: $PORT"
  if [[ -n "$(ls -A "$INSTALL_DIR/data" 2>/dev/null)" ]]; then
    warn "data 目录已有数据: 环境变量里的账号密码只在首次初始化时生效,登录请用原账号"
  fi
  ADMIN_USERNAME="$ADMIN_USER"
  ADMIN_PASSWORD="$(openssl rand -hex 12)"
  KOMARI_BIND="$BIND_IP"
  KOMARI_PORT="$PORT"
  (
    umask 077
    cat >"$ENV_FILE" <<EOF
KOMARI_BIND=$KOMARI_BIND
KOMARI_PORT=$KOMARI_PORT
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
  )
  NEW_INSTALL=1
  info "已生成随机管理员密码并写入 $ENV_FILE (权限 600)"
fi

# ---------------------------- 端口占用检查 ----------------------------
if ! docker ps --format '{{.Names}}' | grep -qx komari; then
  if ss -H -ltn "sport = :$KOMARI_PORT" | grep -q .; then
    die "端口 $KOMARI_PORT 已被占用(本机已占用 22 / 4892 / 8484),请换端口后重试"
  fi
fi

# ---------------------------- 生成 compose ----------------------------
cat >"$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: komari
    restart: unless-stopped
    ports:
      - "${KOMARI_BIND}:${KOMARI_PORT}:25774"
    volumes:
      - ./data:/app/data
    environment:
      ADMIN_USERNAME: ${ADMIN_USERNAME}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
    mem_limit: 256m
EOF
info "已生成 $INSTALL_DIR/docker-compose.yml"

# ---------------------------- 拉取并启动 ----------------------------
cd "$INSTALL_DIR"
for i in 1 2 3; do
  if docker compose pull; then break; fi
  [[ $i -eq 3 ]] && die "镜像拉取失败(ghcr.io),请稍后重试"
  warn "拉取失败,重试 $i/3 ..."
  sleep 3
done
docker compose up -d

ok=0
for _ in $(seq 1 30); do
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${KOMARI_PORT}/"; then ok=1; break; fi
  sleep 1
done
if [[ $ok -ne 1 ]]; then
  docker logs --tail 30 komari || true
  die "服务未在 30 秒内就绪,请查看上面的日志"
fi
info "Komari 已启动"

# ---------------------------- 结果输出 ----------------------------
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
IP="${IP:-<服务器IP>}"

echo
echo "=============================================================="
echo " 面板地址: http://${IP}:${KOMARI_PORT}"
echo " 后台地址: http://${IP}:${KOMARI_PORT}/admin"
if [[ $NEW_INSTALL -eq 1 ]]; then
  echo " 用户名:   ${ADMIN_USERNAME}"
  echo " 密码:     ${ADMIN_PASSWORD}   (请立即保存)"
else
  echo " 账号密码: 见 $ENV_FILE"
fi
echo "--------------------------------------------------------------"
echo " 目录:     $INSTALL_DIR   数据: $INSTALL_DIR/data"
echo " 日志:     docker logs -f komari"
echo " 重启:     cd $INSTALL_DIR && docker compose restart"
echo " 升级:     bash $0      (重新执行即可,数据不丢)"
echo " 备份:     tar czf komari-backup-\$(date +%F).tgz -C $INSTALL_DIR data"
echo " 卸载:     bash $0 uninstall [--purge]"
echo "=============================================================="
if [[ "$KOMARI_BIND" == "0.0.0.0" ]]; then
  warn "当前为 HTTP 明文暴露在公网: 登录密码和 Agent 令牌均未加密。"
  warn "建议尽快套 HTTPS 反代,或改为 BIND_IP=127.0.0.1 后用 SSH 隧道访问后台。"
fi
warn "下一步: 登录后台 → 服务器 → 添加,复制它生成的 Agent 安装命令到被监控的 VPS 上执行。"
