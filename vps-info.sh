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

sep "已安装软件包 / 卸载参考"
if has dpkg; then
  echo "已安装 deb 包总数: $(dpkg -l 2>/dev/null | grep -c '^ii')"
  echo; echo "--- 手动安装的包 (apt-mark showmanual，排除系统自带) ---"
  apt-mark showmanual 2>/dev/null | sort
  echo; echo "--- 占用磁盘最大的 20 个已安装包 ---"
  dpkg-query -Wf '${Installed-Size}\t${Package}\n' 2>/dev/null | sort -rn | head -n 20 | awk '{printf "%.1fMB\t%s\n", $1/1024, $2}'
  echo; echo "--- 残留配置的包 (已卸载但配置文件还在, dpkg状态rc) ---"
  dpkg -l 2>/dev/null | awk '/^rc/ {print $2}'
  echo; echo "--- 最近 apt 安装/卸载记录 (最后20条) ---"
  [ -f /var/log/apt/history.log ] && grep -E "^(Start-Date|Commandline)" /var/log/apt/history.log 2>/dev/null | tail -n 20
fi
has snap && { echo; echo "--- snap 包列表 ---"; snap list 2>/dev/null; }
has pip3 && { echo; echo "--- pip3 全局安装的包 ---"; pip3 list --format=freeze 2>/dev/null | grep -v "^$"; }
has npm && { echo; echo "--- npm 全局安装的包 ---"; npm list -g --depth=0 2>/dev/null; }

sep "Docker 详细占用与可清理项"
if has docker; then
  echo "--- docker system df -v (逐项体积明细) ---"
  docker system df -v 2>/dev/null
  echo; echo "--- 悬空(dangling)镜像 ---"
  docker images -f dangling=true 2>/dev/null
  echo; echo "--- 已停止的容器 ---"
  docker ps -a -f status=exited 2>/dev/null
  echo; echo "--- 未被容器使用的数据卷 ---"
  docker volume ls -f dangling=true 2>/dev/null
  echo; echo "--- 未被使用的自定义网络 ---"
  docker network ls --filter type=custom 2>/dev/null
fi

sep "目录磁盘占用 Top（辅助定位卸载后残留大文件）"
du -sh /opt/* /usr/local/* /srv/* /var/lib/docker/volumes/* 2>/dev/null | sort -rh | head -n 15

sep "非常规方式安装的软件排查（非apt/非docker）"
echo "--- /usr/local/bin 和 /usr/local/sbin 下的自定义程序 ---"
ls -la /usr/local/bin /usr/local/sbin 2>/dev/null | grep -v '^total\|^d'
echo; echo "--- ~/.local/bin (用户级安装) ---"
ls -la ~/.local/bin 2>/dev/null | grep -v '^total\|^d'
echo; echo "--- 最近30天内新增/修改的可执行文件 (常见于 curl|bash 一键安装脚本) ---"
find /usr/bin /usr/local/bin /usr/local/sbin /opt /root -maxdepth 3 -type f -mtime -30 2>/dev/null | grep -v -E '^/usr/bin/(python|perl)' | head -n 30
echo; echo "--- 其他语言/生态的包管理器 ---"
for c in cargo go gem pipx flatpak yarn pnpm composer; do
  has "$c" && echo "检测到: $c ($($c --version 2>&1 | head -n1))"
done
has flatpak && { echo "--- flatpak 已安装应用 ---"; flatpak list 2>/dev/null; }
has go && [ -d "$HOME/go/bin" ] && { echo "--- go install 安装的程序 ---"; ls "$HOME/go/bin" 2>/dev/null; }
has gem && { echo "--- gem 全局安装 ---"; gem list --local 2>/dev/null | head -n 20; }

sep "自定义/非标准开机启动与后台任务"
[ -f /etc/rc.local ] && { echo "--- /etc/rc.local ---"; cat /etc/rc.local; }
echo; echo "--- /etc/systemd/system 下自定义 service/timer（非系统默认路径）---"
ls -la /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null
echo; echo "--- systemd timer 列表（定时任务的另一种形式，比cron更常被脚本使用）---"
has systemctl && systemctl list-timers --all 2>/dev/null | head -n 20
echo; echo "--- 所有用户的 crontab ---"
for u in $(cut -f1 -d: /etc/passwd); do
  ct=$(crontab -l -u "$u" 2>/dev/null)
  [ -n "$ct" ] && { echo "用户 $u:"; echo "$ct"; }
done
echo; echo "--- /etc/cron.daily /weekly /monthly 里的自定义脚本 ---"
ls -la /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null | grep -v '^total\|^d'

sep "异常权限文件排查（安全相关，可选关注）"
echo "--- SUID/SGID 可执行文件（非系统标准路径下的，更值得留意）---"
find /usr/local /opt /root /home -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null

sep "监听端口对应的完整进程路径"
if has ss; then
  for pid in $(ss -tulnp 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u); do
    path=$(readlink -f /proc/"$pid"/exe 2>/dev/null)
    [ -n "$path" ] && echo "PID $pid -> $path"
  done
fi

sep "系统健康状态排查"
echo "--- 是否有失败的 systemd 服务 ---"
systemctl --failed 2>/dev/null
echo; echo "--- 是否需要重启 ---"
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || echo "无需重启"
echo; echo "--- journal 日志磁盘占用 ---"
journalctl --disk-usage 2>/dev/null
echo; echo "--- 最近 20 条 error 级别及以上日志 ---"
journalctl -p err -b --no-pager 2>/dev/null | tail -n 20

sep "网络连接与路由（辅助判断是否有异常外连）"
echo "--- 路由表 ---"
ip route 2>/dev/null
echo; echo "--- /etc/hosts ---"
cat /etc/hosts 2>/dev/null
echo; echo "--- 已建立的出站/入站连接（按远程地址） ---"
if has ss; then ss -tnp state established 2>/dev/null; fi

sep "软件源与密钥（第三方源排查，安全相关）"
echo "--- apt 软件源列表 ---"
[ -f /etc/apt/sources.list ] && cat /etc/apt/sources.list
ls /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | while read -r f; do
  echo "--- $f ---"; cat "$f" 2>/dev/null
done
echo; echo "--- 第三方 apt GPG 公钥 ---"
ls -la /etc/apt/trusted.gpg.d/ 2>/dev/null | grep -v '^total\|^d'
ls -la /etc/apt/keyrings/ 2>/dev/null | grep -v '^total\|^d'

sep "证书与其他常驻服务痕迹"
[ -d /etc/letsencrypt/live ] && { echo "--- Let's Encrypt 证书 ---"; ls /etc/letsencrypt/live 2>/dev/null; }
has acme.sh && echo "检测到 acme.sh"
[ -d "$HOME/.acme.sh" ] && echo "发现 ~/.acme.sh 目录（可能用acme.sh管理证书）"
echo; echo "--- 磁盘上找到的 docker-compose 文件（非docker容器方式部署的项目痕迹）---"
find / -xdev -maxdepth 5 \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null

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
