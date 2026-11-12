#!/usr/bin/env bash
# VLESS + REALITY + Vision 节点管理脚本：Debian/Ubuntu + Xray-core。
# 请先下载为普通文件后运行，不支持 curl | bash（安装过程需要读取终端输入）。
# shellcheck disable=SC2016 # 下方单引号内的 $name 是 jq 变量，不由 Bash 展开。
set -Eeuo pipefail
umask 077

SCRIPT_VERSION='1.0.0'
XRAY_API='https://api.github.com/repos/XTLS/Xray-core/releases'
XRAY_BIN='/usr/local/bin/xray'
CONFIG_DIR='/usr/local/etc/xray'
CONFIG='/usr/local/etc/xray/config.json'
MARKER='/usr/local/etc/xray/.vless-reality-owned'
SERVICE='/etc/systemd/system/xray.service'
MANAGER='/root/vless-reality-setup.sh'
SHORTCUT='/usr/local/bin/vless-reality'
SHORTCUT_TAG='# vless-reality-setup shortcut'
LINK_FILE='/root/vless-reality-link.txt'
TEMP_DIR=''
RELEASE_VERSION=''
RELEASE_URL=''
RELEASE_SHA256=''
PORT=''
SNI=''
NODE_NAME=''
SERVER_IP=''
PUBLIC_KEY=''
SHORT_ID=''
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

valid_host() {
    (( ${#1} <= 253 )) || return 1
    [[ "$1" == *.* && "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
valid_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *$'\n'* ]]
}
port_free() {
    local listeners
    listeners="$(ss -H -ltn "sport = :$1")" || fail "无法检查本机 TCP ${1}。"
    [[ -z "$listeners" ]]
}
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
default_port() {
    if ! command -v ss >/dev/null 2>&1 || port_free 443; then
        printf '443'
    else
        random_port
    fi
}
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

ensure_dependencies() {
    need_command apt-get
    local command_name packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v unzip >/dev/null 2>&1 || packages+=(unzip)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v ss >/dev/null 2>&1 || packages+=(iproute2)
    if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
        packages+=(ca-certificates)
    fi
    if (( ${#packages[@]} )); then
        say "安装缺失的基础工具：${packages[*]}"
        apt-get update
        apt-get install -y "${packages[@]}"
    fi
    for command_name in curl jq unzip openssl ss awk sed od tr systemctl sha256sum getent install timeout dpkg; do
        need_command "$command_name"
    done
}

arch_asset() {
    case "$(dpkg --print-architecture 2>/dev/null)" in
        amd64) printf 'Xray-linux-64.zip' ;;
        arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
        *) fail "不支持的架构：$(dpkg --print-architecture 2>/dev/null || uname -m)" ;;
    esac
}

fetch_release_metadata() {
    local selector="$1" asset="$2" api_url release_file tag asset_json url digest
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] || fail '临时目录未准备好。'
    if [[ "$selector" == latest ]]; then
        api_url="$XRAY_API/latest"
    elif [[ "$selector" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
        api_url="$XRAY_API/tags/$selector"
    else
        fail "无效的 Xray 版本：$selector"
    fi
    release_file="$TEMP_DIR/release.json"
    curl -fLsS --retry 3 --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' -o "$release_file" "$api_url" \
        || fail '无法查询 XTLS/Xray-core 官方 GitHub 发布信息。'
    tag="$(jq -er '.tag_name | select(type == "string")' "$release_file")" \
        || fail '官方发布信息缺少版本号。'
    [[ "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || fail "官方版本号格式异常：$tag"
    [[ "$(jq -r '[.draft, .prerelease] | join(",")' "$release_file")" == 'false,false' ]] \
        || fail '查询到的不是正式稳定版。'
    asset_json="$(jq -c --arg name "$asset" \
        '[(.assets // [])[] | select(.name == $name)] | if length == 1 then .[0] else null end' "$release_file")"
    [[ "$asset_json" != null ]] || fail "官方稳定版 $tag 没有找到 ${asset}。"
    url="$(jq -er '.browser_download_url | select(type == "string")' <<< "$asset_json")" \
        || fail '官方安装包缺少下载地址。'
    digest="$(jq -er '.digest | select(type == "string")' <<< "$asset_json")" \
        || fail '官方安装包缺少 SHA-256。'
    [[ "$url" == "https://github.com/XTLS/Xray-core/releases/download/$tag/$asset" ]] \
        || fail '官方安装包下载地址格式异常。'
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail '官方安装包 SHA-256 格式异常。'
    RELEASE_VERSION="${tag#v}"
    RELEASE_URL="$url"
    RELEASE_SHA256="${digest#sha256:}"
}

download_verified_release() {
    local target="$1"
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$target" "$RELEASE_URL" \
        || fail '下载 Xray 官方安装包失败。'
    printf '%s  %s\n' "$RELEASE_SHA256" "$target" | sha256sum --check --status \
        || fail '安装包 SHA-256 与 GitHub 官方发布信息不一致，已停止。'
}

installed_version() {
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 {print $2}'
    fi
}

target_tls_ok() {
    local host="$1" output
    output="$(timeout 10 openssl s_client -connect "${host}:443" -servername "$host" \
        -tls1_3 -verify_hostname "$host" -verify_return_error -CApath /etc/ssl/certs \
        </dev/null 2>&1 || true)"
    [[ "$output" == *'Verify return code: 0 (ok)'* && "$output" == *'TLSv1.3'* ]]
}

generate_reality_keys() {
    local output private public
    output="$($XRAY_BIN x25519)" || return 1
    private="$(awk -F': *' '/^(PrivateKey|Private key):/ {print $2; exit}' <<< "$output")"
    public="$(awk -F': *' '/^(Password \(PublicKey\)|PublicKey|Public key):/ {print $2; exit}' <<< "$output")"
    [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ && "$public" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    printf '%s\n%s\n' "$private" "$public"
}

write_marker() {
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$PORT" "$SNI" "$NODE_NAME" "$SERVER_IP" "$PUBLIC_KEY" "$SHORT_ID" > "$MARKER"
    chown root:xray "$MARKER"
    chmod 640 "$MARKER"
}

load_metadata() {
    [[ -f "$MARKER" && -f "$CONFIG" ]] || fail '未发现本脚本安装的节点。'
    local lines=()
    mapfile -t lines < "$MARKER"
    PORT="${lines[0]:-}"
    SNI="${lines[1]:-}"
    NODE_NAME="${lines[2]:-}"
    SERVER_IP="${lines[3]:-}"
    PUBLIC_KEY="${lines[4]:-}"
    SHORT_ID="${lines[5]:-}"
    valid_port "$PORT" || fail '安装记录中的端口无效。'
    valid_host "$SNI" || fail '安装记录中的 SNI 无效。'
    [[ -n "$NODE_NAME" && -n "$SERVER_IP" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]] \
        || fail '安装记录不完整。'
}

config_uuid() {
    jq -er '[.inbounds[] | select(.protocol == "vless") | .settings.clients[] | select(.flow == "xtls-rprx-vision") | .id][0]' "$CONFIG"
}

edit_config() {
    local tmp
    tmp="$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")" || return 1
    if jq "$@" "$CONFIG" > "$tmp" && chown root:xray "$tmp" && chmod 640 "$tmp" \
        && mv -f -- "$tmp" "$CONFIG"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

config_ok() {
    "$XRAY_BIN" run -test -config "$CONFIG" >/dev/null 2>&1
}
service_ok() {
    systemctl is-active --quiet xray && [[ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]]
}
wait_service() {
    local attempt
    for ((attempt = 1; attempt <= ${1:-10}; attempt++)); do
        service_ok && return 0
        sleep 1
    done
    return 1
}

save_manager() {
    local source_file="${BASH_SOURCE[0]}"
    [[ -f "$source_file" && "$source_file" != /dev/fd/* && "$source_file" != /proc/*/fd/* ]] \
        || fail '请先将脚本下载为普通文件后运行，例如 /root/vless-reality-setup.sh；不支持 curl | bash。'
    if [[ ! "$source_file" -ef "$MANAGER" ]]; then
        [[ ! -e "$MANAGER" ]] || fail "$MANAGER 已存在；请先检查该文件，脚本不会覆盖它。"
        install -m 700 -- "$source_file" "$MANAGER"
        MANAGER_COPIED=1
    fi
}
shortcut_is_ours() {
    [[ -f "$SHORTCUT" ]] && grep -qF -- "$SHORTCUT_TAG" "$SHORTCUT" 2>/dev/null
}
ensure_shortcut() {
    local quiet="${1:-}"
    [[ -f "$MANAGER" ]] || return 1
    if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
        shortcut_is_ours && return 0
        [[ -n "$quiet" ]] || warn "$SHORTCUT 已被占用，未创建快捷命令。"
        return 1
    fi
    printf '#!/usr/bin/env bash\n%s\nexec bash %s "$@"\n' "$SHORTCUT_TAG" "$MANAGER" > "$SHORTCUT"
    chmod 755 "$SHORTCUT"
}
cmd_name() {
    if shortcut_is_ours; then printf 'vless-reality'; else printf 'bash %s' "$MANAGER"; fi
}

check_install_eligibility() {
    if [[ -f "$MARKER" && -f "$CONFIG" ]]; then
        fail "检测到本脚本已经安装节点，请运行 $(cmd_name) 打开管理菜单。"
    fi
    [[ ! -e "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || fail "$CONFIG_DIR 已存在；为保护现有配置，已停止。"
    [[ ! -e "$SERVICE" && ! -L "$SERVICE" ]] || fail "$SERVICE 已存在；为保护现有服务，已停止。"
    [[ ! -e "$XRAY_BIN" && ! -L "$XRAY_BIN" ]] || fail "$XRAY_BIN 已存在；为保护现有安装，已停止。"
    if command -v systemctl >/dev/null 2>&1 && systemctl cat xray.service >/dev/null 2>&1; then
        fail '检测到已有 xray.service；本脚本不会覆盖现有服务。'
    fi
    [[ ! -e "$LINK_FILE" ]] || fail "$LINK_FILE 已存在；为避免覆盖，已停止。"
    getent passwd xray >/dev/null 2>&1 && fail '系统中已存在 xray 用户；为避免误用或卸载时误删，已停止。'
    getent group xray >/dev/null 2>&1 && fail '系统中已存在 xray 用户组；为避免误用或卸载时误删，已停止。'
}

purge_node_files() {
    systemctl disable --now xray >/dev/null 2>&1 || true
    rm -f -- "$SERVICE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f -- "$XRAY_BIN" "$LINK_FILE"
    rm -rf -- "$CONFIG_DIR"
    if getent passwd xray >/dev/null 2>&1; then userdel xray >/dev/null 2>&1 || true; fi
    if getent group xray >/dev/null 2>&1; then groupdel xray >/dev/null 2>&1 || true; fi
}
finish_install() {
    local result=$?
    trap - EXIT
    if (( INSTALL_COMMITTED == 0 )); then
        if (( INSTALL_STARTED )); then
            warn '安装未完成，正在撤销本次创建的服务和文件…' >&2
            purge_node_files
        fi
        if (( MANAGER_COPIED )); then rm -f -- "$MANAGER"; fi
    fi
    [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    return "$result"
}

write_config() {
    local uuid="$1" private_key="$2"
    jq -n \
        --arg uuid "$uuid" --arg privateKey "$private_key" --arg shortId "$SHORT_ID" \
        --arg sni "$SNI" --argjson port "$PORT" '
        {
          log: {loglevel: "warning"},
          inbounds: [{
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: {
              clients: [{id: $uuid, flow: "xtls-rprx-vision", email: "default"}],
              decryption: "none"
            },
            streamSettings: {
              network: "tcp",
              security: "reality",
              realitySettings: {
                show: false,
                target: ($sni + ":443"),
                xver: 0,
                serverNames: [$sni],
                privateKey: $privateKey,
                shortIds: [$shortId]
              }
            },
            sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
          }],
          outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}]
        }' > "$CONFIG"
    chown root:xray "$CONFIG"
    chmod 640 "$CONFIG"
}

install_node() {
    need_root
    [[ $# -le 3 ]] || fail "用法：$(cmd_name) install [端口] [伪装域名] [节点名称]"
    check_install_eligibility
    local interactive=0 raw_port="${1:-}" answer default_name default_selected
    default_name="Reality-$(hostname -s)"

    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请指定端口、伪装域名和节点名称。'
        interactive=1
        default_selected="$(default_port)" || fail '无法选择可用端口。'
        while true; do
            read -r -p "请输入节点 TCP 端口（直接回车使用 ${default_selected}）：" raw_port || fail '已取消输入。'
            [[ -n "$raw_port" ]] || raw_port="$default_selected"
            if valid_port "$raw_port" && (! command -v ss >/dev/null 2>&1 || port_free "$((10#$raw_port))"); then break; fi
            warn '端口无效或已被占用，请换一个端口。' >&2
        done
    fi
    valid_port "$raw_port" || fail '端口必须是 1–65535 的数字。'
    PORT="$((10#$raw_port))"

    SNI="${2:-}"
    if [[ -z "$SNI" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请指定伪装域名。'
        interactive=1
        read -r -p '请输入 REALITY 伪装域名（直接回车使用 www.amazon.com）：' SNI || fail '已取消输入。'
        SNI="${SNI:-www.amazon.com}"
    fi
    SNI="${SNI,,}"
    valid_host "$SNI" || fail '伪装域名格式不正确；只填域名，不要带 https://、端口或路径。'

    NODE_NAME="${3:-$default_name}"
    if (( interactive )); then
        read -r -p "请输入节点名称（直接回车使用 ${default_name}）：" answer || fail '已取消输入。'
        [[ -z "$answer" ]] || NODE_NAME="$answer"
    fi
    valid_node_name "$NODE_NAME" || fail '节点名称不能为空、不能超过 64 个字符或包含换行。'

    if (( interactive )); then
        say
        step '—————————— 确认安装信息 ——————————'
        say "  协议：VLESS + REALITY + Vision"
        say "  端口：TCP $PORT"
        say "  SNI： $SNI:443"
        say "  名称：$NODE_NAME"
        warn "  请确认云安全组已放行 TCP ${PORT}，无需开放 TCP 80"
        step '————————————————————————————————'
        confirm '开始安装？[y/N]：' || { say '已取消安装。'; return 0; }
    fi

    step '[1/5] 检查系统和安装环境…'
    [[ -r /etc/os-release ]] || fail '无法识别系统。'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || fail '这个脚本仅支持 Debian 和 Ubuntu。'
    ensure_dependencies
    check_install_eligibility
    port_free "$PORT" || fail "本机 TCP $PORT 已被占用。"
    SERVER_IP="$(public_ipv4)" || fail '无法查询此 VPS 的公网 IPv4。'
    step '[2/5] 验证 REALITY 伪装站点…'
    target_tls_ok "$SNI" || fail "$SNI:443 未通过 TLS 1.3 与证书校验，请更换可从本机访问的伪装域名。"
    ok "伪装站点可用：$SNI:443（TLS 1.3）"

    trap finish_install EXIT
    save_manager
    TEMP_DIR="$(mktemp -d)"
    INSTALL_STARTED=1
    step '[3/5] 下载并校验 Xray-core 官方稳定版…'
    local asset archive
    asset="$(arch_asset)"
    archive="$TEMP_DIR/xray.zip"
    fetch_release_metadata latest "$asset"
    say "下载 Xray ${RELEASE_VERSION}（${asset}）…"
    download_verified_release "$archive"
    unzip -q "$archive" xray -d "$TEMP_DIR"
    [[ -x "$TEMP_DIR/xray" || -f "$TEMP_DIR/xray" ]] || fail '安装包中没有找到 xray 程序。'
    install -m 755 "$TEMP_DIR/xray" "$XRAY_BIN"

    step '[4/5] 生成 UUID、REALITY 密钥和配置…'
    if ! getent group xray >/dev/null 2>&1; then groupadd --system xray; fi
    if ! getent passwd xray >/dev/null 2>&1; then
        useradd --system --gid xray --home-dir /nonexistent --shell /usr/sbin/nologin xray
    fi
    install -d -o root -g xray -m 750 "$CONFIG_DIR"
    local uuid key_lines private_key
    uuid="$($XRAY_BIN uuid)"
    mapfile -t key_lines < <(generate_reality_keys)
    (( ${#key_lines[@]} == 2 )) || fail 'REALITY 密钥生成失败。'
    private_key="${key_lines[0]}"
    PUBLIC_KEY="${key_lines[1]}"
    SHORT_ID="$(openssl rand -hex 8)"
    write_config "$uuid" "$private_key"
    write_marker
    config_ok || fail 'Xray 配置校验失败。'

    cat > "$SERVICE" <<'EOF'
[Unit]
Description=Xray VLESS REALITY Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE"

    step '[5/5] 启动服务并检查监听端口…'
    systemctl daemon-reload
    systemctl enable --now xray
    wait_service 10 || fail "Xray 未正常监听 TCP $PORT；请查看 journalctl -u xray。"
    ensure_shortcut || true
    INSTALL_COMMITTED=1
    trap - EXIT
    rm -rf -- "$TEMP_DIR"
    TEMP_DIR=''
    ok "安装完成：Xray ${RELEASE_VERSION} 正在监听 TCP ${PORT}。"
    show_node
    warn "请确认云安全组已放行 TCP ${PORT}。导入链接包含 UUID，请勿公开分享。"
}

show_node() {
    need_root
    load_metadata
    local uuid label link
    uuid="$(config_uuid)" || fail '无法从配置读取 UUID。'
    label="$(jq -rn --arg v "$NODE_NAME" '$v | @uri')"
    link="vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${label}"
    printf '%s\n' "$link" > "$LINK_FILE"
    chmod 600 "$LINK_FILE"
    say
    say 'VLESS 导入链接：'
    printf '%s%s%s\n' "$BOLD" "$link" "$RESET"
    say
    say "已保存到：$LINK_FILE"
}

status_node() {
    need_root
    load_metadata
    local state current_ip version
    state="$(systemctl is-active xray 2>/dev/null || true)"
    version="$(installed_version)"
    say "服务状态：$state"
    say "Xray 版本：${version:-未知}"
    say "监听地址：${SERVER_IP}:${PORT}/TCP"
    say "REALITY SNI：${SNI}:443"
    say "Vision flow：xtls-rprx-vision"
    if config_ok; then ok '配置检查：通过'; else warn '配置检查：失败'; fi
    if [[ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]]; then ok '端口监听：正常'; else warn '端口监听：未发现'; fi
    current_ip="$(public_ipv4 || true)"
    if [[ -n "$current_ip" && "$current_ip" != "$SERVER_IP" ]]; then
        warn "公网 IPv4 已变化：当前 $current_ip，链接中仍为 $SERVER_IP；请运行 $(cmd_name) refresh-ip。"
    fi
    if target_tls_ok "$SNI"; then ok '伪装站点：TLS 1.3 正常'; else warn '伪装站点：当前验证失败'; fi
}

backup_state() {
    local dir="$1"
    cp -a -- "$CONFIG" "$MARKER" "$dir/"
}
restore_state() {
    local dir="$1"
    cp -a -- "$dir/config.json" "$CONFIG"
    cp -a -- "$dir/.vless-reality-owned" "$MARKER"
    systemctl restart xray >/dev/null 2>&1 || true
}
commit_change() {
    local backup="$1" old_port="$2" description="$3"
    if config_ok && systemctl restart xray && wait_service 10; then
        rm -rf -- "$backup"
        ok "$description"
        show_node
        return 0
    fi
    PORT="$old_port"
    restore_state "$backup"
    rm -rf -- "$backup"
    fail '修改后的配置未能正常启动，已恢复原配置。'
}

change_port() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) port [新端口]"
    load_metadata
    local raw="${1:-}" old_port="$PORT" backup
    if [[ -z "$raw" ]]; then
        [[ -t 0 ]] || fail '非交互运行时请指定新端口。'
        read -r -p "当前端口 $PORT，请输入新端口：" raw || fail '已取消输入。'
    fi
    valid_port "$raw" || fail '端口必须是 1–65535 的数字。'
    PORT="$((10#$raw))"
    (( PORT != old_port )) || fail '新端口与当前端口相同。'
    port_free "$PORT" || fail "本机 TCP $PORT 已被占用。"
    backup="$(mktemp -d "$CONFIG_DIR/.change-backup.XXXXXX")"
    backup_state "$backup"
    edit_config --argjson port "$PORT" '(.inbounds[] | select(.protocol == "vless") | .port) = $port' \
        || { restore_state "$backup"; fail '写入配置失败。'; }
    write_marker
    commit_change "$backup" "$old_port" "端口已改为 TCP $PORT；请放行新端口，确认可用后再关闭旧端口 $old_port。"
}

change_sni() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) sni [新域名]"
    load_metadata
    local new="${1:-}" old_port="$PORT" backup
    if [[ -z "$new" ]]; then
        [[ -t 0 ]] || fail '非交互运行时请指定新伪装域名。'
        read -r -p "当前 SNI $SNI，请输入新伪装域名：" new || fail '已取消输入。'
    fi
    new="${new,,}"
    valid_host "$new" || fail '伪装域名格式不正确。'
    [[ "$new" != "$SNI" ]] || fail '新域名与当前域名相同。'
    target_tls_ok "$new" || fail "$new:443 未通过 TLS 1.3 与证书校验。"
    backup="$(mktemp -d "$CONFIG_DIR/.change-backup.XXXXXX")"
    backup_state "$backup"
    SNI="$new"
    edit_config --arg sni "$SNI" \
        '(.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.target) = ($sni + ":443") |
         (.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.serverNames) = [$sni]' \
        || { restore_state "$backup"; fail '写入配置失败。'; }
    write_marker
    commit_change "$backup" "$old_port" "REALITY 伪装域名已改为 $SNI。"
}

change_uuid() {
    need_root
    load_metadata
    local new old_port="$PORT" backup
    new="$($XRAY_BIN uuid)"
    backup="$(mktemp -d "$CONFIG_DIR/.change-backup.XXXXXX")"
    backup_state "$backup"
    edit_config --arg id "$new" \
        '(.inbounds[] | select(.protocol == "vless") | .settings.clients[] | select(.flow == "xtls-rprx-vision") | .id) = $id' \
        || { restore_state "$backup"; fail '写入配置失败。'; }
    commit_change "$backup" "$old_port" 'UUID 已重新生成，旧链接立即失效。'
}

rotate_keys() {
    need_root
    load_metadata
    local key_lines private old_port="$PORT" backup
    mapfile -t key_lines < <(generate_reality_keys)
    (( ${#key_lines[@]} == 2 )) || fail 'REALITY 密钥生成失败。'
    private="${key_lines[0]}"
    PUBLIC_KEY="${key_lines[1]}"
    SHORT_ID="$(openssl rand -hex 8)"
    backup="$(mktemp -d "$CONFIG_DIR/.change-backup.XXXXXX")"
    backup_state "$backup"
    edit_config --arg private "$private" --arg sid "$SHORT_ID" \
        '(.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.privateKey) = $private |
         (.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.shortIds) = [$sid]' \
        || { restore_state "$backup"; fail '写入配置失败。'; }
    write_marker
    commit_change "$backup" "$old_port" 'REALITY 密钥和 Short ID 已轮换，旧链接立即失效。'
}

rename_node() {
    need_root
    [[ $# -le 1 ]] || fail "用法：$(cmd_name) rename [新名称]"
    load_metadata
    local new="${1:-}"
    if [[ -z "$new" ]]; then
        [[ -t 0 ]] || fail '非交互运行时请指定新名称。'
        read -r -p "当前名称 $NODE_NAME，请输入新名称：" new || fail '已取消输入。'
    fi
    valid_node_name "$new" || fail '名称不能为空、不能超过 64 个字符或包含换行。'
    NODE_NAME="$new"
    write_marker
    ok '节点名称已修改，无需重启服务。'
    show_node
}

refresh_ip() {
    need_root
    load_metadata
    local ip
    ip="$(public_ipv4)" || fail '无法查询当前公网 IPv4。'
    if [[ "$ip" == "$SERVER_IP" ]]; then ok "公网 IPv4 未变化：$ip"; return 0; fi
    SERVER_IP="$ip"
    write_marker
    ok "链接中的服务器地址已更新为 $SERVER_IP，服务无需重启。"
    show_node
}

update_xray() {
    need_root
    load_metadata
    ensure_dependencies
    local current asset archive candidate backup
    current="$(installed_version)"
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
    asset="$(arch_asset)"
    archive="$TEMP_DIR/xray.zip"
    fetch_release_metadata latest "$asset"
    if [[ "$current" == "$RELEASE_VERSION" ]]; then
        ok "当前已是官方最新稳定版：$current"
        return 0
    fi
    say "准备从 ${current:-未知} 升级到 ${RELEASE_VERSION}…"
    download_verified_release "$archive"
    unzip -q "$archive" xray -d "$TEMP_DIR"
    candidate="$TEMP_DIR/xray"
    chmod 755 "$candidate"
    "$candidate" run -test -config "$CONFIG" >/dev/null || fail '新版 Xray 不接受当前配置，已停止升级。'
    backup="$TEMP_DIR/xray.old"
    cp -a -- "$XRAY_BIN" "$backup"
    install -m 755 "$candidate" "$XRAY_BIN"
    if systemctl restart xray && wait_service 10; then
        ok "Xray 已升级到 ${RELEASE_VERSION}。"
        return 0
    fi
    install -m 755 "$backup" "$XRAY_BIN"
    systemctl restart xray >/dev/null 2>&1 || true
    fail "升级后服务未正常运行，已恢复 Xray ${current:-旧版本}。"
}

start_node() {
    need_root; load_metadata
    if systemctl is-active --quiet xray; then ok '服务已在运行。'; return 0; fi
    systemctl start xray || fail '启动失败，请查看日志。'
    wait_service 10 || fail '服务已启动但端口未正常监听，请查看日志。'
    ok '服务已启动。'
}
stop_node() {
    need_root; load_metadata
    if ! systemctl is-active --quiet xray; then ok '服务已经停止。'; return 0; fi
    if [[ -t 0 ]] && ! confirm '停止后节点将无法连接，确定停止？[y/N]：'; then say '已取消。'; return 0; fi
    systemctl stop xray
    ok '服务已停止。'
}
restart_node() {
    need_root; load_metadata
    config_ok || fail '配置检查失败，未重启。'
    systemctl restart xray || fail '重启失败，请查看日志。'
    wait_service 10 || fail '重启后端口未正常监听，请查看日志。'
    ok '服务已重启。'
}
log_node() {
    need_root
    local arg="${1:-50}"
    if [[ "$arg" == -f ]]; then journalctl -u xray -f --no-pager; return 0; fi
    [[ "$arg" =~ ^[0-9]{1,5}$ ]] || fail '行数必须是数字，例如 log 100。'
    journalctl -u xray -n "$arg" --no-pager
}

uninstall_node() {
    need_root
    [[ -f "$MARKER" ]] || fail '未发现本脚本安装的节点，已停止以保护现有服务。'
    confirm '确定卸载节点并清理本脚本创建的全部文件？[y/N]：' || { say '已取消卸载。'; return 0; }
    purge_node_files
    shortcut_is_ours && rm -f -- "$SHORTCUT"
    rm -f -- "$MANAGER"
    ok '卸载完成。云安全组规则和客户端中的旧节点需要自行删除。'
}

print_help() {
    local cmd
    cmd="$(cmd_name)"
    cat <<EOF
VLESS + REALITY + Vision 节点管理脚本 v${SCRIPT_VERSION}
用法：${cmd} [命令]
  install [端口] [SNI] [名称]  安装节点
  show                         显示 vless:// 导入链接
  status                       查看服务、配置、端口和伪装站点状态
  port [新端口]                修改端口
  sni [新域名]                 修改 REALITY 伪装域名
  uuid                         重新生成 UUID
  rotate-keys                  轮换 REALITY 密钥和 Short ID
  rename [新名称]              修改节点名称
  refresh-ip                   更新链接中的公网 IPv4
  start|stop|restart           管理服务
  log [-f|行数]                查看日志
  update                       升级 Xray-core
  uninstall                    卸载并清理
EOF
}

menu_status() {
    if [[ ! -f "$MARKER" ]]; then say " 当前状态：${RED}● 未安装${RESET}"; return 0; fi
    local state color label
    state="$(systemctl is-active xray 2>/dev/null || true)"
    case "$state" in
        active) color="$GREEN"; label='运行中' ;;
        failed) color="$RED"; label='运行失败' ;;
        *) color="$YELLOW"; label="${state:-未知}" ;;
    esac
    load_metadata
    say " 当前状态：${GREEN}● 已安装${RESET} [Xray $(installed_version)]  ${color}● ${label}${RESET}"
    say " 当前节点：${NODE_NAME}（${SERVER_IP}:${PORT}，SNI ${SNI}）"
}

show_menu() {
    [[ -t 1 ]] && clear 2>/dev/null || true
    say '=================================='
    say " VLESS + REALITY + Vision ${RED}[v${SCRIPT_VERSION}]${RESET}"
    say '=================================='
    say '  1. 安装节点'
    say '  2. 卸载节点'
    say '  3. 升级 Xray-core'
    say '----------------------------------'
    say '  4. 启动服务'
    say '  5. 停止服务'
    say '  6. 重启服务'
    say '----------------------------------'
    say '  7. 修改端口'
    say '  8. 修改伪装域名（SNI）'
    say '  9. 重新生成 UUID'
    say ' 10. 轮换 REALITY 密钥'
    say ' 11. 修改节点名称'
    say ' 12. 刷新公网 IP'
    say '----------------------------------'
    say ' 13. 查看导入链接'
    say ' 14. 查看运行状态'
    say ' 15. 查看运行日志'
    say ' 00. 退出'
    say '=================================='
    menu_status
    say
}
menu_action() {
    case "$1" in
        1) install_node ;; 2) uninstall_node ;; 3) update_xray ;;
        4) start_node ;; 5) stop_node ;; 6) restart_node ;;
        7) change_port ;; 8) change_sni ;;
        9) warn '操作后旧链接立即失效。'; change_uuid ;;
        10) warn '操作后旧链接立即失效。'; rotate_keys ;;
        11) rename_node ;; 12) refresh_ip ;; 13) show_node ;;
        14) status_node ;; 15) log_node ;; *) return 2 ;;
    esac
}
interactive_menu() {
    if [[ ! -t 0 ]]; then print_help; return 0; fi
    need_root
    ensure_shortcut quiet || true
    local choice rc
    while true; do
        show_menu
        read -r -p '请输入数字 [1-15，00 退出]：' choice || { say; return 0; }
        case "$choice" in 00|q|Q) return 0 ;; [1-9]|1[0-5]) ;; *) warn '请输入菜单中的数字。'; sleep 1; continue ;; esac
        say
        set +e
        ( set -e; menu_action "$choice" )
        rc=$?
        set -e
        [[ "$choice" == 2 && ! -f "$MANAGER" ]] && return 0
        (( rc == 0 )) || say
        say
        read -r -p '* 按回车返回主菜单 *' || return 0
    done
}

main() {
    case "${1:-}" in
        '') interactive_menu ;;
        help|-h|--help) print_help ;;
        install) shift; install_node "$@" ;;
        show) show_node ;;
        status) status_node ;;
        port) shift; change_port "$@" ;;
        sni) shift; change_sni "$@" ;;
        uuid) change_uuid ;;
        rotate-keys) rotate_keys ;;
        rename) shift; rename_node "$@" ;;
        refresh-ip) refresh_ip ;;
        start) start_node ;;
        stop) stop_node ;;
        restart) restart_node ;;
        log|logs) shift; log_node "$@" ;;
        update) update_xray ;;
        uninstall) uninstall_node ;;
        [1-9]|1[0-5]) need_root; menu_action "$1" ;;
        *) print_help; exit 2 ;;
    esac
}

main "$@"
