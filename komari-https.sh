#!/usr/bin/env bash
# =====================================================================
# Komari 面板 HTTPS 一键脚本 (Caddy 自动申请 / 续期 Let's Encrypt 证书)
#
# 前置条件:
#   1. 已用 install-komari.sh 装好 Komari (/opt/komari)
#   2. 域名 A 记录已解析到本机 IPv4
#   3. 本机 80 / 443 端口空闲, 且云厂商侧未拦截
#
# 用法:
#   DOMAIN=probe.example.com bash komari-https.sh
#   DOMAIN=probe.example.com EMAIL=me@example.com bash komari-https.sh
#   KEEP_HTTP=1 DOMAIN=...   bash komari-https.sh   # 保留旧的 HTTP 端口(过渡用)
#   SKIP_DNS_CHECK=1 DOMAIN=... bash komari-https.sh # 跳过解析检查(套了 CDN 时)
#   bash komari-https.sh revert                      # 回退到 HTTP, 停止 Caddy
#   bash komari-https.sh revert --purge              # 回退并删除 Caddy 目录和证书
# =====================================================================
set -Eeuo pipefail

KOMARI_DIR="${KOMARI_DIR:-/opt/komari}"
CADDY_DIR="${CADDY_DIR:-/opt/caddy}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
KEEP_HTTP="${KEEP_HTTP:-0}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
info() { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[✗]${N} $*" >&2; exit 1; }
trap 'die "第 $LINENO 行出错,已中止: $BASH_COMMAND"' ERR

[[ $EUID -eq 0 ]] || die "请使用 root 运行"

# ---------------------------- 回退 ----------------------------
if [[ "${1:-}" == "revert" ]]; then
  if [[ -f "$KOMARI_DIR/.env.pre-https" ]]; then
    cp -f "$KOMARI_DIR/.env.pre-https" "$KOMARI_DIR/.env"
    (cd "$KOMARI_DIR" && docker compose up -d)
    info "Komari 已恢复为原来的监听地址"
  else
    warn "未找到 $KOMARI_DIR/.env.pre-https, 跳过 Komari 部分"
  fi
  if [[ -f "$CADDY_DIR/docker-compose.yml" ]]; then
    (cd "$CADDY_DIR" && docker compose down)
    info "Caddy 已停止"
  fi
  if [[ "${2:-}" == "--purge" ]]; then
    rm -rf "$CADDY_DIR"
    info "已删除 $CADDY_DIR (含证书)"
  else
    info "Caddy 目录与证书保留在 $CADDY_DIR"
  fi
  exit 0
fi

# ---------------------------- 参数与环境检查 ----------------------------
[[ -n "$DOMAIN" ]] || die "请指定域名,例如: DOMAIN=probe.example.com bash komari-https.sh"
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "域名格式不正确: $DOMAIN"

command -v docker >/dev/null           || die "未检测到 docker"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"
docker info >/dev/null 2>&1            || die "docker 守护进程未运行"
[[ -f "$KOMARI_DIR/docker-compose.yml" && -f "$KOMARI_DIR/.env" ]] \
  || die "未找到 $KOMARI_DIR, 请先运行 install-komari.sh"
docker ps --format '{{.Names}}' | grep -qx komari || die "komari 容器未运行, 请先启动: cd $KOMARI_DIR && docker compose up -d"

KOMARI_PORT="$(grep -E '^KOMARI_PORT=' "$KOMARI_DIR/.env" | tail -n1 | cut -d= -f2 || true)"
KOMARI_PORT="${KOMARI_PORT:-25774}"
info "Komari 端口 $KOMARI_PORT, 目标域名 $DOMAIN"

# 80/443 是否空闲(已有本脚本的 caddy 在跑则跳过)
if ! docker ps --format '{{.Names}}' | grep -qx komari-caddy; then
  for p in 80 443; do
    if ss -H -ltn "sport = :$p" | grep -q .; then
      die "端口 $p 已被占用, 无法启动 Caddy, 请先释放该端口"
    fi
  done
fi

# ---------------------------- 域名解析检查 ----------------------------
LOCAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
if [[ "$SKIP_DNS_CHECK" != "1" ]]; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
  [[ -n "$RESOLVED" ]] || die "域名 $DOMAIN 还没有解析, 请先添加 A 记录指向 ${LOCAL_IP:-本机IP} (刚改完可等几分钟)"
  if [[ "$RESOLVED" != "$LOCAL_IP" ]]; then
    PUB_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
    [[ -n "$PUB_IP" && "$RESOLVED" == "$PUB_IP" ]] \
      || die "域名解析到 $RESOLVED, 但本机地址是 ${PUB_IP:-$LOCAL_IP}。若套了 CDN 请加 SKIP_DNS_CHECK=1"
  fi
  AAAA="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}' || true)"
  if [[ -n "$AAAA" ]] && ! ip -6 addr show 2>/dev/null | grep -q "$AAAA"; then
    warn "域名有 AAAA 记录 $AAAA, 但不是本机 IPv6, Let's Encrypt 可能优先走 IPv6 导致验证失败, 建议删除该记录"
  fi
  info "域名解析正确: $DOMAIN -> $RESOLVED"
fi

# ---------------------------- 生成 Caddy 配置 ----------------------------
mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config"

{
  if [[ -n "$EMAIL" ]]; then printf '{\n    email %s\n}\n\n' "$EMAIL"; fi
  printf '%s {\n    encode zstd gzip\n    reverse_proxy 127.0.0.1:%s\n}\n' "$DOMAIN" "$KOMARI_PORT"
} >"$CADDY_DIR/Caddyfile"

cat >"$CADDY_DIR/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2
    container_name: komari-caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    mem_limit: 128m
EOF
info "已生成 $CADDY_DIR/Caddyfile 与 docker-compose.yml"

# ---------------------------- 启动 Caddy 并等待证书 ----------------------------
cd "$CADDY_DIR"
for i in 1 2 3; do
  if docker compose pull; then break; fi
  [[ $i -eq 3 ]] && die "镜像拉取失败, 请稍后重试"
  warn "拉取失败, 重试 $i/3 ..."
  sleep 3
done
docker compose up -d

info "等待 Caddy 申请证书(最多约 90 秒)..."
ok=0
for _ in $(seq 1 45); do
  if curl -s -o /dev/null --max-time 5 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/"; then ok=1; break; fi
  sleep 2
done
if [[ $ok -ne 1 ]]; then
  docker logs --tail 40 komari-caddy || true
  docker compose down || true
  die "证书申请失败, 已停止 Caddy 以免反复重试触发限流; Komari 仍保持原样(HTTP)可用。请检查: 域名解析 / 80 端口是否对外可达 / 有无 AAAA 记录"
fi
info "HTTPS 已生效, 证书签发成功"

# ---------------------------- 关闭 HTTP 公网入口 ----------------------------
if [[ "$KEEP_HTTP" == "1" ]]; then
  warn "KEEP_HTTP=1: 保留 Komari 的 HTTP 公网端口, 过渡完成后请重新运行本脚本(不带 KEEP_HTTP)以关闭"
else
  cd "$KOMARI_DIR"
  [[ -f .env.pre-https ]] || cp -p .env .env.pre-https
  if grep -q '^KOMARI_BIND=' .env; then
    sed -i 's/^KOMARI_BIND=.*/KOMARI_BIND=127.0.0.1/' .env
  else
    [[ -z "$(tail -c1 .env)" ]] || echo >>.env
    echo 'KOMARI_BIND=127.0.0.1' >>.env
  fi
  docker compose up -d
  ok=0
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${KOMARI_PORT}/"; then ok=1; break; fi
    sleep 1
  done
  [[ $ok -eq 1 ]] || { docker logs --tail 30 komari || true; die "Komari 重启后未就绪, 可执行: bash komari-https.sh revert"; }
  info "Komari 已改为仅监听 127.0.0.1:${KOMARI_PORT}, 公网 HTTP 入口已关闭"
fi

# ---------------------------- 结果输出 ----------------------------
echo
echo "=============================================================="
echo " 面板地址: https://${DOMAIN}"
echo " 后台地址: https://${DOMAIN}/admin"
echo "--------------------------------------------------------------"
echo " Caddy 目录:  $CADDY_DIR   (证书在 $CADDY_DIR/data, 自动续期)"
echo " Caddy 日志:  docker logs -f komari-caddy"
echo " 回退:        bash komari-https.sh revert [--purge]"
echo "=============================================================="
warn "旧的 Agent 若使用 http://<IP>:${KOMARI_PORT} 会断线, 请改用 https://${DOMAIN} 重新安装。"
warn "本机 Agent 请使用 http://127.0.0.1:${KOMARI_PORT} (仍可用)。"
warn "升级 Komari 请用: cd $KOMARI_DIR && docker compose pull && docker compose up -d"
