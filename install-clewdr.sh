#!/usr/bin/env bash
# ClewdR 一键部署脚本 (Docker · 环境变量配置方式 · 针对 Debian 13 VPS)
# 只使用环境变量配置:不挂载 clewdr.toml,不混用两种方式。
#
# 用法:  bash install-clewdr.sh
#
# 可选环境变量(都不是必须的):
#   ADMIN_PASSWORD   前端登录密码 (默认随机生成)
#   API_PASSWORD     API 访问密钥  (默认随机生成)
#   COOKIE_ARRAY     Claude Cookie,按官方文档格式原样传入,如 [[COOKIE 1],[COOKIE 2]]
#   GEMINI_KEYS      Gemini 密钥,  按官方文档格式原样传入
#   BIND_IP          监听地址,默认 0.0.0.0;只想本机/SSH 隧道访问请用 127.0.0.1
#   PORT             监听端口,默认 8484
#   PROXY            上游代理地址
#   MAX_RETRIES      失败重试次数,默认 10
#   CACHE_RESPONSE   缓存并发数,默认 0 (不启用)
#   DIR              部署目录,默认 /opt/clewdr
#   FORCE=1          忽略已有配置,重新生成 (旧配置会备份)
set -Eeuo pipefail

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$1" >&2; exit 1; }
trap 'die "第 ${LINENO} 行出错,命令: ${BASH_COMMAND}"' ERR

DIR="${DIR:-/opt/clewdr}"
BIND_IP="${BIND_IP:-0.0.0.0}"
PORT="${PORT:-8484}"
PROXY="${PROXY:-}"
MAX_RETRIES="${MAX_RETRIES:-10}"
CACHE_RESPONSE="${CACHE_RESPONSE:-0}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
API_PASSWORD="${API_PASSWORD:-}"
COOKIE_ARRAY="${COOKIE_ARRAY:-}"
GEMINI_KEYS="${GEMINI_KEYS:-}"
FORCE="${FORCE:-0}"
ENVF="$DIR/clewdr.env"

# ---------- 0. 环境检查 ----------
step "0/4 环境检查"
[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
command -v curl   >/dev/null 2>&1 || die "缺少 curl: apt-get install -y curl"
command -v docker >/dev/null 2>&1 || die "未检测到 docker,请先运行 Docker 安装脚本"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"
docker info >/dev/null 2>&1 || die "Docker 守护进程未运行,先执行: systemctl start docker"

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  die "PORT 不合法: $PORT"
fi
[[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]    || die "MAX_RETRIES 必须是数字"
[[ "$CACHE_RESPONSE" =~ ^[0-9]+$ ]] || die "CACHE_RESPONSE 必须是数字"

# 端口占用检查(容器已存在时是重复运行,跳过)
EXISTING="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
if ! grep -qx clewdr <<<"$EXISTING"; then
  LISTEN="$(ss -ltnH "sport = :$PORT" 2>/dev/null || true)"
  [ -z "$LISTEN" ] || die "端口 $PORT 已被占用,可用 PORT=xxxx 换一个端口"
fi

GHCR="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://ghcr.io/v2/ 2>/dev/null || true)"
case "$GHCR" in
  200|401) echo "ghcr.io 可访问" ;;
  *) warn "ghcr.io 连通性异常 (HTTP ${GHCR:-000}),拉取镜像可能失败" ;;
esac

# ---------- 1. 生成配置 ----------
step "1/4 生成环境变量配置 ($ENVF)"
mkdir -p "$DIR"
chmod 700 "$DIR"

gen() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

check_plain() {
  [[ "$2" =~ ^[A-Za-z0-9._@%+:,~-]+$ ]] \
    || die "$1 只能包含字母、数字和 . _ @ % + : , ~ - ,不能有空格、引号或 \$"
}

check_array() {
  case "$2" in
    *"'"*|*$'\n'*) die "$1 里不能包含单引号或换行" ;;
  esac
}

ask_secret() {   # 变量名 提示语;没有终端时直接跳过
  local var="$1" prompt="$2" val=""
  if [ -n "${!var:-}" ]; then return 0; fi
  if { true </dev/tty; } 2>/dev/null; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r -s val </dev/tty || true
    printf '\n' >/dev/tty
    val="$(printf '%s' "$val" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf -v "$var" '%s' "$val"
  fi
  return 0
}

if [ -f "$ENVF" ] && [ "$FORCE" != "1" ]; then
  echo "已存在配置,保持不变 (想重新生成请加 FORCE=1,旧配置会备份)"
else
  if [ -f "$ENVF" ]; then
    cp -p "$ENVF" "$ENVF.bak.$(date +%s)"
    echo "旧配置已备份"
  fi

  [ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD="$(gen)"
  [ -n "$API_PASSWORD" ]   || API_PASSWORD="$(gen)"
  check_plain ADMIN_PASSWORD "$ADMIN_PASSWORD"
  check_plain API_PASSWORD "$API_PASSWORD"

  ask_secret COOKIE_ARRAY "粘贴 Claude Cookie(按文档格式,输入不回显;直接回车=跳过,稍后在后台添加): "
  ask_secret GEMINI_KEYS  "粘贴 Gemini 密钥(按文档格式,输入不回显;直接回车=跳过): "
  check_array COOKIE_ARRAY "$COOKIE_ARRAY"
  check_array GEMINI_KEYS "$GEMINI_KEYS"

  umask 077
  {
    echo "CLEWDR_IP=$BIND_IP"
    echo "CLEWDR_PORT=$PORT"
    echo "CLEWDR_ADMIN_PASSWORD=$ADMIN_PASSWORD"
    echo "CLEWDR_PASSWORD=$API_PASSWORD"
    echo "CLEWDR_MAX_RETRIES=$MAX_RETRIES"
    echo "CLEWDR_CACHE_RESPONSE=$CACHE_RESPONSE"
    if [ -n "$PROXY" ];        then echo "CLEWDR_PROXY=$PROXY"; fi
    if [ -n "$COOKIE_ARRAY" ]; then echo "CLEWDR_COOKIE_ARRAY='$COOKIE_ARRAY'"; fi
    if [ -n "$GEMINI_KEYS" ];  then echo "CLEWDR_GEMINI_KEYS='$GEMINI_KEYS'"; fi
  } > "$ENVF"
  chmod 600 "$ENVF"
fi

getv() { grep -m1 "^$1=" "$ENVF" | cut -d= -f2- || true; }
CUR_IP="$(getv CLEWDR_IP)"
CUR_PORT="$(getv CLEWDR_PORT)"
HAS_COOKIE="$(getv CLEWDR_COOKIE_ARRAY)"

# ---------- 2. compose 文件 ----------
step "2/4 写入 docker-compose.yml"
cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  clewdr:
    image: ghcr.io/xerxes-2/clewdr:latest
    container_name: clewdr
    hostname: clewdr
    env_file:
      - clewdr.env
    network_mode: host
    restart: unless-stopped
EOF

# ---------- 3. 启动 ----------
step "3/4 拉取镜像并启动"
cd "$DIR"
for i in 1 2 3; do
  if docker compose pull; then break; fi
  [ "$i" -lt 3 ] || die "镜像拉取失败,请检查到 ghcr.io 的网络"
  warn "拉取失败,5 秒后重试 ($i/3)"
  sleep 5
done
docker compose up -d

# ---------- 4. 验证 ----------
step "4/4 等待服务就绪"
CHECK_HOST="$CUR_IP"
if [ "$CHECK_HOST" = "0.0.0.0" ]; then CHECK_HOST="127.0.0.1"; fi

ok=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null -m 2 "http://${CHECK_HOST}:${CUR_PORT}/"; then ok=1; break; fi
  sleep 1
done
if [ "$ok" -ne 1 ]; then
  docker compose logs --tail 40 clewdr || true
  die "40 秒内服务未响应。若日志提示配置解析错误,请编辑 $ENVF 删除 COOKIE/GEMINI 那两行,再执行: cd $DIR && docker compose up -d"
fi

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
IP="${IP:-你的VPS-IP}"
SHOW_HOST="$IP"
if [ "$CUR_IP" != "0.0.0.0" ]; then SHOW_HOST="$CUR_IP"; fi

printf '\n\033[1;32m✔ ClewdR 已启动\033[0m\n'
echo "----------------------------------------------------------"
echo "前端后台:  http://${SHOW_HOST}:${CUR_PORT}"
echo "API 地址:  http://${SHOW_HOST}:${CUR_PORT}  (如 /v1/messages、/v1/chat/completions)"
echo "后台密码:  $(getv CLEWDR_ADMIN_PASSWORD)"
echo "API 密钥:  $(getv CLEWDR_PASSWORD)"
echo "配置文件:  $ENVF (权限 600)"
echo "----------------------------------------------------------"
if [ -z "$HAS_COOKIE" ]; then
  warn "还没有配置 Claude Cookie:请登录后台添加,否则无法提供 Claude 服务"
fi
if [ "$CUR_IP" != "127.0.0.1" ]; then
  warn "服务监听在公网且是明文 HTTP,密码和 Cookie 会明文传输;建议改用 BIND_IP=127.0.0.1 + SSH 隧道,或前置 HTTPS 反向代理"
fi
echo
echo "常用命令:"
echo "  查看日志   cd $DIR && docker compose logs -f"
echo "  重启       cd $DIR && docker compose restart"
echo "  更新镜像   cd $DIR && docker compose pull && docker compose up -d"
echo "  停止删除   cd $DIR && docker compose down"
