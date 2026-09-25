#!/usr/bin/env bash
#
# check_debian_junk.sh
# 扫描 Debian/Ubuntu VPS 上常见的"垃圾"占用：
#   - apt 缓存、旧内核、孤立依赖包
#   - 日志文件 / systemd journal
#   - 临时文件 / core dump
#   - 大文件 / 大目录 Top N
#   - 旧的 .deb 残留配置包
#   - 用户和 root 的回收站、缓存目录
#
# 本脚本只做检测和列出，不做任何删除操作，
# 每一项后面会给出对应的清理命令供你自行确认执行。
#
# 用法: bash check_debian_junk.sh
#

set -uo pipefail

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m"

section () {
    echo
    echo -e "${CYAN}==================== $1 ====================${NC}"
}

hint () {
    echo -e "${YELLOW}  建议命令: $1${NC}"
}

human_size () {
    # 输入路径，输出 du -sh 结果（不存在则跳过）
    [ -e "$1" ] && du -sh "$1" 2>/dev/null | awk '{print $1}'
}

TOTAL_RECLAIMABLE_NOTE=0

# 0. 磁盘总体情况
section "0. 磁盘总体使用情况"
df -h / 2>/dev/null

# 1. APT 缓存
section "1. APT 下载缓存 (/var/cache/apt/archives)"
apt_cache_size=$(human_size /var/cache/apt/archives)
echo "当前占用: ${apt_cache_size:-0}"
if [ -n "$apt_cache_size" ] && [ "$apt_cache_size" != "0" ]; then
    hint "apt-get clean            # 清空全部缓存"
    hint "apt-get autoclean        # 只清理过时的包，更保守"
fi

# 2. 孤立的依赖包 (autoremove)
section "2. 可自动移除的孤立依赖包"
autoremove_list=$(apt-get -s autoremove 2>/dev/null | grep -E "^Remv" || true)
if [ -n "$autoremove_list" ]; then
    echo "$autoremove_list"
    hint "apt-get autoremove --purge   # 移除孤立包并清除其配置文件"
else
    echo -e "${GREEN}[OK] 无孤立依赖包${NC}"
fi

# 3. 旧内核
section "3. 旧内核 (保留当前内核, 列出其余可删除的)"
current_kernel=$(uname -r)
echo "当前使用内核: $current_kernel"
old_kernels=$(dpkg --list 2>/dev/null | grep -E '^ii  linux-image-[0-9]' \
    | awk '{print $2}' | grep -v "$current_kernel" || true)
if [ -n "$old_kernels" ]; then
    echo "发现旧内核包:"
    echo "$old_kernels"
    hint "apt-get purge <上面列出的包名>   # 确认当前内核可正常启动后再删旧内核"
else
    echo -e "${GREEN}[OK] 未发现多余旧内核${NC}"
fi

# 4. dpkg 状态为 rc (已卸载但配置文件残留) 的包
section "4. 已卸载但配置文件残留的包 (dpkg 状态 rc)"
rc_packages=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
if [ -n "$rc_packages" ]; then
    echo "$rc_packages"
    hint "dpkg -l | awk '/^rc/ {print \$2}' | xargs -r dpkg --purge"
else
    echo -e "${GREEN}[OK] 无残留配置包${NC}"
fi

# 5. systemd journal 日志
section "5. systemd journal 日志占用"
journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | tail -1)
echo "当前占用: ${journal_size:-未知}"
hint "journalctl --vacuum-time=7d   # 只保留最近 7 天日志"
hint "journalctl --vacuum-size=200M # 或按大小限制，二选一即可"

# 6. /var/log 下的大日志文件与已轮转的旧日志
section "6. /var/log 下体积较大或已轮转压缩的旧日志"
find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) 2>/dev/null \
    -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20 | awk -F'\t' '{
        size=$1; path=$2;
        printf "%8.1fK  %s\n", size/1024, path
    }'
big_logs=$(find /var/log -type f -size +50M 2>/dev/null)
if [ -n "$big_logs" ]; then
    echo
    echo -e "${YELLOW}[注意] 以下未轮转日志单个文件超过 50M，建议检查是否需要 logrotate 或手动清空:${NC}"
    echo "$big_logs" | xargs -r ls -lh 2>/dev/null | awk '{print $5"\t"$NF}'
fi
hint "find /var/log -name '*.gz' -o -name '*.old' | xargs -r rm -f   # 确认无需保留后清理压缩旧日志"

# 7. /tmp 和 /var/tmp
section "7. /tmp 与 /var/tmp 临时文件"
tmp_size=$(human_size /tmp)
var_tmp_size=$(human_size /var/tmp)
echo "/tmp 占用: ${tmp_size:-0}"
echo "/var/tmp 占用: ${var_tmp_size:-0}"
old_tmp_files=$(find /tmp /var/tmp -mtime +7 -type f 2>/dev/null | wc -l)
echo "其中超过 7 天未修改的文件数: $old_tmp_files"
if [ "$old_tmp_files" -gt 0 ]; then
    hint "find /tmp /var/tmp -mtime +7 -type f -delete   # 谨慎: 确认没有服务依赖这些临时文件"
fi

# 8. core dump 文件
section "8. Core dump 文件"
core_files=$(find / -xdev -not -path "/proc/*" -not -path "/sys/*" \
    -type f \( -name "core" -o -name "core.[0-9]*" \) -size +1M 2>/dev/null)
if [ -n "$core_files" ]; then
    echo "$core_files" | xargs -r ls -lh 2>/dev/null | awk '{print $5"\t"$NF}'
    hint "把上面列出的路径逐个 rm 掉即可（先确认不是刚好在排查的崩溃现场）"
else
    echo -e "${GREEN}[OK] 未发现明显的 core dump 文件${NC}"
fi

# 9. 已知的第三方一键脚本残留 (docker/snap 等未使用组件)
section "9. 未使用但常驻占用空间的组件"
if ! command -v docker >/dev/null 2>&1 && [ -d /var/lib/docker ]; then
    echo -e "${YELLOW}[注意] 未检测到 docker 命令，但 /var/lib/docker 仍存在:${NC} $(human_size /var/lib/docker)"
    hint "确认不再需要 docker 数据后: rm -rf /var/lib/docker"
fi
if command -v snap >/dev/null 2>&1; then
    disabled_snaps=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    if [ -n "$disabled_snaps" ]; then
        echo "发现已禁用的旧版本 snap 包:"
        echo "$disabled_snaps"
        hint "snap list --all | awk '/disabled/{print \$1, \$3}' 后用 snap remove <name> --revision=<rev>"
    fi
fi

# 10. 用户 / root 的常见缓存目录
section "10. 常见缓存目录 (root 与各用户)"
for home in /root /home/*; do
    [ -d "$home" ] || continue
    for c in ".cache" ".npm" ".cargo/registry" ".composer/cache" ".m2/repository"; do
        p="$home/$c"
        [ -d "$p" ] || continue
        sz=$(human_size "$p")
        [ -n "$sz" ] && echo "$p  ->  $sz"
    done
done

# 11. 根目录下体积最大的 20 个目录（辅助人工判断，非全自动垃圾判定）
section "11. 磁盘占用 Top 20 目录 (辅助人工排查, 排除 /proc /sys)"
du -x -h --max-depth=4 / 2>/dev/null \
    | grep -Ev '^\S+\s+/(proc|sys)($|/)' \
    | sort -rh | head -20

# 12. 已卸载软件遗留的 systemd 单元 (LOAD 状态为 not-found)
section "12. 已损坏/悬空的 systemd 单元 (not-found)"
broken_units=$(systemctl list-units --all 2>/dev/null | grep -i "not-found")
if [ -n "$broken_units" ]; then
    echo "$broken_units"
    hint "systemctl list-unit-files 确认后用 systemctl disable <unit> 清理引用"
else
    echo -e "${GREEN}[OK] 未发现悬空 systemd 单元${NC}"
fi

echo
section "扫描完成"
echo "以上仅为检测结果和清理建议，脚本未执行任何删除操作。"
echo "请根据业务实际情况逐项确认后再手动执行对应命令，尤其是内核、docker 数据、日志等敏感项。"
