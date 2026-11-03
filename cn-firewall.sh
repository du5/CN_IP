#!/bin/bash
#
# cn-firewall.sh —— 基于中国 IPv4 列表的 ipset + iptables 入站防火墙
#
# 用法：
#   cn-firewall.sh setup    安装依赖并配置开机持久化（每台机器只需执行一次）
#   cn-firewall.sh accept   仅允许中国来源新建入站连接，其余丢弃（INPUT 默认 DROP）
#   cn-firewall.sh block    丢弃中国来源，其余放行（INPUT 默认 ACCEPT）
#
# 环境变量：
#   SSH_PORTS   accept 模式下无条件放行的 TCP 端口，空格分隔。
#               默认从 sshd -T 自动读取，读取失败则为 22。
#   LIST_URL    CN.txt 下载地址。
#
# accept/block 执行成功后会写入每小时一次的 crontab 任务，之后自动更新列表。
# 列表未变化且防火墙已处于目标模式时，脚本会直接退出，不做任何修改。

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

LIST_URL="${LIST_URL:-https://git.affcm.com/CN_IP/CN.txt}"
LIST_FILE="$SCRIPT_DIR/CN.txt"

SET_NAME="cn_ipv4_list"
TEMP_SET="${SET_NAME}_new"
ACCEPT_CHAIN="CN_IPV4_ACCEPT"
BLOCK_CHAIN="CN_IPV4_BLOCK"

LOCK_FILE="/run/cn-ipv4-firewall.lock"
LOG_FILE="/var/log/cn-firewall.log"
IPSET_PLUGIN="/usr/share/netfilter-persistent/plugins.d/10-ipset"
IPSET_SAVE_FILE="/etc/iptables/ipsets"

MODE="${1:-}"
CHANGED=0
TMP_FILES=()

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    echo "错误：$*" >&2
    exit 1
}

usage() {
    sed -n '3,/^$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
    exit 1
}

cleanup() {
    rm -f ${TMP_FILES[@]+"${TMP_FILES[@]}"}
    # 尚未 swap 的临时集合
    ipset destroy "$TEMP_SET" 2>/dev/null || true
}
trap cleanup EXIT

require_root() {
    [[ $EUID -eq 0 ]] || die "此脚本必须以 root 身份运行"
}

require_commands() {
    local c
    for c in ipset iptables wget sha256sum flock awk sort crontab netfilter-persistent; do
        command -v "$c" >/dev/null 2>&1 || die "缺少命令 ${c}，请先执行：$SCRIPT_PATH setup"
    done
    [[ -x "$IPSET_PLUGIN" ]] || die "未安装 ipset-persistent，重启后 ipset 不会恢复，请先执行：$SCRIPT_PATH setup"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

cmd_setup() {
    require_root
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -yqq ipset iptables wget ca-certificates cron \
        netfilter-persistent ipset-persistent

    [[ -x "$IPSET_PLUGIN" ]] || die "ipset-persistent 安装后仍未找到 $IPSET_PLUGIN"

    systemctl enable --now cron
    systemctl enable netfilter-persistent

    log "依赖安装完成。ipset 将保存到 ${IPSET_SAVE_FILE}，由 netfilter-persistent 在开机时先于 iptables 恢复。"
    log "下一步执行：$SCRIPT_PATH accept  或  $SCRIPT_PATH block"
}

# ---------------------------------------------------------------------------
# 列表下载与校验
# ---------------------------------------------------------------------------

download_list() {
    log "正在下载 $LIST_URL ..."
    wget -q --timeout=30 --tries=3 -O "$NEW_LIST" "$LIST_URL" || die "下载 $LIST_URL 失败"
}

# 从原始列表提取有效行到 PREFIX_FILE：
# - 去掉 CR、空行、# 注释
# - 每行只能有一个 IP 或 CIDR
# - 去重
normalize_list() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        NF != 1 {
            printf "错误：第 %d 行格式不正确，每行只能有一个 IP/CIDR：%s\n", NR, $0 > "/dev/stderr"
            exit 1
        }
        { print $1 }
    ' "$NEW_LIST" | sort -u > "$PREFIX_FILE"

    ENTRY_COUNT="$(wc -l < "$PREFIX_FILE" | tr -d ' ')"
    (( ENTRY_COUNT > 0 )) || die "列表中没有有效 IP/CIDR，拒绝替换现有集合"
}

list_unchanged() {
    [[ -f "$LIST_FILE" ]] || return 1
    [[ "$(sha256sum < "$NEW_LIST")" == "$(sha256sum < "$LIST_FILE")" ]]
}

# ---------------------------------------------------------------------------
# ipset
# ---------------------------------------------------------------------------

set_exists() {
    ipset list -t "$SET_NAME" >/dev/null 2>&1
}

# ipset list -t 只输出头部（Type、Number of entries 等），不打印成员，
# 对上万条的集合比完整 list 快得多。
set_header() {
    ipset list -t "$1" | awk -v key="$2" '$0 ~ "^" key ":" { print $NF; exit }'
}

rebuild_set() {
    local maxelem imported
    maxelem=$(( ENTRY_COUNT * 2 > 65536 ? ENTRY_COUNT * 2 : 65536 ))

    if set_exists; then
        local t
        t="$(set_header "$SET_NAME" Type)"
        [[ "$t" == "hash:net" ]] || die "现有集合 $SET_NAME 类型是 ${t}，不是 hash:net"
    else
        ipset create "$SET_NAME" hash:net family inet hashsize 16384 maxelem "$maxelem"
    fi

    ipset destroy "$TEMP_SET" 2>/dev/null || true
    ipset create "$TEMP_SET" hash:net family inet hashsize 16384 maxelem "$maxelem"

    # 任何无效 IP/CIDR 都会让 ipset restore 失败，脚本随之退出
    awk -v set="$TEMP_SET" '{ print "add " set " " $1 }' "$PREFIX_FILE" | ipset restore

    imported="$(set_header "$TEMP_SET" "Number of entries")"
    [[ "$imported" =~ ^[0-9]+$ && "$imported" -eq "$ENTRY_COUNT" ]] \
        || die "导入数量不一致，文件=${ENTRY_COUNT}，ipset=$imported"

    # 原子替换，正在被 iptables 引用的 SET_NAME 不会消失
    ipset swap "$TEMP_SET" "$SET_NAME"
    ipset destroy "$TEMP_SET"
    CHANGED=1
    log "已更新集合 ${SET_NAME}，共 $imported 条"
}

# ---------------------------------------------------------------------------
# iptables 链
# ---------------------------------------------------------------------------

# 链已存在、规则条数一致且每条规则都能 -C 匹配时返回 0。
# 满足时跳过重建，避免 -F 到重新 -A 之间链为空的窗口。
chain_is_complete() {
    local chain="$1" count rule
    shift
    iptables -S "$chain" >/dev/null 2>&1 || return 1
    count="$(iptables -S "$chain" | grep -c '^-A ')" || true
    (( count == $# )) || return 1
    for rule in "$@"; do
        # shellcheck disable=SC2086
        iptables -C "$chain" $rule 2>/dev/null || return 1
    done
}

ensure_chain() {
    local chain="$1" rule
    shift
    if chain_is_complete "$chain" "$@"; then
        return
    fi
    iptables -N "$chain" 2>/dev/null || true
    iptables -F "$chain"
    for rule in "$@"; do
        # shellcheck disable=SC2086
        iptables -A "$chain" $rule
    done
    CHANGED=1
    log "已重建链 $chain"
}

# 输出 INPUT 中跳转到指定链的规则序号，每行一个
jump_positions() {
    iptables -L INPUT -n --line-numbers | awk -v c="$1" '$2 == c { print $1 }'
}

jump_is_first() {
    [[ "$(jump_positions "$1" | head -n 1)" == "1" ]]
}

# 先把本模式的跳转插到 INPUT 第一条，再从后往前删除重复项和另一模式的跳转，
# 保证切换过程中始终有一条生效的跳转。
ensure_jump() {
    local own="$1" other="$2" n
    if ! jump_is_first "$own"; then
        iptables -I INPUT 1 -j "$own"
        CHANGED=1
        log "已将 $own 置于 INPUT 第一条"
    fi
    for n in $({ jump_positions "$own" | awk '$1 != 1'; jump_positions "$other"; } | sort -rn); do
        iptables -D INPUT "$n"
        CHANGED=1
    done
    # 另一模式的链已无引用，顺手删除
    if iptables -S "$other" >/dev/null 2>&1; then
        iptables -F "$other" && iptables -X "$other" || true
        CHANGED=1
    fi
}

policy_is() {
    [[ "$(iptables -S INPUT | awk '$1 == "-P" { print $3; exit }')" == "$1" ]]
}

ensure_policy() {
    if ! policy_is "$1"; then
        iptables -P INPUT "$1"
        CHANGED=1
        log "INPUT 默认策略已设为 $1"
    fi
}

# ---------------------------------------------------------------------------
# 持久化与 cron
# ---------------------------------------------------------------------------

persist() {
    # ipset-persistent 的 10-ipset 插件把集合保存到 /etc/iptables/ipsets，
    # 开机时在 15-ip4tables 之前恢复，iptables 规则引用的集合因此已存在。
    netfilter-persistent save >/dev/null
    if ! grep -q "^create $SET_NAME " "$IPSET_SAVE_FILE" 2>/dev/null; then
        log "警告：netfilter-persistent 未写入 ${SET_NAME}，改为手动保存到 $IPSET_SAVE_FILE"
        ipset save > "$IPSET_SAVE_FILE"
    fi
    log "已保存 ipset 与 iptables 规则"
}

ensure_cron() {
    local entry current
    entry="0 * * * * $SCRIPT_PATH $MODE >> $LOG_FILE 2>&1"
    current="$(crontab -l 2>/dev/null || true)"
    if grep -Fxq "$entry" <<<"$current"; then
        return
    fi
    # 替换旧版 accept.sh / block.sh 以及本脚本的旧条目
    {
        awk '!/\/(accept|block|cn-firewall)\.sh( |$)/ && NF' <<<"$current"
        echo "$entry"
    } | crontab -
    log "已写入 crontab：$entry"
}

# ---------------------------------------------------------------------------
# accept / block
# ---------------------------------------------------------------------------

detect_ssh_ports() {
    if [[ -n "${SSH_PORTS:-}" ]]; then
        echo "$SSH_PORTS"
        return
    fi
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | tr '\n' ' ')" || true
        ports="${ports% }"
    fi
    echo "${ports:-22}"
}

cmd_apply() {
    require_root
    require_commands

    exec 9>"$LOCK_FILE"
    flock -x 9

    local own other policy port
    local -a rules
    case "$MODE" in
        accept)
            own="$ACCEPT_CHAIN" other="$BLOCK_CHAIN" policy="DROP"
            rules=(
                "-i lo -j ACCEPT"
                "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
            )
            for port in $(detect_ssh_ports); do
                rules+=("-p tcp --dport $port -j ACCEPT")
            done
            rules+=(
                "-m set --match-set $SET_NAME src -j ACCEPT"
                "-j DROP"
            )
            ;;
        block)
            own="$BLOCK_CHAIN" other="$ACCEPT_CHAIN" policy="ACCEPT"
            rules=(
                "-m set --match-set $SET_NAME src -j DROP"
                "-j ACCEPT"
            )
            ;;
    esac

    NEW_LIST="$(mktemp)"
    PREFIX_FILE="$(mktemp)"
    TMP_FILES+=("$NEW_LIST" "$PREFIX_FILE")

    download_list
    normalize_list
    ensure_cron

    if list_unchanged && set_exists && chain_is_complete "$own" "${rules[@]}" \
        && jump_is_first "$own" && policy_is "$policy"; then
        log "列表未变化（$ENTRY_COUNT 条），已处于 $MODE 模式，无需更新"
        exit 0
    fi

    if ! list_unchanged || ! set_exists; then
        rebuild_set
    fi

    # 顺序很重要：先建链、再挂跳转、最后改默认策略，
    # accept 模式下 SSH 与中国来源的放行规则在策略变为 DROP 前已经生效。
    ensure_chain "$own" "${rules[@]}"
    ensure_jump "$own" "$other"
    ensure_policy "$policy"

    if (( CHANGED )); then
        persist
    fi

    cp "$NEW_LIST" "$LIST_FILE"

    case "$MODE" in
        accept)
            log "已切换至 ACCEPT 模式：仅 $SET_NAME 中的来源和 TCP 端口 $(detect_ssh_ports) 可以新建入站连接"
            ;;
        block)
            log "已切换至 BLOCK 模式：$SET_NAME 中的来源被拒绝，其他来源无条件允许"
            ;;
    esac

    echo
    iptables -L INPUT -n -v --line-numbers
    echo
    iptables -L "$own" -n -v --line-numbers
}

case "$MODE" in
    setup)        cmd_setup ;;
    accept|block) cmd_apply ;;
    *)            usage ;;
esac
