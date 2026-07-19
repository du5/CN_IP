#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin:/usr/local/go/bin"
set -Eeuo pipefail

LIST_FILE="CN.txt"
SET_NAME="cn_ipv4_list"
TEMP_SET="${SET_NAME}_new"

ACCEPT_CHAIN="CN_IPV4_ACCEPT"
BLOCK_CHAIN="CN_IPV4_BLOCK"

LOCK_FILE="/run/cn-ipv4-firewall.lock"
PREFIX_FILE=""

log() {
    echo "[$(date '+%F %T')] $*"
}

cleanup() {
    if [[ -n "${PREFIX_FILE:-}" ]]; then
        rm -f "$PREFIX_FILE"
    fi

    ipset destroy "$TEMP_SET" 2>/dev/null || true
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "错误：缺少命令 $1" >&2
        exit 1
    }
}

if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本必须以 root 身份运行" >&2
    exit 1
fi

apt update -y
apt install -yqq ipset iptables wget netfilter-persistent cron mawk
apt autoremove -y gawk

systemctl enable cron --now

require_command ipset
require_command iptables
require_command flock
require_command awk
require_command sort
require_command wget
require_command crontab

exec 9>"$LOCK_FILE"
flock -x 9

log "正在从远端更新 $LIST_FILE ..."
wget -q -O "$LIST_FILE" "http://git.affcm.com/CN_IP/CN.txt" || {
    echo "错误：下载 CN.txt 失败" >&2
    exit 1
}
log "$LIST_FILE 下载完成"

if [[ ! -r "$LIST_FILE" ]]; then
    echo "错误：文件不存在或不可读：$LIST_FILE" >&2
    exit 1
fi

PREFIX_FILE="$(mktemp)"

awk '
{
    sub(/\r$/, "")
}

/^[[:space:]]*$/ {
    next
}

/^[[:space:]]*#/ {
    next
}

{
    if (NF != 1) {
        printf "错误：第 %d 行格式不正确，每行只能有一个 IP/CIDR：%s\n", NR, $0 > "/dev/stderr"
        exit 1
    }

    print $1
}
' "$LIST_FILE" | sort -u > "$PREFIX_FILE"

ENTRY_COUNT="$(wc -l < "$PREFIX_FILE")"

if [[ "$ENTRY_COUNT" -eq 0 ]]; then
    echo "错误：$LIST_FILE 中没有有效 IP/CIDR，拒绝替换现有列表" >&2
    exit 1
fi

if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset create "$SET_NAME" hash:net \
        family inet \
        hashsize 16384 \
        maxelem 65536
else
    CURRENT_TYPE="$(ipset list "$SET_NAME" | awk '/^Type:/ {print $2; exit}')"

    if [[ "$CURRENT_TYPE" != "hash:net" ]]; then
        echo "错误：现有集合 $SET_NAME 类型是 $CURRENT_TYPE，不是 hash:net" >&2
        exit 1
    fi
fi

ipset destroy "$TEMP_SET" 2>/dev/null || true

ipset create "$TEMP_SET" hash:net \
    family inet \
    hashsize 16384 \
    maxelem 65536

awk -v set="$TEMP_SET" '{
    print "add " set " " $1
}' "$PREFIX_FILE" | ipset restore

IMPORTED_COUNT="$(
    ipset list "$TEMP_SET" |
    awk '/^Number of entries:/ {print $4; exit}'
)"

if [[ -z "$IMPORTED_COUNT" || "$IMPORTED_COUNT" -ne "$ENTRY_COUNT" ]]; then
    echo "错误：导入数量不一致，文件=$ENTRY_COUNT，ipset=$IMPORTED_COUNT" >&2
    exit 1
fi

ipset swap "$TEMP_SET" "$SET_NAME"
ipset destroy "$TEMP_SET"

log "已更新 $SET_NAME，共 $IMPORTED_COUNT 条"

iptables -N "$BLOCK_CHAIN" 2>/dev/null || true
iptables -F "$BLOCK_CHAIN"

# 中国 IP 直接丢弃
iptables -A "$BLOCK_CHAIN" \
    -m set \
    --match-set "$SET_NAME" src \
    -j DROP

# 非中国 IP 无条件允许
iptables -A "$BLOCK_CHAIN" -j ACCEPT

# 删除以前脚本加入的模式跳转，避免重复
while iptables -C INPUT -j "$ACCEPT_CHAIN" 2>/dev/null; do
    iptables -D INPUT -j "$ACCEPT_CHAIN"
done

while iptables -C INPUT -j "$BLOCK_CHAIN" 2>/dev/null; do
    iptables -D INPUT -j "$BLOCK_CHAIN"
done

# 放到 INPUT 第一条，避免前面的规则提前 ACCEPT 中国 IP
iptables -I INPUT 1 -j "$BLOCK_CHAIN"

# 按要求设置默认策略
iptables -P INPUT ACCEPT

ipset save > /etc/ipset.conf

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null
elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4
fi

# 写入 crontab，替换两个脚本的旧条目
CRON_ENTRY="0 * * * * /root/CN_IP/block.sh"
CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v '/root/CN_IP/accept\.sh' | grep -v '/root/CN_IP/block\.sh' > "$CRON_TMP" || true
echo "$CRON_ENTRY" >> "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"
log "已写入 crontab：$CRON_ENTRY"

log "已切换至 BLOCK 模式"
log "$SET_NAME 中的来源被拒绝，其他来源无条件允许"

echo
iptables -L INPUT -n -v --line-numbers
echo
iptables -L "$BLOCK_CHAIN" -n -v --line-numbers
