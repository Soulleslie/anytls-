#!/usr/bin/env bash
# AnyTLS 节点管理脚本：Debian/Ubuntu + sing-box + Let's Encrypt。
# 安装：wget -O /root/anytls-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/install.sh && chmod +x /root/anytls-setup.sh && /root/anytls-setup.sh
# 用法：anytls [命令]，命令列表见 anytls help。
set -Eeuo pipefail
umask 077

SCRIPT_VERSION='2.1.2'
SCRIPT_URL='https://raw.githubusercontent.com/Soulleslie/anytls-/main/install.sh'
DOMAIN=''
PORT=''
NODE_NAME=''
RELEASE_API='https://api.github.com/repos/SagerNet/sing-box/releases'
RELEASE_VERSION=''
RELEASE_URL=''
RELEASE_SHA256=''
CONFIG='/etc/sing-box/config.json'
MARKER='/etc/sing-box/.anytls-setup-owned'
ACME_DIR='/var/lib/sing-box/acme'
SURGE_FILE='/root/anytls-surge.txt'
MANAGER='/root/anytls-setup.sh'
UNINSTALLER='/root/anytls-uninstall.sh'
SHORTCUT='/usr/local/bin/anytls'
SHORTCUT_TAG='# anytls-setup shortcut'
TFO_SYSCTL='/etc/sysctl.d/99-anytls-tfo.conf'
TFO_TAG='# anytls-setup: TCP Fast Open'
TEMP_DIR=''
TLS_OUTPUT=''
LATEST_VERSION=''
REMOTE_SCRIPT_VERSION=''
MARKER_DOMAIN=''
MARKER_PORT=''
MARKER_NAME=''
MARKER_MODE='domain'
MARKER_IP=''
ADDR_MODE='domain'
ADDR_IP=''
INSTALL_STARTED=0
INSTALL_COMMITTED=0
MANAGER_COPIED=0

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    GREEN=$'\033[32m' RED=$'\033[31m' YELLOW=$'\033[33m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

say() { printf '%s\n' "$*"; }
ok() { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$RESET"; }
step() { printf '%s%s%s\n' "$BOLD" "$*" "$RESET"; }
fail() { printf '%s错误：%s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || fail '请以 root 身份运行（可先执行 sudo -i）。'; }
need_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

valid_domain() {
    (( ${#1} <= 253 )) || return 1
    [[ "$1" == *.* && "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}
# 合法节点端口：1–65535 且不是 80（80 留给 ACME HTTP-01）。
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 && 10#$1 != 80 ))
}
# 节点名称会写进 Surge 节点行，不能含逗号、等号或换行。
valid_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *','* && "$1" != *'='* && "$1" != *$'\n'* ]]
}
port_free() {
    local listeners
    listeners="$(ss -H -ltn "sport = :$1")" || fail "无法检查本机 TCP ${1}。"
    [[ -z "$listeners" ]]
}
# 在 20000–60000 之间随机挑一个本机未占用的端口。
random_port() {
    local attempt n p
    for ((attempt = 0; attempt < 50; attempt++)); do
        n="$(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]')"
        p=$((20000 + n % 40001))
        if ! command -v ss >/dev/null 2>&1 || port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}
gen_password() {
    local pw
    pw="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ ${#pw} -eq 48 ]] || fail '随机密码生成失败。'
    printf '%s' "$pw"
}
# 读取安装记录：第 1 行域名，第 2 行端口，第 3 行节点名，
# 第 4 行节点行地址模式（domain/ip，旧记录没有时视为 domain），第 5 行 IP 模式下的 IP。
read_marker() {
    local lines=()
    mapfile -t lines < "$MARKER" 2>/dev/null || true
    MARKER_DOMAIN="${lines[0]:-}"
    MARKER_PORT="${lines[1]:-}"
    MARKER_NAME="${lines[2]:-}"
    MARKER_MODE="${lines[3]:-domain}"
    MARKER_IP="${lines[4]:-}"
    if [[ "$MARKER_MODE" != ip || ! "$MARKER_IP" =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]]; then
        MARKER_MODE=domain
        MARKER_IP=''
    fi
}
# 参数：域名 端口 节点名 [地址模式] [IP]；省略的地址字段沿用当前值。
write_marker() {
    printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${4:-$ADDR_MODE}" "${5-$ADDR_IP}" > "$MARKER" \
        && chmod 600 "$MARKER"
}
config_password() {
    jq -er '[.inbounds[] | select(.type == "anytls") | .users[0].password][0] | select(type == "string")' "$CONFIG" 2>/dev/null
}
# 用 jq 修改配置并原子替换，保留 root:sing-box 640 权限；失败时原文件不变。
edit_config() {
    local tmp
    tmp="$(mktemp /etc/sing-box/.config.json.XXXXXX)" || return 1
    if jq "$@" "$CONFIG" > "$tmp" && chown root:sing-box "$tmp" && chmod 640 "$tmp" \
        && mv -f -- "$tmp" "$CONFIG"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}
# 本机 TLS 握手并校验证书链与域名；握手输出保存在 TLS_OUTPUT，供读取证书到期时间。
tls_ok() {
    TLS_OUTPUT="$(timeout 6 openssl s_client \
        -connect "127.0.0.1:${PORT}" \
        -servername "$DOMAIN" \
        -verify_hostname "$DOMAIN" \
        -verify_return_error </dev/null 2>&1 || true)"
    [[ "$TLS_OUTPUT" == *'Verify return code: 0 (ok)'* ]]
}
# 等待服务运行且本机 TLS 验证通过；参数为最多尝试次数（每次间隔 2 秒）。
wait_tls() {
    local attempt
    for ((attempt = 1; attempt <= $1; attempt++)); do
        if systemctl is-active --quiet sing-box && tls_ok; then return 0; fi
        sleep 2
    done
    return 1
}
# 依次尝试多个查询源获取本机公网 IPv4。
public_ipv4() {
    local url ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip="$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        if [[ "$ip" =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}
# 询问 y/n；第二个参数是直接回车时的默认值（y 或 n，默认 n）。
confirm() {
    local answer default="${2:-n}"
    while true; do
        read -r -p "$1" answer || return 1
        [[ -n "$answer" ]] || answer="$default"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) warn '请输入 y 或 n。' ;;
        esac
    done
}
# TCP Fast Open 需要两处同时开启：sing-box 入站的 tcp_fast_open，以及内核 net.ipv4.tcp_fastopen 的服务端位（2）。
config_tfo_enabled() {
    [[ "$(jq -r '[.inbounds[] | select(.type == "anytls") | .tcp_fast_open][0] // false' "$CONFIG" 2>/dev/null)" == true ]]
}
kernel_tfo_value() {
    local v
    v="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}
kernel_tfo_server() {
    (( $(kernel_tfo_value) & 2 ))
}
tfo_active() {
    config_tfo_enabled && kernel_tfo_server
}
tfo_sysctl_is_ours() {
    [[ -f "$TFO_SYSCTL" ]] && grep -qF -- "$TFO_TAG" "$TFO_SYSCTL" 2>/dev/null
}
# 开启内核服务端 TFO 并持久化；原值记在 sysctl 文件里，关闭或卸载时恢复。
enable_kernel_tfo() {
    local orig current new
    current="$(kernel_tfo_value)"
    orig="$current"
    if tfo_sysctl_is_ours; then
        orig="$(sed -n 's/^# original=\([0-9]*\)$/\1/p' "$TFO_SYSCTL" | head -n 1)"
        [[ "$orig" =~ ^[0-9]+$ ]] || orig="$current"
    elif [[ -e "$TFO_SYSCTL" ]]; then
        warn "$TFO_SYSCTL 已存在且不是本脚本创建的，未修改。" >&2
        return 1
    fi
    new=$(( current | 3 ))
    printf '%s\n# original=%s\nnet.ipv4.tcp_fastopen = %s\n' "$TFO_TAG" "$orig" "$new" > "$TFO_SYSCTL" || return 1
    chmod 644 "$TFO_SYSCTL" || return 1
    sysctl -q -w "net.ipv4.tcp_fastopen=$new" >/dev/null
}
# 删除本脚本的 sysctl 文件，并把内核参数恢复成开启前的值。
disable_kernel_tfo() {
    local orig
    tfo_sysctl_is_ours || return 0
    orig="$(sed -n 's/^# original=\([0-9]*\)$/\1/p' "$TFO_SYSCTL" | head -n 1)"
    rm -f -- "$TFO_SYSCTL"
    if [[ "$orig" =~ ^[0-9]+$ ]]; then
        sysctl -q -w "net.ipv4.tcp_fastopen=$orig" >/dev/null 2>&1 || true
    fi
}

format_duration() {
    local s="$1"
    if (( s >= 86400 )); then
        printf '%d 天 %d 小时' $((s / 86400)) $((s % 86400 / 3600))
    elif (( s >= 3600 )); then
        printf '%d 小时 %d 分钟' $((s / 3600)) $((s % 3600 / 60))
    else
        printf '%d 分钟' $((s / 60))
    fi
}

ensure_dependencies() {
    need_command apt-get
    local command_name packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v ss >/dev/null 2>&1 || packages+=(iproute2)
    command -v runuser >/dev/null 2>&1 || packages+=(util-linux)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
        packages+=(ca-certificates)
    fi
    if (( ${#packages[@]} )); then
        say "安装缺失的基础工具：${packages[*]}"
        apt-get update
        apt-get install -y "${packages[@]}"
    fi
    for command_name in curl dpkg dpkg-deb dpkg-query getent ss awk sort od tr systemctl openssl timeout runuser sha256sum jq; do
        need_command "$command_name"
    done
}

cleanup_temp() {
    if [[ -n "$TEMP_DIR" ]]; then rm -rf -- "$TEMP_DIR" || true; fi
}

fetch_release_metadata() {
    local selector="$1" arch="$2" api_url release_file tag release_id asset_name
    local page assets_file asset_json asset_count url digest
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] || fail '临时目录未准备好。'
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || fail "不支持的架构：$arch"
    if [[ "$selector" == latest ]]; then
        api_url="$RELEASE_API/latest"
    elif [[ "$selector" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        api_url="$RELEASE_API/tags/$selector"
    else
        fail "无效的版本：$selector"
    fi

    release_file="$TEMP_DIR/release.json"
    curl -fLsS --retry 3 --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' -o "$release_file" "$api_url" \
        || fail '无法查询 sing-box 官方 GitHub 发布信息。'
    tag="$(jq -er '.tag_name | select(type == "string")' "$release_file")" \
        || fail '官方发布信息缺少版本号。'
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "官方版本号格式异常：$tag"
    if [[ "$selector" != latest && "$tag" != "$selector" ]]; then
        fail "官方发布版本与请求版本不符：$tag"
    fi
    [[ "$(jq -r '[.draft, .prerelease] | join(",")' "$release_file")" == 'false,false' ]] \
        || fail '查询到的不是正式稳定版。'
    release_id="$(jq -er '.id | select(type == "number")' "$release_file")" \
        || fail '官方发布信息缺少 release ID。'
    RELEASE_VERSION="${tag#v}"
    asset_name="sing-box_${RELEASE_VERSION}_linux_${arch}.deb"
    RELEASE_URL=''
    RELEASE_SHA256=''

    # release 对象通常已包含全部 assets：先直接查找，省去分页请求（未认证 API 限额 60 次/小时）。
    asset_json="$(jq -c --arg name "$asset_name" \
        '[(.assets // [])[] | select(.name == $name)] | if length == 1 then .[0] else null end' "$release_file")" \
        || fail '无法读取安装包信息。'
    page=1
    while [[ "$asset_json" == null ]] && (( page <= 5 )); do
        assets_file="$TEMP_DIR/assets.json"
        curl -fLsS --retry 3 --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -o "$assets_file" \
            "$RELEASE_API/$release_id/assets?per_page=100&page=$page" \
            || fail '无法读取 sing-box 官方发布文件列表。'
        asset_count="$(jq -er 'if type == "array" then length else error("invalid assets") end' "$assets_file")" \
            || fail '官方发布文件列表格式异常。'
        asset_json="$(jq -c --arg name "$asset_name" \
            '[.[] | select(.name == $name)] | if length == 1 then .[0] else null end' "$assets_file")" \
            || fail '无法读取安装包信息。'
        (( asset_count == 100 )) || break
        page=$((page + 1))
    done
    [[ "$asset_json" != null ]] || fail "官方稳定版 $tag 没有找到 ${asset_name}。"

    url="$(jq -er '.browser_download_url | select(type == "string")' <<< "$asset_json")" \
        || fail '官方安装包缺少下载地址。'
    digest="$(jq -er '.digest | select(type == "string")' <<< "$asset_json")" \
        || fail '官方安装包缺少 SHA-256。'
    [[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/$tag/$asset_name" ]] \
        || fail '官方安装包下载地址格式异常。'
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail '官方安装包 SHA-256 格式异常。'
    RELEASE_URL="$url"
    RELEASE_SHA256="${digest#sha256:}"
}

download_verified_package() {
    local target="$1"
    [[ -n "$RELEASE_URL" && -n "$RELEASE_SHA256" ]] || fail '安装包信息尚未准备好。'
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$target" "$RELEASE_URL" \
        || fail '下载安装包失败。'
    printf '%s  %s\n' "$RELEASE_SHA256" "$target" | sha256sum --check --status \
        || fail '安装包 SHA-256 与官方发布信息不一致，已停止。'
}

installed_version() {
    if [[ "$(dpkg-query -W -f='${Status}' sing-box 2>/dev/null || true)" == 'install ok installed' ]]; then
        dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true
    fi
}
# 查询官方最新稳定版版本号；查询失败时输出为空，不会中断脚本。
query_latest_version() {
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null)" || return 0
    (
        TEMP_DIR="$(mktemp -d)"
        trap 'rm -rf -- "$TEMP_DIR"' EXIT
        fetch_release_metadata latest "$arch" >/dev/null 2>&1
        printf '%s' "$RELEASE_VERSION"
    ) 2>/dev/null || true
}

save_manager() {
    local source_file="${BASH_SOURCE[0]}"
    [[ -f "$source_file" && "$source_file" != /dev/fd/* && "$source_file" != /proc/*/fd/* ]] \
        || fail '请先将脚本下载为普通文件再运行，例如 /root/anytls-setup.sh；不支持 curl | bash。'
    if [[ ! "$source_file" -ef "$MANAGER" ]]; then
        [[ ! -e "$MANAGER" ]] || fail "$MANAGER 已存在；请直接使用该文件，或先检查后手动替换。"
        install -m 700 -- "$source_file" "$MANAGER"
        MANAGER_COPIED=1
    fi
}

shortcut_is_ours() {
    [[ -f "$SHORTCUT" ]] && grep -qF -- "$SHORTCUT_TAG" "$SHORTCUT" 2>/dev/null
}
# 创建快捷命令 anytls；参数 quiet 表示不显示提示。路径被其他程序占用时不覆盖。
ensure_shortcut() {
    local quiet="${1:-}"
    [[ -f "$MANAGER" ]] || return 1
    if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
        shortcut_is_ours && return 0
        [[ -n "$quiet" ]] || warn "$SHORTCUT 已被其他程序占用，未创建快捷命令；请继续使用 bash ${MANAGER}。"
        return 1
    fi
    [[ -d /usr/local/bin ]] || return 1
    printf '#!/usr/bin/env bash\n%s\nexec bash %s "$@"\n' "$SHORTCUT_TAG" "$MANAGER" > "$SHORTCUT" || return 1
    chmod 755 "$SHORTCUT" || return 1
    [[ -n "$quiet" ]] || ok "已创建快捷命令 anytls（等同于 bash ${MANAGER}）。"
}
# 提示里使用的命令名：有快捷命令时用 anytls，否则用完整路径。
cmd_name() {
    if shortcut_is_ours; then printf 'anytls'; else printf 'bash %s' "$MANAGER"; fi
}

# 删除节点在系统中的全部文件。安装时已确认这些路径原本不存在，因此可以整体删除。
purge_node_files() {
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    apt-get purge -y sing-box >/dev/null 2>&1 || warn '软件包卸载失败，请运行 dpkg-query -W sing-box 检查。' >&2
    systemctl daemon-reload >/dev/null 2>&1 || true
    disable_kernel_tfo
    rm -rf -- /etc/sing-box /var/lib/sing-box
    if getent passwd sing-box >/dev/null 2>&1; then userdel sing-box >/dev/null 2>&1 || true; fi
    if getent group sing-box >/dev/null 2>&1; then groupdel sing-box >/dev/null 2>&1 || true; fi
    rm -f -- "$SURGE_FILE" "$UNINSTALLER"
}

finish_install() {
    local result=$?
    trap - EXIT
    if (( INSTALL_COMMITTED == 0 )); then
        if (( INSTALL_STARTED )); then
            if [[ -t 1 ]]; then printf '\n'; fi
            warn '安装未完成，正在撤销本次创建的服务和节点文件…' >&2
            purge_node_files
        fi
        if (( MANAGER_COPIED )); then rm -f -- "$MANAGER"; fi
    fi
    if [[ -n "$TEMP_DIR" ]]; then rm -rf -- "$TEMP_DIR"; fi
    return "$result"
}

print_help() {
    local cmd
    cmd="$(cmd_name)"
    cat <<EOF
AnyTLS 节点管理脚本 v${SCRIPT_VERSION}（以 root 身份运行）
用法：${cmd} [命令]
  （不带命令）        打开中文管理菜单
  install             安装节点；按提示输入域名、端口和节点名称
  status              查看服务、证书剩余天数和 sing-box 版本
  show                显示 Surge 节点行（含密码）
  password            生成新密码；需更新 Surge 节点行
  port [新端口]       修改节点端口；需先放行新端口并更新 Surge
  domain [新域名]     更换证书域名；检查 DNS 并签发新证书后更新 Surge
  rename [新名称]     修改节点名称；需更新 Surge 节点行
  addr [ip|domain]    节点行服务器地址改用 IP 或域名；需更新 Surge 节点行
  tfo [on|off]        开关 TCP Fast Open；需更新 Surge 节点行
  start|stop|restart  启动、停止、重启服务
  log [-f|行数]       查看运行日志；-f 为实时查看
  version             查看 sing-box 已安装版本和官方最新稳定版
  update              升级 sing-box
  self-update         更新本管理脚本
  uninstall           卸载节点并清理残留
  0–15                直接执行菜单中对应序号的操作
EOF
}

load_metadata() {
    [[ -f "$MARKER" && -f "$CONFIG" ]] || fail '未发现本脚本安装的节点。'
    command -v jq >/dev/null 2>&1 || fail '缺少 jq，请先运行：apt-get update && apt-get install -y jq'
    read_marker
    DOMAIN="$MARKER_DOMAIN"
    PORT="$MARKER_PORT"
    NODE_NAME="$MARKER_NAME"
    ADDR_MODE="$MARKER_MODE"
    ADDR_IP="$MARKER_IP"
    if [[ -z "$DOMAIN" || -z "$PORT" ]]; then
        DOMAIN="$(jq -r '.certificate_providers[0].domain[0] // empty' "$CONFIG" 2>/dev/null || true)"
        PORT="$(jq -r '[.inbounds[] | select(.type == "anytls") | .listen_port][0] // empty' "$CONFIG" 2>/dev/null || true)"
    fi
    [[ -n "$DOMAIN" && "$PORT" =~ ^[0-9]+$ ]] || fail '安装记录不完整。'
    [[ -n "$NODE_NAME" ]] || NODE_NAME="AnyTLS-$(hostname -s)"
}

show_node() {
    need_root
    load_metadata
    local password line tfo=false server="$DOMAIN"
    password="$(config_password)" || fail '无法从配置读取密码。'
    # 只有服务端真正开启 TFO 时才写 tfo=true。
    if tfo_active; then tfo=true; fi
    # IP 模式下服务器地址用 IP，sni 始终是证书域名。
    if [[ "$ADDR_MODE" == ip && -n "$ADDR_IP" ]]; then server="$ADDR_IP"; fi
    printf -v line '%s = anytls, %s, %s, password=%s, skip-cert-verify=false, tfo=%s, sni=%s' \
        "$NODE_NAME" "$server" "$PORT" "$password" "$tfo" "$DOMAIN"
    printf '%s\n' "$line" > "$SURGE_FILE"
    chmod 600 "$SURGE_FILE"
    printf '%s\n' "$line"
}

menu_show() {
    say '复制下面整行到 Surge 配置文件的 [Proxy] 段：'
    say
    printf '%s' "$BOLD"
    show_node
    printf '%s' "$RESET"
    say
    warn '此行包含密码，请勿公开分享。'
}

check_install_eligibility() {
    if [[ -f "$MARKER" && -f "$CONFIG" ]]; then
        read_marker
        fail "检测到本脚本已配置节点 ${MARKER_DOMAIN:-未知域名}:${MARKER_PORT:-未知端口}。请运行 $(cmd_name) 打开管理菜单。"
    fi
    [[ ! -e "$MARKER" && ! -L "$MARKER" ]] || fail '检测到已有节点安装记录，但配置不完整；已停止以保护现有文件。'
    if command -v dpkg-query >/dev/null 2>&1 \
        && dpkg-query -W -f='${Status}' sing-box >/dev/null 2>&1; then
        fail '检测到已有 sing-box 软件包记录。请先检查 dpkg-query -W sing-box；本脚本不会覆盖现有安装。'
    fi
    [[ ! -e /etc/sing-box && ! -L /etc/sing-box ]] || fail '/etc/sing-box 已存在，为避免覆盖配置，已停止。'
    [[ ! -e /var/lib/sing-box && ! -L /var/lib/sing-box ]] || fail '/var/lib/sing-box 已存在，为避免覆盖数据，已停止。'
    [[ ! -e "$UNINSTALLER" && ! -L "$UNINSTALLER" ]] || fail "$UNINSTALLER 已存在，为避免覆盖，已停止。"
    [[ ! -e "$SURGE_FILE" && ! -L "$SURGE_FILE" ]] || fail "$SURGE_FILE 已存在，为避免覆盖节点信息，已停止。"
    if command -v sing-box >/dev/null 2>&1; then
        fail '检测到已有 sing-box 程序；本脚本不会覆盖现有安装。'
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl cat sing-box.service >/dev/null 2>&1; then
        fail '检测到已有 sing-box 系统服务；本脚本不会覆盖现有安装。'
    fi
}

install_node() {
    need_root
    [[ -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/*/fd/* ]] \
        || fail '请先将脚本下载为普通文件再运行；不支持 curl | bash。'
    [[ $# -le 3 ]] || fail "用法：$(cmd_name) install [域名] [端口] [节点名称]"
    check_install_eligibility
    local interactive=0 raw_port="${2:-}" default_name answer
    default_name="AnyTLS-$(hostname -s)"

    DOMAIN="${1:-}"
    if [[ -z "$DOMAIN" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定域名。'
        interactive=1
        while true; do
            read -r -p '请输入已解析到这台 VPS 的域名：' DOMAIN || fail '已取消输入。'
            DOMAIN="${DOMAIN,,}"
            if valid_domain "$DOMAIN"; then break; fi
            warn '域名格式不对。只输入域名，例如 sg.example.com，不要带 https:// 或路径。' >&2
        done
    fi
    DOMAIN="${DOMAIN,,}"
    valid_domain "$DOMAIN" || fail '域名格式不对。只输入域名，例如 sg.example.com，不要带 https:// 或路径。'

    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定端口。'
        interactive=1
        while true; do
            read -r -p '请输入节点 TCP 端口（1–65535，不能是 80；直接回车随机生成）：' raw_port \
                || fail '已取消输入。'
            if [[ -z "$raw_port" ]]; then
                if raw_port="$(random_port)"; then
                    say "已随机选择端口：$raw_port"
                    break
                fi
                warn '随机端口生成失败，请手动输入。' >&2
                continue
            fi
            if valid_port "$raw_port"; then
                if ! command -v ss >/dev/null 2>&1 || port_free "$((10#$raw_port))"; then break; fi
                warn "本机 TCP $((10#$raw_port)) 已被占用，请换一个端口。" >&2
                continue
            fi
            warn '端口无效，请输入 1–65535 的数字；TCP 80 留给证书验证。' >&2
        done
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    (( 10#$raw_port != 80 )) || fail 'TCP 80 需要留给证书申请，请另选节点端口。'
    valid_port "$raw_port" || fail '端口必须是 1–65535 的数字。'
    PORT="$((10#$raw_port))"

    NODE_NAME="${3:-}"
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="$default_name"
        if (( interactive )); then
            while true; do
                read -r -p "请输入节点名称（直接回车使用 ${default_name}）：" answer || fail '已取消输入。'
                [[ -n "$answer" ]] || break
                if valid_node_name "$answer"; then
                    NODE_NAME="$answer"
                    break
                fi
                warn '节点名称不能超过 64 个字符，也不能包含逗号、等号或换行。' >&2
            done
        fi
    fi
    valid_node_name "$NODE_NAME" || fail '节点名称不能为空、不能超过 64 个字符，也不能包含逗号、等号或换行。'

    local addr_mode=domain addr_ip='' tfo=0
    if (( interactive )); then
        say '节点行的服务器地址：1) 域名（默认）  2) IP（sni 仍为域名）'
        while true; do
            read -r -p '请选择 [1/2]：' answer || fail '已取消输入。'
            case "$answer" in
                ''|1) addr_mode=domain; break ;;
                2) addr_mode=ip; break ;;
                *) warn '请输入 1 或 2。' >&2 ;;
            esac
        done
        if confirm '是否开启 TCP Fast Open？收益很小，部分网络可能丢包 [y/N]：'; then
            tfo=1
        fi
    fi

    if (( interactive )); then
        say
        step '—————————— 确认安装信息 ——————————'
        say "  域名：$DOMAIN"
        say "  端口：TCP $PORT"
        say "  名称：$NODE_NAME"
        if [[ "$addr_mode" == ip ]]; then
            say '  地址：IP（安装时自动填入本机公网 IPv4）'
        else
            say '  地址：域名'
        fi
        if (( tfo )); then say '  TFO： 开启'; else say '  TFO： 关闭'; fi
        warn "  请确认云安全组已放行 TCP 80 和 TCP ${PORT}"
        step '————————————————————————————————'
        if ! confirm '开始安装？[y/N]：'; then
            say '已取消安装。'
            return 0
        fi
    fi

    say
    step '[1/4] 检查系统和安装环境…'
    [[ -r /etc/os-release ]] || fail '无法识别系统。'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || fail '这个脚本仅支持 Debian 和 Ubuntu。'
    need_command dpkg
    need_command dpkg-query
    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        arm64|amd64) ;;
        *) fail "不支持的架构：$arch" ;;
    esac
    check_install_eligibility
    ensure_dependencies

    step '[2/4] 检查域名解析和本机端口…'
    local dns_ips public_ip
    dns_ips="$(getent ahostsv4 "$DOMAIN" | awk '$2 == "STREAM" {print $1}' | sort -u)" \
        || fail "无法解析域名 ${DOMAIN}。"
    [[ -n "$dns_ips" ]] || fail "域名 $DOMAIN 没有 IPv4 A 记录。"
    public_ip="$(public_ipv4)" || fail '无法查到此 VPS 的公网 IPv4。'
    [[ "$dns_ips" == "$public_ip" ]] \
        || fail "域名 $DOMAIN 解析到 ${dns_ips//$'\n'/, }，但这台 VPS 的公网 IPv4 是 ${public_ip}。请修正 A 记录，生效后重试。"
    ok "域名已指向这台 VPS：$public_ip"
    if [[ "$addr_mode" == ip ]]; then addr_ip="$public_ip"; fi
    local check_port
    for check_port in 80 "$PORT"; do
        port_free "$check_port" || fail "本机 TCP $check_port 已被占用。"
    done

    local password
    trap finish_install EXIT
    save_manager
    TEMP_DIR="$(mktemp -d)"
    step '[3/4] 下载并安装 sing-box 官方最新稳定版…'
    fetch_release_metadata latest "$arch"
    say "下载 sing-box $RELEASE_VERSION ($arch)…"
    download_verified_package "$TEMP_DIR/sing-box.deb"
    ok '安装包 SHA-256 校验通过。'
    INSTALL_STARTED=1
    dpkg -i "$TEMP_DIR/sing-box.deb"

    step '[4/4] 配置节点并申请证书…'
    systemctl stop sing-box >/dev/null 2>&1 || true
    install -d -m 755 /etc/sing-box
    ADDR_MODE="$addr_mode"
    ADDR_IP="$addr_ip"
    write_marker "$DOMAIN" "$PORT" "$NODE_NAME" "$addr_mode" "$addr_ip"
    getent passwd sing-box >/dev/null || fail '安装后未发现 sing-box 系统用户。'
    password="$(gen_password)"
    install -d -o sing-box -g sing-box -m 700 "$ACME_DIR"
    cat > "$CONFIG" <<EOF
{
  "log": { "level": "info" },
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "anytls-cert",
      "domain": ["$DOMAIN"],
      "data_directory": "$ACME_DIR",
      "provider": "letsencrypt",
      "disable_tls_alpn_challenge": true
    }
  ],
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [{ "password": "$password" }],
      "tls": {
        "enabled": true,
        "certificate_provider": "anytls-cert"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    chown root:sing-box "$CONFIG"
    chmod 640 "$CONFIG"
    if (( tfo )); then
        edit_config '(.inbounds[] | select(.type == "anytls") | .tcp_fast_open) = true' \
            || fail '写入 TCP Fast Open 配置失败。'
        enable_kernel_tfo || fail '开启内核 TCP Fast Open 失败。'
        ok '已开启 TCP Fast Open。'
    fi
    runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG"
    systemctl enable --now sing-box

    say '等待 Let’s Encrypt 签发证书并验证 TLS（最长约 2 分钟）…'
    local start=$SECONDS deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        if tls_ok; then
            if [[ -t 1 ]]; then printf '\r\033[K'; fi
            cat > "$UNINSTALLER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo '请以 root 身份运行。' >&2; exit 1; }
exec bash $MANAGER uninstall
EOF
            chmod 700 "$UNINSTALLER"
            show_node >/dev/null
            INSTALL_COMMITTED=1
            ok '证书签发成功，TLS 验证通过。'
            ensure_shortcut || true
            print_install_result
            return 0
        fi
        sleep 5
        if [[ -t 1 ]]; then printf '\r  已等待 %d 秒（最长 120 秒）…' $((SECONDS - start)); fi
    done
    if [[ -t 1 ]]; then printf '\n'; fi
    warn '尚未验证到有效证书，本次安装将自动撤销。请检查域名解析及云安全组 TCP 80，再重新运行安装。' >&2
    say '查看签发错误：journalctl -u sing-box -n 60 --no-pager' >&2
    return 1
}

print_install_result() {
    local cmd
    cmd="$(cmd_name)"
    say
    printf '%s%s================ 安装完成 ================%s\n' "$GREEN" "$BOLD" "$RESET"
    say '复制下面这一行到 Surge 配置文件的 [Proxy] 段：'
    say
    printf '%s%s%s\n' "$BOLD" "$(cat -- "$SURGE_FILE")" "$RESET"
    say
    say "（已保存到 ${SURGE_FILE}；此行含密码，请勿外传）"
    printf '%s%s==========================================%s\n' "$GREEN" "$BOLD" "$RESET"
    say '常用命令：'
    printf '  %-30s %s\n' "$cmd" '打开管理菜单' "$cmd show" '再次显示节点行' "$cmd status" '检查节点状态'
    warn '提醒：保持 TCP 80 开放，证书才能自动续期。'
}

status_node() {
    need_root
    load_metadata
    local listeners service_ok=0 port_ok=0 tls_verified=0
    local since since_epoch cert_end end_epoch days color installed latest
    say "节点名称：$NODE_NAME"
    say "服务器：  $DOMAIN:$PORT"
    if [[ "$ADDR_MODE" == ip ]]; then
        local now_ip
        say "节点地址：IP ${ADDR_IP}（sni 为 ${DOMAIN}）"
        now_ip="$(public_ipv4 || true)"
        if [[ -n "$now_ip" && "$now_ip" != "$ADDR_IP" ]]; then
            warn "VPS 公网 IP 已变为 ${now_ip}，Surge 里的节点会连不上；请运行 $(cmd_name) addr ip 更新。"
        fi
    else
        say '节点地址：域名'
    fi
    if tfo_active; then
        say "TCP Fast Open：${GREEN}已开启${RESET}"
    elif config_tfo_enabled || tfo_sysctl_is_ours; then
        warn "TCP Fast Open：设置不完整（sing-box 与内核参数不一致），运行 $(cmd_name) tfo on 修复，或 $(cmd_name) tfo off 关闭。"
    else
        say 'TCP Fast Open：未开启'
    fi
    if systemctl is-active --quiet sing-box; then
        service_ok=1
        since="$(systemctl show sing-box -p ActiveEnterTimestamp --value 2>/dev/null || true)"
        if [[ -n "$since" ]] && since_epoch="$(date -d "$since" +%s 2>/dev/null)"; then
            say "服务状态：${GREEN}运行中${RESET}（已运行 $(format_duration $(( $(date +%s) - since_epoch )))）"
        else
            say "服务状态：${GREEN}运行中${RESET}"
        fi
    else
        say "服务状态：${RED}未运行${RESET}"
    fi
    if listeners="$(ss -H -ltn "sport = :$PORT" 2>/dev/null)"; then
        if [[ -n "$listeners" ]]; then
            say "本机端口：${GREEN}TCP $PORT 已监听${RESET}"
            port_ok=1
        else
            say "本机端口：${RED}TCP $PORT 未监听${RESET}"
        fi
    else
        say '本机端口：无法检查，请运行 ss -lntp 查看。'
    fi
    if tls_ok; then
        tls_verified=1
        say "TLS 证书：${GREEN}验证通过${RESET}"
        cert_end="$(openssl x509 -noout -enddate <<< "$TLS_OUTPUT" 2>/dev/null || true)"
        cert_end="${cert_end#notAfter=}"
        if [[ -n "$cert_end" ]] && end_epoch="$(date -d "$cert_end" +%s 2>/dev/null)"; then
            days=$(( (end_epoch - $(date +%s)) / 86400 ))
            if (( days > 20 )); then color="$GREEN"; elif (( days > 7 )); then color="$YELLOW"; else color="$RED"; fi
            say "证书到期：$(date -d "@$end_epoch" +%F)（${color}还剩 ${days} 天${RESET}）"
            if (( days <= 20 )); then
                warn '证书剩余时间偏少：正常会在到期前约 30 天自动续期，请检查 TCP 80 是否可从外网访问。'
            fi
        elif [[ -n "$cert_end" ]]; then
            say "证书到期：$cert_end"
        fi
    else
        say "TLS 证书：${RED}验证未通过${RESET}"
    fi
    installed="$(installed_version)"
    latest="$(query_latest_version)"
    if [[ -n "$installed" && -n "$latest" ]] && dpkg --compare-versions "$latest" gt "$installed"; then
        say "sing-box：$installed（${YELLOW}可升级到 ${latest}${RESET}，运行 $(cmd_name) update）"
    elif [[ -n "$installed" && -n "$latest" ]]; then
        say "sing-box：$installed（已是最新稳定版）"
    else
        say "sing-box：${installed:-未知}（无法查询官方最新版本）"
    fi
    say '外部连接：请用 Surge 实测；本机检查无法确认云安全组是否放行。'
    say '证书续签：需保持 TCP 80 可从外部访问。'
    if (( service_ok == 0 || port_ok == 0 || tls_verified == 0 )); then
        warn "排查日志：$(cmd_name) log"
    fi
}

version_node() {
    local installed arch
    installed="$(installed_version)"
    say "已安装版本：${installed:-未安装}"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        say '无法检查官方版本：缺少 curl 或 jq；安装节点或运行 update 时会自动补齐。'
        return 0
    fi
    arch="$(dpkg --print-architecture)"
    TEMP_DIR="$(mktemp -d)"
    trap cleanup_temp EXIT
    fetch_release_metadata latest "$arch"
    say "官方最新稳定版：$RELEASE_VERSION"
    if [[ -n "$installed" ]]; then
        if dpkg --compare-versions "$RELEASE_VERSION" gt "$installed"; then
            warn "有新版本。运行 $(cmd_name) update 手动升级。"
        else
            ok '当前已是最新稳定版，或已安装版本更新。'
        fi
    fi
}

update_node() {
    need_root
    load_metadata
    local installed arch new_version old_version verified=0 restored=1 recovery_dir
    installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null)" \
        || fail '无法读取已安装的 sing-box 版本。'
    [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "已安装版本格式不受支持：${installed}。请先检查软件包来源。"
    systemctl is-active --quiet sing-box && tls_ok \
        || fail "升级前服务或 TLS 验证未通过。请先运行 $(cmd_name) status 排查。"
    arch="$(dpkg --print-architecture)"
    ensure_dependencies
    TEMP_DIR="$(mktemp -d)"
    trap cleanup_temp EXIT

    say '查询官方最新稳定版…'
    fetch_release_metadata latest "$arch"
    new_version="$RELEASE_VERSION"
    if ! dpkg --compare-versions "$new_version" gt "$installed"; then
        ok "当前版本 ${installed}；官方最新稳定版 ${new_version}。无需升级。"
        return 0
    fi
    say "准备从 sing-box $installed 升级到 ${new_version}。"
    download_verified_package "$TEMP_DIR/new.deb"
    say '下载并校验当前版本安装包，供升级失败时恢复…'
    fetch_release_metadata "v$installed" "$arch"
    old_version="$RELEASE_VERSION"
    [[ "$old_version" == "$installed" ]] || fail '旧版本发布信息不一致，已停止。'
    download_verified_package "$TEMP_DIR/old.deb"
    cp -a -- "$CONFIG" "$TEMP_DIR/config.backup" \
        || fail '配置备份失败，已停止升级。'
    dpkg-deb -x "$TEMP_DIR/new.deb" "$TEMP_DIR/unpacked" \
        || fail '无法检查新版本安装包，已停止升级。'
    [[ -x "$TEMP_DIR/unpacked/usr/bin/sing-box" ]] \
        || fail '新版本安装包中未找到 sing-box 程序，已停止升级。'
    "$TEMP_DIR/unpacked/usr/bin/sing-box" check -c "$CONFIG" \
        || fail '新版本不接受当前配置，已停止升级，节点保持原样。'

    if dpkg -i "$TEMP_DIR/new.deb" && systemctl daemon-reload \
        && runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" \
        && systemctl restart sing-box && wait_tls 5; then
        verified=1
    fi
    if (( verified )); then
        ok "升级完成：sing-box ${new_version}。节点域名、端口和密码未变。"
        return 0
    fi

    warn '升级或验证失败，正在恢复原版本…' >&2
    cp -a -- "$TEMP_DIR/config.backup" "$CONFIG" || restored=0
    dpkg -i "$TEMP_DIR/old.deb" || restored=0
    systemctl daemon-reload || restored=0
    systemctl restart sing-box || restored=0
    if (( restored )) && systemctl is-active --quiet sing-box && tls_ok; then
        fail "升级失败，已恢复 sing-box ${old_version}；请运行 $(cmd_name) log 查看日志。"
    fi
    recovery_dir="$TEMP_DIR"
    TEMP_DIR=''
    fail "升级失败且未能验证恢复；原版安装包和配置备份保留在 ${recovery_dir}。请检查 systemctl status sing-box。"
}

change_password() {
    need_root
    load_metadata
    local old_password new_password backup
    old_password="$(config_password)" || fail '无法从配置读取密码。'
    [[ "$old_password" =~ ^[0-9a-f]{48}$ ]] || fail '配置中的节点密码格式异常，已停止。'
    new_password="$(gen_password)"
    backup="$(mktemp /etc/sing-box/config.json.backup.XXXXXX)"
    if ! cp -a -- "$CONFIG" "$backup"; then
        rm -f -- "$backup"
        fail '配置备份失败，密码未修改。'
    fi
    if ! edit_config --arg pw "$new_password" \
            '(.inbounds[] | select(.type == "anytls") | .users[0].password) = $pw' \
        || ! runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" \
        || ! systemctl restart sing-box \
        || ! systemctl is-active --quiet sing-box; then
        mv -f -- "$backup" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup}。"
        systemctl restart sing-box || true
        fail '修改或重启失败，已恢复原密码；请检查 systemctl status sing-box。'
    fi
    rm -f -- "$backup" || warn "提醒：旧配置备份清理失败，请检查 ${backup}。" >&2
    ok '密码已更换。将下面这一行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
    warn "节点行也已保存到 ${SURGE_FILE}。请勿把含密码的节点行发到聊天中。"
}

change_port() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) port [新端口]"
    load_metadata
    local old_port="$PORT" raw_port="${1:-}" new_port match_count backup_dir verified=0
    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定新端口。'
        while true; do
            read -r -p "当前端口 ${old_port}；请输入新的 TCP 端口（直接回车随机生成）：" raw_port \
                || fail '已取消输入。'
            if [[ -z "$raw_port" ]]; then
                if raw_port="$(random_port)" && (( raw_port != old_port )); then
                    say "已随机选择端口：$raw_port"
                    break
                fi
                warn '随机端口生成失败，请手动输入。' >&2
                continue
            fi
            if valid_port "$raw_port" && (( 10#$raw_port != old_port )); then
                if port_free "$((10#$raw_port))"; then break; fi
                warn "本机 TCP $((10#$raw_port)) 已被占用，请换一个端口。" >&2
                continue
            fi
            warn "端口无效。请输入 1–65535 的数字，不能是 TCP 80 或当前端口 ${old_port}。" >&2
        done
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    (( 10#$raw_port != 80 )) || fail 'TCP 80 用于证书验证，请另选节点端口。'
    valid_port "$raw_port" || fail '端口必须是 1–65535 的数字。'
    new_port="$((10#$raw_port))"
    (( new_port != old_port )) || fail "新端口与当前端口相同：${old_port}。"
    port_free "$new_port" || fail "本机 TCP $new_port 已被占用。"
    match_count="$(jq --argjson p "$old_port" '[.inbounds[] | select(.type == "anytls" and .listen_port == $p)] | length' "$CONFIG" 2>/dev/null || true)"
    [[ "$match_count" == 1 ]] || fail '配置中的当前端口不唯一或不存在，已停止以避免改错。'
    say "正在切换到 TCP ${new_port}；请确认已在服务商安全组放行该端口。"

    backup_dir="$(mktemp -d /etc/sing-box/.port-backup.XXXXXX)"
    if ! cp -a -- "$CONFIG" "$MARKER" "$backup_dir/"; then
        rm -rf -- "$backup_dir"
        fail '配置备份失败，端口未修改。'
    fi
    if ! edit_config --argjson old "$old_port" --argjson new "$new_port" \
            '(.inbounds[] | select(.type == "anytls" and .listen_port == $old) | .listen_port) = $new' \
        || ! write_marker "$DOMAIN" "$new_port" "$NODE_NAME"; then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        rm -rf -- "$backup_dir"
        fail '修改端口文件失败，已恢复旧配置。'
    fi

    PORT="$new_port"
    if runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" && systemctl restart sing-box \
        && wait_tls 5; then
        verified=1
    fi
    if (( verified == 0 )); then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        PORT="$old_port"
        systemctl restart sing-box || warn '旧配置已恢复，但服务重启失败；请检查 systemctl status sing-box。' >&2
        rm -rf -- "$backup_dir" || warn "提醒：旧配置备份清理失败，请检查 ${backup_dir}。" >&2
        fail "新端口 $new_port 启动或 TLS 验证失败，已恢复旧端口 ${old_port}；请查看 systemctl status sing-box。"
    fi
    rm -rf -- "$backup_dir" || warn "提醒：旧配置备份清理失败，请检查 ${backup_dir}。" >&2
    ok "已从 TCP $old_port 切换到 TCP ${new_port}。请将下面的新节点行替换到 Surge 的 [Proxy] 段："
    show_node
    warn "确认 Surge 可连接后，再关闭云安全组中的旧端口 ${old_port}。TCP 80 仍需保持开放。"
    warn '请勿把含密码的节点行发到聊天中。'
}

change_domain() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) domain [新域名]"
    load_metadata
    local old_domain="$DOMAIN" new_domain="${1:-}" dns_ips public_ip backup_dir new_addr_ip
    if [[ -z "$new_domain" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定新域名。'
        read -r -p "当前域名 ${old_domain}；请输入已指向这台 VPS 的新域名：" new_domain || fail '已取消输入。'
    fi
    new_domain="${new_domain,,}"
    valid_domain "$new_domain" || fail '域名格式不对。只输入域名，例如 sg.example.com，不要带 https:// 或路径。'
    [[ "$new_domain" != "$old_domain" ]] || fail '新域名与当前域名相同。'
    # 只修改本脚本创建的单域名 ACME 提供者，避免误改其他证书配置。
    jq -e --arg old "$old_domain" '
        ([.certificate_providers[]? | select(.tag == "anytls-cert")] | length) == 1 and
        ([.certificate_providers[]? | select(.tag == "anytls-cert" and .type == "acme" and .domain == [$old])] | length) == 1 and
        ([.inbounds[]? | select(.type == "anytls" and .tls.certificate_provider == "anytls-cert")] | length) == 1
    ' "$CONFIG" >/dev/null || fail '当前 ACME 配置与安装记录不一致，已停止以避免改错。'
    systemctl is-active --quiet sing-box || fail 'sing-box 服务未运行；请先恢复服务，再更换域名。'
    need_command curl
    dns_ips="$(getent ahostsv4 "$new_domain" | awk '$2 == "STREAM" {print $1}' | sort -u)" \
        || fail "无法解析域名 ${new_domain}。"
    [[ -n "$dns_ips" ]] || fail "域名 $new_domain 没有 IPv4 A 记录。"
    public_ip="$(public_ipv4)" || fail '无法查到此 VPS 的公网 IPv4。'
    [[ "$dns_ips" == "$public_ip" ]] \
        || fail "域名 $new_domain 解析到 ${dns_ips//$'\n'/, }，但这台 VPS 的公网 IPv4 是 ${public_ip}。请修正 A 记录，生效后重试。"
    new_addr_ip="$ADDR_IP"
    if [[ "$ADDR_MODE" == ip ]]; then new_addr_ip="$public_ip"; fi
    say "新域名 ${new_domain} 已指向这台 VPS；请确认 TCP 80 可从公网访问。"

    backup_dir="$(mktemp -d /etc/sing-box/.domain-backup.XXXXXX)" || fail '无法创建配置备份。'
    if ! cp -a -- "$CONFIG" "$MARKER" "$backup_dir/"; then
        rm -rf -- "$backup_dir"
        fail '配置备份失败，域名未修改。'
    fi
    if ! edit_config --arg old "$old_domain" --arg new "$new_domain" \
            '(.certificate_providers[] | select(.type == "acme" and .tag == "anytls-cert" and .domain == [$old]) | .domain) = [$new]' \
        || ! write_marker "$new_domain" "$PORT" "$NODE_NAME" "$ADDR_MODE" "$new_addr_ip"; then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        rm -rf -- "$backup_dir"
        fail '修改域名文件失败，已恢复旧配置。'
    fi

    DOMAIN="$new_domain"
    say '正在申请新域名证书并验证 TLS（可能需要数分钟）…'
    if ! runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" \
        || ! systemctl restart sing-box || ! wait_tls 60; then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        DOMAIN="$old_domain"
        systemctl restart sing-box || warn '旧配置已恢复，但服务重启失败；请检查 systemctl status sing-box。' >&2
        rm -rf -- "$backup_dir" || warn "旧配置备份清理失败，请检查 ${backup_dir}。" >&2
        fail "新域名 ${new_domain} 的证书签发或 TLS 验证失败，已恢复旧域名 ${old_domain}；请检查 DNS、TCP 80 和 $(cmd_name) log。"
    fi
    rm -rf -- "$backup_dir" || warn "旧配置备份清理失败，请检查 ${backup_dir}。" >&2
    ok "证书已为 ${new_domain} 验证通过；ACME 自动续期域名已从 ${old_domain} 改为 ${new_domain}。"
    say '请将下面的新节点行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
    warn "保持 ${new_domain} 的 A 记录指向本机，并持续开放 TCP 80，以便自动续期。旧域名确认不用后可自行清理 DNS。"
    warn '请勿把含密码的节点行发到聊天中。'
}

rename_node() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) rename [新名称]"
    load_metadata
    local new_name="${1:-}"
    if [[ -z "$new_name" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定新名称。'
        say "当前节点名称：$NODE_NAME"
        while true; do
            read -r -p '请输入新的节点名称：' new_name || fail '已取消输入。'
            if valid_node_name "$new_name" && [[ "$new_name" != "$NODE_NAME" ]]; then break; fi
            warn '名称无效：不能为空、不能与当前名称相同、不能超过 64 个字符，也不能包含逗号、等号或换行。' >&2
        done
    fi
    valid_node_name "$new_name" || fail '节点名称不能为空、不能超过 64 个字符，也不能包含逗号、等号或换行。'
    [[ "$new_name" != "$NODE_NAME" ]] || fail '新名称与当前名称相同。'
    write_marker "$DOMAIN" "$PORT" "$new_name" || fail '写入安装记录失败，名称未修改。'
    ok "节点名称已改为 ${new_name}，服务无需重启。将下面这一行替换到 Surge 配置文件的 [Proxy] 段："
    show_node
}

addr_node() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) addr [ip|domain]"
    load_metadata
    local target="${1:-}" ip dns_ips
    if [[ -z "$target" ]]; then
        if [[ "$ADDR_MODE" == ip ]]; then
            say "当前节点行服务器地址：IP ${ADDR_IP}（sni 为 ${DOMAIN}）"
        else
            say "当前节点行服务器地址：域名 ${DOMAIN}"
        fi
        [[ -t 0 ]] || return 0
        if [[ "$ADDR_MODE" == ip ]]; then
            confirm '是否切换为域名？[y/N]：' || { say '未修改。'; return 0; }
            target=domain
        else
            confirm '是否切换为 IP？[y/N]：' || { say '未修改。'; return 0; }
            target=ip
        fi
    fi
    case "$target" in
        domain)
            if [[ "$ADDR_MODE" == domain ]]; then
                ok '节点行已经使用域名，无需修改。'
                return 0
            fi
            write_marker "$DOMAIN" "$PORT" "$NODE_NAME" domain '' || fail '写入安装记录失败，未修改。'
            ok "节点行服务器地址已改为域名 ${DOMAIN}，服务无需重启。"
            ;;
        ip)
            command -v curl >/dev/null 2>&1 || fail '缺少 curl，无法查询本机公网 IPv4。'
            ip="$(public_ipv4)" || fail '无法查到此 VPS 的公网 IPv4。'
            dns_ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u || true)"
            if [[ "$dns_ips" != "$ip" ]]; then
                warn "注意：域名 $DOMAIN 当前解析到 ${dns_ips:-（无记录）}，与本机公网 IPv4 $ip 不一致；证书续期会失败，请修正 A 记录。"
            fi
            if [[ "$ADDR_MODE" == ip && "$ADDR_IP" == "$ip" ]]; then
                ok "节点行已经使用 IP ${ip}，无需修改。"
                return 0
            fi
            write_marker "$DOMAIN" "$PORT" "$NODE_NAME" ip "$ip" || fail '写入安装记录失败，未修改。'
            ok "节点行服务器地址已改为 IP ${ip}，服务无需重启。"
            warn "VPS 更换 IP 后，需重新运行 $(cmd_name) addr ip 并更新 Surge；域名解析不能删除，证书续期仍需要它。"
            ;;
        *) fail "用法：$(cmd_name) addr [ip|domain]" ;;
    esac
    say '将下面这一行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
}

tfo_node() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) tfo [on|off]"
    load_metadata
    local action="${1:-}" backup changed=1
    if [[ -z "$action" ]]; then
        if tfo_active; then say 'TCP Fast Open：已开启'; else say 'TCP Fast Open：未开启'; fi
        [[ -t 0 ]] || return 0
        if tfo_active; then
            confirm '是否关闭 TCP Fast Open？[y/N]：' || { say '未修改。'; return 0; }
            action=off
        else
            warn 'TFO 只能省掉新建连接时的 1 次往返，收益很小；部分网络会丢弃握手时携带数据的包。'
            confirm '是否开启 TCP Fast Open？[y/N]：' || { say '未修改。'; return 0; }
            action=on
        fi
    fi
    case "$action" in
        on)
            if tfo_active && tfo_sysctl_is_ours; then
                ok 'TCP Fast Open 已开启，无需修改。'
                return 0
            fi
            ;;
        off)
            if ! config_tfo_enabled && ! tfo_sysctl_is_ours; then
                ok 'TCP Fast Open 已关闭，无需修改。'
                return 0
            fi
            ;;
        *) fail "用法：$(cmd_name) tfo [on|off]" ;;
    esac

    backup="$(mktemp /etc/sing-box/config.json.backup.XXXXXX)"
    if ! cp -a -- "$CONFIG" "$backup"; then
        rm -f -- "$backup"
        fail '配置备份失败，未修改。'
    fi
    if [[ "$action" == on ]]; then
        if ! edit_config '(.inbounds[] | select(.type == "anytls") | .tcp_fast_open) = true' \
            || ! enable_kernel_tfo; then
            changed=0
        fi
    else
        edit_config '(.inbounds[] | select(.type == "anytls")) |= del(.tcp_fast_open)' || changed=0
        disable_kernel_tfo
    fi
    if (( changed )) && runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" \
        && systemctl restart sing-box && wait_tls 5; then
        rm -f -- "$backup" || true
    else
        warn '修改或验证失败，正在恢复原设置…' >&2
        mv -f -- "$backup" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup}。"
        if [[ "$action" == on ]]; then disable_kernel_tfo; else enable_kernel_tfo || true; fi
        systemctl restart sing-box || true
        fail "TCP Fast Open 设置失败，已恢复原设置；请运行 $(cmd_name) log 查看日志。"
    fi
    if [[ "$action" == on ]]; then
        ok "已开启 TCP Fast Open（内核 net.ipv4.tcp_fastopen=$(kernel_tfo_value)）。"
    else
        ok "已关闭 TCP Fast Open（内核 net.ipv4.tcp_fastopen=$(kernel_tfo_value)）。"
    fi
    say '将下面这一行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
}

start_node() {
    need_root
    load_metadata
    if systemctl is-active --quiet sing-box; then
        ok '服务已在运行。'
        return 0
    fi
    systemctl start sing-box || fail "启动失败；运行 $(cmd_name) log 查看日志。"
    say '正在验证 TLS…'
    wait_tls 5 || fail "服务已启动，但 TLS 验证未通过；运行 $(cmd_name) log 查看日志。"
    ok '服务已启动，TLS 验证通过。'
}

stop_node() {
    need_root
    load_metadata
    if ! systemctl is-active --quiet sing-box; then
        ok '服务已处于停止状态。'
        return 0
    fi
    if [[ -t 0 ]] && ! confirm '停止后节点将无法连接，确定停止？[y/N]：'; then
        say '已取消。'
        return 0
    fi
    systemctl stop sing-box || fail '停止服务失败。'
    ok "服务已停止。需要恢复时运行 $(cmd_name) start。"
    warn '注意：服务停止期间证书不会自动续期；重启 VPS 后服务会自动启动。'
}

restart_node() {
    need_root
    load_metadata
    say '正在重启服务…'
    systemctl restart sing-box || fail "重启失败；运行 $(cmd_name) log 查看日志。"
    wait_tls 5 || fail "服务已重启，但 TLS 验证未通过；运行 $(cmd_name) log 查看日志。"
    ok '服务已重启，TLS 验证通过。'
}

log_node() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) log [-f|行数]"
    local arg="${1:-50}"
    if [[ "$arg" == -f ]]; then
        say '实时查看日志，按 Ctrl+C 退出。'
        journalctl -u sing-box -f --no-pager
        return 0
    fi
    [[ "$arg" =~ ^[0-9]{1,5}$ ]] || fail '行数必须是数字，例如 log 100。'
    journalctl -u sing-box -n "$arg" --no-pager
}

download_file() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -t 3 -O "$2" "$1"
    else
        return 1
    fi
}

self_update() {
    need_root
    local new remote_ver
    TEMP_DIR="$(mktemp -d /root/.anytls-update.XXXXXX)"
    trap cleanup_temp EXIT
    new="$TEMP_DIR/anytls-setup.sh"
    say "当前脚本版本：v${SCRIPT_VERSION}，正在检查最新版本…"
    download_file "$SCRIPT_URL" "$new" || fail '下载最新脚本失败，请检查网络后重试；旧脚本保持不变。'
    [[ -s "$new" && "$(head -n 1 "$new")" == '#!/usr/bin/env bash' ]] && grep -qF 'anytls-setup-owned' "$new" \
        || fail '下载的文件不是 AnyTLS 管理脚本，已停止；旧脚本保持不变。'
    bash -n "$new" || fail '新脚本语法检查未通过，已停止；旧脚本保持不变。'
    remote_ver="$(sed -n "s/^SCRIPT_VERSION='\([^']*\)'.*/\1/p" "$new" | head -n 1)"
    rm -f -- /root/anytls-setup.new.sh
    if [[ -f "$MANAGER" ]] && cmp -s -- "$new" "$MANAGER"; then
        ok "当前已是最新版本：v${remote_ver:-$SCRIPT_VERSION}"
        ensure_shortcut || true
        return 0
    fi
    say "发现新版本：v${remote_ver:-未知}（当前 v${SCRIPT_VERSION}）"
    if [[ -t 0 ]] && ! confirm '是否更新？[Y/n]：' y; then
        say '已取消更新。'
        return 0
    fi
    chmod 700 "$new"
    mv -f -- "$new" "$MANAGER" || fail '替换脚本失败；旧脚本保持不变。'
    ensure_shortcut || true
    ok "管理脚本已更新到 v${remote_ver:-最新版本}。"
}

uninstall_node() {
    need_root
    [[ -f "$MARKER" ]] || fail '未发现本脚本安装的节点，已停止以保护现有服务。'
    if ! confirm '确定卸载节点并清理全部残留？[y/N]（直接回车默认 n）：'; then
        say '已取消卸载。'
        return 0
    fi
    say '正在卸载…'
    purge_node_files
    if shortcut_is_ours; then rm -f -- "$SHORTCUT"; fi
    rm -f -- "$MANAGER" /root/anytls-setup.new.sh
    rm -rf -- /root/.anytls-update.*
    ok '卸载完成，已清理：'
    say '  · sing-box 程序、系统服务和 sing-box 系统用户'
    say '  · /etc/sing-box（配置、安装记录、备份）和 /var/lib/sing-box（证书、缓存）'
    say "  · ${SURGE_FILE}、${UNINSTALLER}、${MANAGER} 和更新时的临时文件"
    say "  · 快捷命令 ${SHORTCUT}"
    say "  · TCP Fast Open 设置 ${TFO_SYSCTL}（如有），内核参数已恢复"
    warn '以下内容在 VPS 之外，如不再使用请自行删除：域名 DNS 记录、云安全组规则、Surge 中的节点配置。'
}

# 菜单底部的状态行。
menu_status() {
    local state label color ver
    if [[ ! -f "$MARKER" || ! -f "$CONFIG" ]]; then
        say " 当前状态：${RED}● 未安装${RESET}"
        return 0
    fi
    ver="$(installed_version)"
    state="$(systemctl is-active sing-box 2>/dev/null || true)"
    case "$state" in
        active) color="$GREEN"; label='运行中' ;;
        activating|reloading) color="$YELLOW"; label='启动中' ;;
        failed) color="$RED"; label='运行失败' ;;
        inactive) color="$YELLOW"; label='已停止' ;;
        *) color="$YELLOW"; label="状态未知（${state:-无}）" ;;
    esac
    say " 当前状态：${GREEN}● 已安装${RESET} [sing-box ${ver:-未知}]  ${color}● ${label}${RESET}"
    read_marker
    say " 当前节点：${MARKER_NAME:-未命名}（${MARKER_DOMAIN:-未知域名}:${MARKER_PORT:-未知端口}）"
}

# 只读取 GitHub 上最新脚本的开头部分，取出版本号；失败时输出为空，不影响菜单。
query_remote_script_version() {
    local head_text=''
    if command -v curl >/dev/null 2>&1; then
        head_text="$(curl -fsS -r 0-2047 --connect-timeout 5 --max-time 8 "$SCRIPT_URL" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
        head_text="$(wget -qO- -T 8 -t 1 "$SCRIPT_URL" 2>/dev/null | head -c 2048 || true)"
    fi
    sed -n "s/^SCRIPT_VERSION='\([0-9][0-9.]*\)'.*/\1/p" <<< "$head_text" | head -n 1
}
# 判断版本号 $1 是否高于 $2。
version_gt() {
    [[ -n "$1" && -n "$2" && "$1" != "$2" ]] || return 1
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$1" gt "$2" 2>/dev/null
    else
        [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
    fi
}

show_menu() {
    local installed upgrade_tag='' script_tag=''
    installed="$(installed_version)"
    if version_gt "$LATEST_VERSION" "$installed"; then
        upgrade_tag="  ${YELLOW}(可升级到 ${LATEST_VERSION})${RESET}"
    fi
    if version_gt "$REMOTE_SCRIPT_VERSION" "$SCRIPT_VERSION"; then
        script_tag="  ${YELLOW}(可更新到 v${REMOTE_SCRIPT_VERSION})${RESET}"
    fi
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    say '=============================='
    say " AnyTLS 节点管理脚本 ${RED}[v${SCRIPT_VERSION}]${RESET}"
    say '=============================='
    say "  ${GREEN}0.${RESET} 更新脚本${script_tag}"
    say '——————————————————————————————'
    say "  ${GREEN}1.${RESET} 安装节点"
    say "  ${GREEN}2.${RESET} 卸载节点（含清理残留）"
    say "  ${GREEN}3.${RESET} 升级 sing-box${upgrade_tag}"
    say '——————————————————————————————'
    say "  ${GREEN}4.${RESET} 启动服务"
    say "  ${GREEN}5.${RESET} 停止服务"
    say "  ${GREEN}6.${RESET} 重启服务"
    say '——————————————————————————————'
    say "  ${GREEN}7.${RESET} 修改密码"
    say "  ${GREEN}8.${RESET} 修改端口"
    say "  ${GREEN}9.${RESET} 修改节点名称"
    say " ${GREEN}10.${RESET} 切换服务器地址（域名/IP）"
    say " ${GREEN}11.${RESET} 开关 TCP Fast Open"
    say " ${GREEN}15.${RESET} 更换证书域名"
    say '——————————————————————————————'
    say " ${GREEN}12.${RESET} 查看节点行"
    say " ${GREEN}13.${RESET} 查看运行状态"
    say " ${GREEN}14.${RESET} 查看运行日志"
    say '——————————————————————————————'
    say " ${GREEN}00.${RESET} 退出"
    say '=============================='
    menu_status
    say
}

menu_action() {
    case "$1" in
        0) self_update ;;
        1) install_node ;;
        2) uninstall_node ;;
        3) update_node ;;
        4) start_node ;;
        5) stop_node ;;
        6) restart_node ;;
        7) warn '修改后，Surge 中的旧密码会立即失效。'; change_password ;;
        8) warn '请先在服务商安全组放行准备使用的新端口。'; change_port ;;
        9) rename_node ;;
        10) addr_node ;;
        11) tfo_node ;;
        15) change_domain ;;
        12) menu_show ;;
        13) status_node ;;
        14) log_node ;;
        *) return 2 ;;
    esac
}

interactive_menu() {
    if [[ ! -t 0 ]]; then
        print_help
        return 0
    fi
    need_root
    ensure_shortcut quiet || true
    local choice rc before dummy
    say '正在检查更新…'
    REMOTE_SCRIPT_VERSION="$(query_remote_script_version)"
    if [[ -f "$MARKER" ]]; then
        LATEST_VERSION="$(query_latest_version)"
    fi
    while true; do
        show_menu
        read -r -p ' 请输入数字 [0-15，00 退出]：' choice || { say; return 0; }
        case "$choice" in
            00|q|Q) return 0 ;;
            [0-9]|1[0-5]) ;;
            *) warn ' 请输入菜单中的数字。'; sleep 1; continue ;;
        esac
        before="$(cksum "$MANAGER" 2>/dev/null || true)"
        say
        # 每项操作在子进程中运行：出错只结束这一项，不会退出菜单。
        set +e
        ( set -e; menu_action "$choice" )
        rc=$?
        set -e
        if [[ "$choice" == 0 && -f "$MANAGER" && "$(cksum "$MANAGER")" != "$before" ]]; then
            ok '正在打开新版本脚本…'
            sleep 1
            exec bash "$MANAGER"
        fi
        if [[ "$choice" == 2 && ! -f "$MANAGER" ]]; then
            return 0
        fi
        if (( rc != 0 )); then say; fi
        say
        read -r -p "${YELLOW}* 按回车返回主菜单 *${RESET}" dummy || { say; return 0; }
    done
}

main() {
    case "${1:-}" in
        '') interactive_menu ;;
        help|-h|--help) print_help ;;
        install) shift; install_node "$@" ;;
        status) status_node ;;
        show) show_node ;;
        password) change_password ;;
        port) shift; change_port "$@" ;;
        domain) shift; change_domain "$@" ;;
        rename) shift; rename_node "$@" ;;
        addr) shift; addr_node "$@" ;;
        tfo) shift; tfo_node "$@" ;;
        start) start_node ;;
        stop) stop_node ;;
        restart) restart_node ;;
        log|logs) shift; log_node "$@" ;;
        version) version_node ;;
        update) update_node ;;
        self-update|update-script) self_update ;;
        uninstall) uninstall_node ;;
        [0-9]|1[0-5]) need_root; menu_action "$1" ;;
        *) print_help; exit 2 ;;
    esac
}

main "$@"
