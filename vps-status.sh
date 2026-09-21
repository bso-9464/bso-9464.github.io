#!/usr/bin/env bash
# VPS 运行状态检测脚本(只读,不修改任何东西)
# 针对: Debian 13 / KVM / 1 vCPU / 2GB 内存 / 20GB 磁盘 + Docker + ClewdR
# 用法:  bash vps-status.sh
# 可选变量: SAMPLE=10 (采样秒数,默认5)  CNAME=clewdr (容器名)  PORT=8484 (服务端口)
export LC_ALL=C
set +e

SAMPLE="${SAMPLE:-5}"
CNAME="${CNAME:-clewdr}"
PORT="${PORT:-8484}"

if [ -t 1 ]; then
  CR=$'\033[1;31m'; CY=$'\033[1;33m'; CG=$'\033[1;32m'; CC=$'\033[1;36m'; CN=$'\033[0m'
else
  CR=; CY=; CG=; CC=; CN=
fi

has() { command -v "$1" >/dev/null 2>&1; }
T=""; has timeout && T="timeout 15"

OK=0; WARN=0; CRIT=0
WARNS=(); CRITS=(); SAT=(); TIPS=()

sec() { printf '\n%s===== %s =====%s\n' "$CC" "$1" "$CN"; }
rep() { # 级别(ok|warn|crit|info) 名称 详情
  local tag
  case "$1" in
    ok)   OK=$((OK+1));     tag="${CG}[ 正常 ]${CN}" ;;
    warn) WARN=$((WARN+1)); tag="${CY}[ 警告 ]${CN}"; WARNS+=("$2: $3") ;;
    crit) CRIT=$((CRIT+1)); tag="${CR}[ 严重 ]${CN}"; CRITS+=("$2: $3") ;;
    *)    tag="[ 信息 ]" ;;
  esac
  printf '%s %s: %s\n' "$tag" "$2" "$3"
}
ge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
lvl() { if ge "$1" "$3"; then echo crit; elif ge "$1" "$2"; then echo warn; else echo ok; fi; }
dur() { local s=${1:-0}; printf '%d天%02d时%02d分' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }
tip() { TIPS+=("$1"); }

printf '%sVPS 运行状态检测%s  %s\n' "$CC" "$CN" "$(date '+%F %T %Z')"
echo "系统: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")  内核: $(uname -r)  已运行: $(uptime -p 2>/dev/null)"
CORES="$(nproc 2>/dev/null || echo 1)"

# ---------- 采样开始 ----------
echo "采样 ${SAMPLE} 秒中,请稍候..."
ROOTSRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOTDEV="$(basename "$(readlink -f "$ROOTSRC" 2>/dev/null)" 2>/dev/null)"
DISK="$(lsblk -no pkname "/dev/$ROOTDEV" 2>/dev/null | head -1)"
[ -n "$DISK" ] || DISK="$ROOTDEV"
IFACE="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"

cpu_read()  { awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat; }
swap_read() { awk '/^pswpin/{a=$2} /^pswpout/{b=$2} END{print a+0,b+0}' /proc/vmstat; }
io_read()   { awk -v d="$DISK" '$3==d{print $13}' /proc/diskstats; }
net_read()  { sed 's/:/ /' /proc/net/dev 2>/dev/null | awk -v i="$IFACE" '$1==i{print $2,$10}'; }

t1=$(date +%s.%N)
C1="$(cpu_read)"; S1="$(swap_read)"; IO1="$(io_read)"; N1="$(net_read)"
sleep "$SAMPLE"
C2="$(cpu_read)"; S2="$(swap_read)"; IO2="$(io_read)"; N2="$(net_read)"
t2=$(date +%s.%N)
EL="$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.3f", b-a}')"

# shellcheck disable=SC2086
read -r CPU_USE CPU_IOW CPU_STL < <(awk 'BEGIN{
  for(i=1;i<=8;i++){a[i]=ARGV[i]; b[i]=ARGV[i+8]}
  t1=0; t2=0; for(i=1;i<=8;i++){t1+=a[i]; t2+=b[i]}
  dt=t2-t1; if(dt<=0){print "0 0 0"; exit}
  idle=(b[4]+b[5])-(a[4]+a[5])
  printf "%.1f %.1f %.1f", 100*(dt-idle)/dt, 100*(b[5]-a[5])/dt, 100*(b[8]-a[8])/dt
}' $C1 $C2)

# ---------- 1. CPU ----------
sec "1. CPU (${CORES} 核)"
read -r L1 L5 L15 _ < /proc/loadavg
LR5="$(awk -v l="$L5" -v c="$CORES" 'BEGIN{printf "%.2f", l/c}')"
echo "负载 1/5/15 分钟: $L1 / $L5 / $L15   (每核: 5分钟 ${LR5})"
rep "$(lvl "$CPU_USE" 70 90)" "CPU 使用率" "${CPU_USE}% (采样 ${SAMPLE}s)"
ge "$CPU_USE" 90 && SAT+=("CPU 使用率 ${CPU_USE}%")
rep "$(lvl "$LR5" 0.8 1.5)" "系统负载" "5分钟平均每核 ${LR5} (1.0 = 刚好跑满,>1 说明有进程在排队)"
ge "$LR5" 1.5 && SAT+=("CPU 排队 (每核负载 ${LR5})")
rep "$(lvl "$CPU_IOW" 20 40)" "IO 等待" "${CPU_IOW}%"
ge "$CPU_IOW" 20 && tip "IO 等待偏高:磁盘可能是瓶颈,检查是否有大量读写(日志、镜像拉取、swap)"
rep "$(lvl "$CPU_STL" 5 15)" "CPU 被偷取" "${CPU_STL}% (KVM 宿主机超售/邻居抢占,不是你的进程造成的)"
ge "$CPU_STL" 5 && tip "CPU steal 偏高:宿主机资源紧张,持续偏高可考虑联系商家或换机器"
if [ -r /proc/pressure/cpu ]; then
  PC="$(awk '$1=="some"{split($2,a,"=");split($3,b,"=");print a[2],b[2]}' /proc/pressure/cpu)"
  read -r PC10 PC60 <<<"$PC"
  rep "$(lvl "$PC10" 40 70)" "CPU 压力(PSI)" "近10秒 ${PC10}% / 近60秒 ${PC60}% 的时间有任务在等 CPU"
  ge "$PC10" 70 && SAT+=("CPU 压力 PSI ${PC10}%")
fi
echo "--- CPU 占用 Top 5 ---"
$T top -bn2 -d1 -w 200 2>/dev/null | awk '/^top -/{n++} n==2' | sed -n '7,12p'
ge "$CPU_USE" 70 && tip "CPU 偏高:看上面 Top 进程,是容器就用 docker stats 定位"

# ---------- 2. 内存 ----------
sec "2. 内存 / Swap"
read -r MT MA SWT SWF < <(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} /^SwapTotal/{st=$2} /^SwapFree/{sf=$2} END{print t+0,a+0,st+0,sf+0}' /proc/meminfo)
MEM_USED="$(awk -v t="$MT" -v a="$MA" 'BEGIN{printf "%.1f", 100*(t-a)/t}')"
MEM_TXT="$(awk -v t="$MT" -v a="$MA" 'BEGIN{printf "已用 %.0fMB / 共 %.0fMB,可用 %.0fMB", (t-a)/1024, t/1024, a/1024}')"
rep "$(lvl "$MEM_USED" 85 93)" "内存" "${MEM_USED}% ($MEM_TXT)"
ge "$MEM_USED" 93 && SAT+=("内存 ${MEM_USED}%")
ge "$MEM_USED" 85 && tip "内存吃紧:用 docker stats / ps 找大户,或考虑增加 swap、限制容器内存"
if [ "$SWT" -gt 0 ]; then
  SW_USED="$(awk -v t="$SWT" -v f="$SWF" 'BEGIN{printf "%.1f", 100*(t-f)/t}')"
  SW_TXT="$(awk -v t="$SWT" -v f="$SWF" 'BEGIN{printf "%.0fMB / %.0fMB", (t-f)/1024, t/1024}')"
  rep "$(lvl "$SW_USED" 50 80)" "Swap 使用" "${SW_USED}% ($SW_TXT)"
  read -r PI1 PO1 <<<"$S1"; read -r PI2 PO2 <<<"$S2"
  SWR="$(awk -v a="$PI1" -v b="$PO1" -v c="$PI2" -v d="$PO2" -v e="$EL" 'BEGIN{printf "%.0f", ((c-a)+(d-b))/e}')"
  rep "$(lvl "$SWR" 100 1000)" "Swap 换页" "${SWR} 页/秒 (持续偏高=内存不够,系统在抖动)"
  ge "$SWR" 1000 && SAT+=("内存抖动 (swap ${SWR} 页/秒)")
else
  rep info "Swap" "未配置"
fi
if [ -r /proc/pressure/memory ]; then
  read -r PM10 PM60 <<<"$(awk '$1=="some"{split($2,a,"=");split($3,b,"=");print a[2],b[2]}' /proc/pressure/memory)"
  rep "$(lvl "$PM10" 10 30)" "内存压力(PSI)" "近10秒 ${PM10}% / 近60秒 ${PM60}%"
fi
echo "--- 内存占用 Top 5 ---"
ps -eo pid,comm,%mem,rss --sort=-rss 2>/dev/null | head -6 | awk 'NR==1{print "  PID COMMAND %MEM RSS";next}{printf "  %s %s %s%% %.0fMB\n",$1,$2,$3,$4/1024}'

# ---------- 3. 磁盘 ----------
sec "3. 磁盘"
read -r DSIZE DUSED DAVAIL DPCT < <(df -Ph / 2>/dev/null | awk 'NR==2{print $2,$3,$4,$5}')
DPCT="${DPCT%\%}"
rep "$(lvl "${DPCT:-0}" 80 90)" "根分区空间" "${DPCT}% (已用 ${DUSED} / ${DSIZE},剩余 ${DAVAIL})"
ge "${DPCT:-0}" 80 && tip "磁盘空间偏紧:docker system df 查看占用,docker system prune 清理无用镜像(先确认再执行)"
IPCT="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
rep "$(lvl "${IPCT:-0}" 80 90)" "inode" "${IPCT}%"
if [ -n "$IO1" ] && [ -n "$IO2" ]; then
  IOU="$(awk -v a="$IO1" -v b="$IO2" -v e="$EL" 'BEGIN{v=(b-a)/(e*10); if(v>100)v=100; if(v<0)v=0; printf "%.1f", v}')"
  rep "$(lvl "$IOU" 70 90)" "磁盘忙碌度" "${IOU}% (设备 ${DISK})"
  ge "$IOU" 90 && SAT+=("磁盘 IO ${IOU}%")
fi
if [ -r /proc/pressure/io ]; then
  read -r PI10 PI60 <<<"$(awk '$1=="some"{split($2,a,"=");split($3,b,"=");print a[2],b[2]}' /proc/pressure/io)"
  rep "$(lvl "$PI10" 20 50)" "IO 压力(PSI)" "近10秒 ${PI10}% / 近60秒 ${PI60}%"
fi

# ---------- 4. 网络 ----------
sec "4. 网络"
if [ -n "$IFACE" ] && [ -n "$N1" ] && [ -n "$N2" ]; then
  read -r RX1 TX1 <<<"$N1"; read -r RX2 TX2 <<<"$N2"
  NET_TXT="$(awk -v a="$RX1" -v b="$TX1" -v c="$RX2" -v d="$TX2" -v e="$EL" 'BEGIN{printf "下行 %.1f KB/s  上行 %.1f KB/s", (c-a)/e/1024, (d-b)/e/1024}')"
  rep info "网卡 ${IFACE}" "$NET_TXT"
fi
TCPSUM="$(ss -s 2>/dev/null | awk '/^TCP:/{print}')"
[ -n "$TCPSUM" ] && echo "$TCPSUM"
if has ping; then
  PING="$($T ping -c 4 -W 2 1.1.1.1 2>&1)"
  LOSS="$(awk -F', ' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){split($i,a,"%"); print a[1]}}' <<<"$PING")"
  RTT="$(awk -F'/' '/^rtt|^round-trip/{print $5}' <<<"$PING")"
  if [ -n "$LOSS" ]; then
    rep "$(lvl "$LOSS" 1 20)" "出网连通性" "到 1.1.1.1 丢包 ${LOSS}%,平均延迟 ${RTT:-?} ms"
  else
    rep warn "出网连通性" "ping 1.1.1.1 无结果"
  fi
else
  rep info "出网连通性" "未安装 ping,跳过"
fi

# ---------- 5. Docker / ClewdR ----------
sec "5. Docker / ${CNAME}"
if ! has docker; then
  rep info "Docker" "未安装"
elif ! $T docker info >/dev/null 2>&1; then
  rep crit "Docker" "守护进程无响应 (systemctl status docker)"
else
  rep ok "Docker 守护进程" "运行正常 ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  echo "--- 全部容器 ---"
  docker ps -a --format '  {{.Names}} | {{.Status}} | {{.Image}}' 2>/dev/null
  if docker inspect "$CNAME" >/dev/null 2>&1; then
    IFS='|' read -r CST RC OOM STARTED EXITC < <(docker inspect -f '{{.State.Status}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.StartedAt}}|{{.State.ExitCode}}' "$CNAME" 2>/dev/null)
    if [ "$CST" = "running" ]; then
      UPS=$(( $(date +%s) - $(date -d "$STARTED" +%s 2>/dev/null || echo "$(date +%s)") ))
      rep ok "${CNAME} 状态" "运行中,已连续运行 $(dur "$UPS")"
    else
      rep crit "${CNAME} 状态" "${CST} (退出码 ${EXITC}),查看: docker logs --tail 50 ${CNAME}"
    fi
    if [ "${RC:-0}" -ge 5 ]; then
      rep crit "${CNAME} 重启次数" "${RC} 次,可能在反复崩溃"
      tip "容器反复重启:docker logs --tail 100 ${CNAME} 看报错原因"
    elif [ "${RC:-0}" -gt 0 ]; then
      rep warn "${CNAME} 重启次数" "${RC} 次"
    else
      rep ok "${CNAME} 重启次数" "0 次"
    fi
    [ "$OOM" = "true" ] && { rep crit "${CNAME} 内存" "曾被 OOM 杀死"; tip "容器被 OOM 杀死:内存不足,考虑加 swap 或减少其他占用"; }

    if [ "$CST" = "running" ]; then
      HR="$($T curl -s -o /dev/null -m 6 -w '%{http_code} %{time_total}' "http://127.0.0.1:${PORT}/" 2>/dev/null)"
      CODE="${HR%% *}"; TT="${HR##* }"
      if [ -z "$CODE" ] || [ "$CODE" = "000" ]; then
        rep crit "服务响应" "127.0.0.1:${PORT} 无响应 (容器在运行但服务不通)"
      else
        MS="$(awk -v t="$TT" 'BEGIN{printf "%.0f", t*1000}')"
        rep "$(lvl "$TT" 1 3)" "服务响应" "HTTP ${CODE},耗时 ${MS} ms"
      fi
      CONN="$(ss -tnH state established "( sport = :${PORT} )" 2>/dev/null | wc -l)"
      rep info "端口 ${PORT} 连接数" "${CONN} 个已建立连接"
    fi
  else
    rep info "${CNAME}" "容器不存在 (可用 CNAME=xxx 指定其他容器名)"
  fi
  echo "--- 容器资源占用 ---"
  $T docker stats --no-stream --format '  {{.Name}}: CPU {{.CPUPerc}} | 内存 {{.MemUsage}} ({{.MemPerc}})' 2>/dev/null
  BIGLOG="$(find /var/lib/docker/containers -name '*-json.log' -size +50M 2>/dev/null | wc -l)"
  if [ "$BIGLOG" -gt 0 ]; then
    rep warn "容器日志" "${BIGLOG} 个日志文件超过 50MB"
    tip "容器日志过大:在 /etc/docker/daemon.json 配置 log-opts max-size 后重启 docker,并重建容器"
  else
    rep ok "容器日志" "没有超过 50MB 的日志文件"
  fi
fi

# ---------- 6. 系统健康 ----------
sec "6. 系统健康"
if has systemctl; then
  FAILED="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  if [ -n "$FAILED" ]; then
    rep warn "systemd 失败单元" "$(echo "$FAILED" | tr '\n' ' ')"
  else
    rep ok "systemd 失败单元" "无"
  fi
fi
if has journalctl; then
  OOMN="$($T journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'out of memory\|oom-kill')"
  if [ "${OOMN:-0}" -gt 0 ]; then
    rep crit "24小时内 OOM" "内核杀过进程 ${OOMN} 次"
    tip "发生过 OOM:内存不足,运行 journalctl -k | grep -i oom 查看被杀的进程"
  else
    rep ok "24小时内 OOM" "无"
  fi
  BRUTE="$($T journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -c 'Failed password\|Invalid user')"
  if [ "${BRUTE:-0}" -ge 200 ]; then
    rep warn "SSH 被爆破" "24小时内 ${BRUTE} 次失败登录"
    tip "SSH 被大量爆破:建议改用密钥登录并禁用密码登录,或安装 fail2ban"
  else
    rep ok "SSH 失败登录" "24小时内 ${BRUTE:-0} 次"
  fi
fi
if has timedatectl; then
  SYNC="$(timedatectl 2>/dev/null | awk -F': ' '/System clock synchronized/{print $2}')"
  if [ "$SYNC" = "yes" ]; then rep ok "时间同步" "正常"
  elif [ "$SYNC" = "no" ]; then rep warn "时间同步" "未同步"; fi
fi

# ---------- 综合结论 ----------
sec "综合结论"
if [ "${#SAT[@]}" -gt 0 ]; then
  printf '是否满负载: %s是%s  -> %s\n' "$CR" "$CN" "$(IFS='; '; echo "${SAT[*]}")"
else
  printf '是否满负载: %s否%s  (CPU %s%%, 内存 %s%%, 磁盘 %s%%)\n' "$CG" "$CN" "$CPU_USE" "$MEM_USED" "$DPCT"
fi
printf '检查项: %s正常 %d%s / %s警告 %d%s / %s严重 %d%s\n' "$CG" "$OK" "$CN" "$CY" "$WARN" "$CN" "$CR" "$CRIT" "$CN"
if [ "$CRIT" -gt 0 ]; then
  printf '%s结论: 存在严重问题,需要处理%s\n' "$CR" "$CN"
  for x in "${CRITS[@]}"; do echo "  严重 - $x"; done
elif [ "$WARN" -gt 0 ]; then
  printf '%s结论: 基本可用,但有需要留意的警告%s\n' "$CY" "$CN"
else
  printf '%s结论: 运行良好,资源充裕%s\n' "$CG" "$CN"
fi
for x in "${WARNS[@]}"; do echo "  警告 - $x"; done
if [ "${#TIPS[@]}" -gt 0 ]; then
  echo "建议:"
  printf '  - %s\n' "${TIPS[@]}"
fi
echo
echo "提示: 单次采样只反映此刻。想看趋势,可隔几分钟再跑几次,或加大 SAMPLE=30。"
