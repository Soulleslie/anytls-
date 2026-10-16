#!/usr/bin/env bash
# AnyTLS for Debian/Ubuntu VPSs with a public IPv4 address.
# Usage: bash anytls-setup.sh install [domain] [port] [node_name]
#        bash anytls-setup.sh status|show|password|port [new_port]|version|update|uninstall|help
set -Eeuo pipefail
umask 077

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
TEMP_DIR=''
INSTALL_STARTED=0
INSTALL_COMMITTED=0
MANAGER_COPIED=0

say() { printf '%s\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || fail '请以 root 身份运行：bash /root/anytls-setup.sh ...'; }
need_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }
valid_domain() {
    [[ "$1" =~ ^[a-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *. && "$1" != *..* ]]
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

    for ((page = 1; page <= 5; page++)); do
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
        if [[ "$asset_json" != null ]]; then
            url="$(jq -er '.browser_download_url | select(type == "string")' <<< "$asset_json")" \
                || fail '官方安装包缺少下载地址。'
            digest="$(jq -er '.digest | select(type == "string")' <<< "$asset_json")" \
                || fail '官方安装包缺少 SHA-256。'
            [[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/$tag/$asset_name" ]] \
                || fail '官方安装包下载地址格式异常。'
            [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail '官方安装包 SHA-256 格式异常。'
            RELEASE_URL="$url"
            RELEASE_SHA256="${digest#sha256:}"
            return 0
        fi
        (( asset_count == 100 )) || break
    done
    fail "官方稳定版 $tag 没有找到 ${asset_name}。"
}

download_verified_package() {
    local target="$1"
    [[ -n "$RELEASE_URL" && -n "$RELEASE_SHA256" ]] || fail '安装包信息尚未准备好。'
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$target" "$RELEASE_URL" \
        || fail '下载安装包失败。'
    printf '%s  %s\n' "$RELEASE_SHA256" "$target" | sha256sum --check --status \
        || fail '安装包 SHA-256 与官方发布信息不一致，已停止。'
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

finish_install() {
    local result=$?
    trap - EXIT
    if (( INSTALL_COMMITTED == 0 )); then
        if (( INSTALL_STARTED )); then
            say '安装未完成，正在撤销本次创建的服务和节点文件…' >&2
            systemctl disable --now sing-box >/dev/null 2>&1 || true
            apt-get purge -y sing-box >/dev/null 2>&1 || say '软件包清理失败，请运行 dpkg-query -W sing-box 检查。' >&2
            rm -f -- "$CONFIG" "$MARKER" "$SURGE_FILE" /root/anytls-uninstall.sh
            rm -rf -- "$ACME_DIR"
            rmdir -- /etc/sing-box /var/lib/sing-box 2>/dev/null || true
            if [[ -d /etc/sing-box || -d /var/lib/sing-box ]]; then
                say '仍有安装目录未清空，请检查 /etc/sing-box 和 /var/lib/sing-box。' >&2
            fi
        fi
        if (( MANAGER_COPIED )); then rm -f -- "$MANAGER"; fi
    fi
    if [[ -n "$TEMP_DIR" ]]; then rm -rf -- "$TEMP_DIR"; fi
    return "$result"
}

print_help() {
    cat <<'EOF'
AnyTLS 管理命令（在 VPS 上以 root 身份运行）：
  bash /root/anytls-setup.sh            # 打开中文菜单
  bash /root/anytls-setup.sh install    # 新 VPS 安装；按提示输入域名和端口
  bash /root/anytls-setup.sh status     # 检查服务和证书
  bash /root/anytls-setup.sh show       # 查看 Surge 节点行（含密码）
  bash /root/anytls-setup.sh password   # 生成新密码；需更新 Surge 节点行
  bash /root/anytls-setup.sh port       # 修改节点端口；需先放行新端口并更新 Surge
  bash /root/anytls-setup.sh version    # 查看已安装版本及官方最新稳定版
  bash /root/anytls-setup.sh update     # 手动升级已安装节点的 sing-box
  bash /root/anytls-uninstall.sh        # 卸载本脚本安装的节点
  bash /root/anytls-setup.sh help       # 再次显示本帮助
EOF
}

interactive_menu() {
    if [[ ! -t 0 ]]; then
        print_help
        return
    fi
    local choice saved_domain saved_port
    say
    say '========== AnyTLS 节点管理 =========='
    if [[ -f "$MARKER" && -f "$CONFIG" ]]; then
        saved_domain="$(sed -n '1p' "$MARKER")"
        saved_port="$(sed -n '2p' "$MARKER")"
        say '检测到本脚本已配置的节点。'
        say "当前节点：${saved_domain:-未知域名}:${saved_port:-未知端口}"
        say '  1) 查看节点状态'
        say '  2) 查看 Surge 节点行（含密码）'
        say '  3) 修改密码'
        say '  4) 修改端口'
        say '  5) 查看版本'
        say '  6) 升级 sing-box'
        say '  7) 卸载节点'
        say '  0) 退出'
        while true; do
            read -r -p '请输入序号并按回车：' choice || return 0
            case "$choice" in
                1) status_node; return ;;
                2)
                    say '复制下面整行到 Surge 配置文件的 [Proxy] 段：'
                    show_node
                    say '此行包含密码，请勿公开分享。'
                    return ;;
                3)
                    say '修改后，Surge 中的旧密码会立即失效。'
                    change_password
                    return ;;
                4)
                    say '请先在服务商安全组放行准备使用的新端口。'
                    change_port
                    return ;;
                5) version_node; return ;;
                6) update_node; return ;;
                7)
                    uninstall_node
                    return ;;
                0) return 0 ;;
                *) say '请输入 0–7 中的一个数字。' ;;
            esac
        done
    else
        say '当前没有检测到由本脚本安装的节点。'
        if [[ -e /etc/sing-box || -e "$MARKER" ]]; then
            say '发现已有 sing-box 文件；安装前会检查并保护这些文件。'
        fi
        say '  1) 安装新节点'
        say '  2) 查看脚本版本'
        say '  0) 退出'
        while true; do
            read -r -p '请输入序号并按回车：' choice || return 0
            case "$choice" in
                1) install_node; return ;;
                2) version_node; return ;;
                0) return 0 ;;
                *) say '请输入 0、1 或 2。' ;;
            esac
        done
    fi
}

load_metadata() {
    [[ -f "$MARKER" && -f "$CONFIG" ]] || fail '未发现本脚本安装的节点。'
    DOMAIN="$(sed -n '1p' "$MARKER")"
    PORT="$(sed -n '2p' "$MARKER")"
    NODE_NAME="$(sed -n '3p' "$MARKER")"
    if [[ -z "$DOMAIN" || -z "$PORT" ]]; then
        DOMAIN="$(sed -n 's/.*"domain": \["\([^"]*\)"\].*/\1/p' "$CONFIG" | head -n 1)"
        PORT="$(sed -n 's/.*"listen_port": \([0-9]*\).*/\1/p' "$CONFIG" | head -n 1)"
    fi
    [[ -n "$DOMAIN" && "$PORT" =~ ^[0-9]+$ ]] || fail '安装记录不完整。'
    [[ -n "$NODE_NAME" ]] || NODE_NAME="AnyTLS-$(hostname -s)"
}

tls_ok() {
    local output
    output="$(timeout 6 openssl s_client \
        -connect "127.0.0.1:${PORT}" \
        -servername "$DOMAIN" \
        -verify_hostname "$DOMAIN" \
        -verify_return_error -brief </dev/null 2>&1 || true)"
    [[ "$output" == *'Verification: OK'* ]]
}

show_node() {
    need_root
    load_metadata
    local password line
    password="$(sed -n 's/.*"password": "\([^"]*\)".*/\1/p' "$CONFIG" | head -n 1)"
    [[ -n "$password" ]] || fail '无法从配置读取密码。'
    printf -v line '%s = anytls, %s, %s, password=%s, skip-cert-verify=false, tfo=true, sni=%s' \
        "$NODE_NAME" "$DOMAIN" "$PORT" "$password" "$DOMAIN"
    printf '%s\n' "$line" > "$SURGE_FILE"
    chmod 600 "$SURGE_FILE"
    printf '%s\n' "$line"
}

check_install_eligibility() {
    local saved_domain saved_port
    if [[ -f "$MARKER" && -f "$CONFIG" ]]; then
        saved_domain="$(sed -n '1p' "$MARKER")"
        saved_port="$(sed -n '2p' "$MARKER")"
        fail "检测到本脚本已配置节点 ${saved_domain:-未知域名}:${saved_port:-未知端口}。请运行 bash /root/anytls-setup.sh 打开管理菜单。"
    fi
    [[ ! -e "$MARKER" && ! -L "$MARKER" ]] || fail '检测到已有节点安装记录，但配置不完整；已停止以保护现有文件。'
    if command -v dpkg-query >/dev/null 2>&1 \
        && dpkg-query -W -f='${Status}' sing-box >/dev/null 2>&1; then
        fail '检测到已有 sing-box 软件包记录。请先检查 dpkg-query -W sing-box；本脚本不会覆盖现有安装。'
    fi
    [[ ! -e /etc/sing-box && ! -L /etc/sing-box ]] || fail '/etc/sing-box 已存在，为避免覆盖配置，已停止。'
    [[ ! -e /root/anytls-uninstall.sh && ! -L /root/anytls-uninstall.sh ]] || fail '/root/anytls-uninstall.sh 已存在，为避免覆盖，已停止。'
    [[ ! -e "$ACME_DIR" && ! -L "$ACME_DIR" ]] || fail "$ACME_DIR 已存在，为避免覆盖证书数据，已停止。"
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
    [[ $# -le 3 ]] || fail '用法：bash anytls-setup.sh install [域名] [端口] [节点名称]'
    check_install_eligibility
    DOMAIN="${1:-}"
    if [[ -z "$DOMAIN" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定域名。'
        while true; do
            read -r -p '请输入已解析到这台 VPS 的域名：' DOMAIN \
                || fail '已取消输入。'
            DOMAIN="${DOMAIN,,}"
            if valid_domain "$DOMAIN"; then break; fi
            say '域名格式不对。只输入域名，例如 sg.example.com，不要带 https:// 或路径。' >&2
        done
    fi
    DOMAIN="${DOMAIN,,}"
    local raw_port="${2:-}"
    NODE_NAME="${3:-AnyTLS-$(hostname -s)}"
    valid_domain "$DOMAIN" || fail '域名格式不对。只输入域名，例如 sg.example.com，不要带 https:// 或路径。'
    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定端口。'
        while true; do
            read -r -p '请输入 AnyTLS 节点 TCP 端口（1–65535，不能是 80）：' raw_port \
                || fail '已取消输入。'
            if [[ "$raw_port" =~ ^[0-9]{1,5}$ ]]; then
                PORT="$((10#$raw_port))"
                if (( PORT >= 1 && PORT <= 65535 && PORT != 80 )); then break; fi
            fi
            say '端口无效，请输入 1–65535 的数字；TCP 80 留给证书验证。' >&2
        done
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    PORT="$((10#$raw_port))"
    (( PORT >= 1 && PORT <= 65535 )) || fail '端口必须是 1–65535 的数字。'
    (( PORT != 80 )) || fail 'TCP 80 需要留给证书申请，请另选节点端口。'
    [[ "$NODE_NAME" != *','* && "$NODE_NAME" != *'='* && "$NODE_NAME" != *$'\n'* ]] \
        || fail '节点名称不能包含逗号、等号或换行。'
    say
    say "准备安装：$DOMAIN:$PORT"
    say "请先在服务商安全组放行 TCP 80 和 ${PORT}；现有 SSH 端口请保持开放。"
    say '[1/4] 检查系统和安装环境…'
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

    say '[2/4] 检查域名解析和本机端口…'
    local dns_ips public_ip
    dns_ips="$(getent ahostsv4 "$DOMAIN" | awk '$2 == "STREAM" {print $1}' | sort -u)" \
        || fail "无法解析域名 ${DOMAIN}。"
    [[ -n "$dns_ips" ]] || fail "域名 $DOMAIN 没有 IPv4 A 记录。"
    public_ip="$(curl -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)" \
        || fail '无法查到此 VPS 的公网 IPv4。'
    [[ "$dns_ips" == "$public_ip" ]] \
        || fail "域名 $DOMAIN 解析到 ${dns_ips//$'\n'/, }，但这台 VPS 的公网 IPv4 是 ${public_ip}。请修正 A 记录，生效后重试。"
    say "域名已指向这台 VPS：$public_ip"

    local listeners
    for check_port in 80 "$PORT"; do
        listeners="$(ss -H -ltn "sport = :$check_port")" || fail "无法检查本机 TCP ${check_port}。"
        [[ -z "$listeners" ]] || fail "本机 TCP $check_port 已被占用。"
    done

    local password
    trap finish_install EXIT
    save_manager
    TEMP_DIR="$(mktemp -d)"
    say '[3/4] 查询官方最新稳定版…'
    fetch_release_metadata latest "$arch"
    say "下载并校验 sing-box $RELEASE_VERSION ($arch)…"
    download_verified_package "$TEMP_DIR/sing-box.deb"
    say '安装包 SHA-256 校验通过。'
    INSTALL_STARTED=1
    dpkg -i "$TEMP_DIR/sing-box.deb"
    say '[4/4] 配置节点并申请证书…'
    systemctl stop sing-box >/dev/null 2>&1 || true
    install -d -m 755 /etc/sing-box
    printf '%s\n%s\n%s\n' "$DOMAIN" "$PORT" "$NODE_NAME" > "$MARKER"
    chmod 600 "$MARKER"
    getent passwd sing-box >/dev/null || fail '安装后未发现 sing-box 系统用户。'

    password="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ ${#password} -eq 48 ]] || fail '随机密码生成失败。'
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
    runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG"
    systemctl enable --now sing-box

    say '等待 Let’s Encrypt 签发证书并验证 TLS（最长约两分钟）…'
    local deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        if tls_ok; then
            cat > /root/anytls-uninstall.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '请以 root 身份运行。' >&2; exit 1; }
exec bash /root/anytls-setup.sh uninstall
EOF
            chmod 700 /root/anytls-uninstall.sh
            show_node >/dev/null
            INSTALL_COMMITTED=1
            say '完成：服务已运行，证书链和域名验证通过。'
            say 'Surge 节点（复制下一行到配置文件的 [Proxy] 段）：'
            cat -- "$SURGE_FILE"
            say "节点行已保存到 ${SURGE_FILE}；以后运行 bash /root/anytls-setup.sh show 可重新输出。"
            say "请在云安全组放行 TCP ${PORT}，并保持 TCP 80 开放以供证书续签。"
            say
            print_help
            return 0
        fi
        sleep 5
    done
    say "尚未验证到有效证书，本次安装将自动撤销。请检查域名解析及云安全组 TCP 80，再重新运行 install。" >&2
    say '查看签发错误：journalctl -u sing-box -n 60 --no-pager' >&2
    return 1
}

status_node() {
    need_root
    load_metadata
    local cert_expiry listeners service_ok=0 port_ok=0 tls_verified=0
    say "节点名称：$NODE_NAME"
    say "服务器：$DOMAIN:$PORT"
    if systemctl is-active --quiet sing-box; then
        say '服务状态：运行中'
        service_ok=1
    else
        say '服务状态：未运行'
    fi
    if listeners="$(ss -H -ltn "sport = :$PORT" 2>/dev/null)"; then
        if [[ -n "$listeners" ]]; then
            say "本机端口：TCP $PORT 已监听"
            port_ok=1
        else
            say "本机端口：TCP $PORT 未监听"
        fi
    else
        say '本机端口：无法检查，请运行 ss -lntp 查看。'
    fi
    if tls_ok; then
        say 'TLS 证书：验证通过'
        tls_verified=1
        cert_expiry="$(timeout 6 openssl s_client -connect "127.0.0.1:${PORT}" -servername "$DOMAIN" -showcerts \
            </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || true)"
        if [[ -n "$cert_expiry" ]]; then say "证书到期：${cert_expiry#notAfter=}"; fi
    else
        say 'TLS 证书：验证未通过'
    fi
    say '外部连接：请用 Surge 实测；本机检查无法确认云安全组是否放行。'
    say '证书续签：需保持 TCP 80 可从外部访问。'
    if (( service_ok == 0 || port_ok == 0 || tls_verified == 0 )); then
        say '排查日志：journalctl -u sing-box -n 30 --no-pager'
    fi
}

version_node() {
    local installed arch
    installed=''
    if [[ "$(dpkg-query -W -f='${Status}' sing-box 2>/dev/null || true)" == 'install ok installed' ]]; then
        installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
    fi
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
            say '有新版本。运行 bash /root/anytls-setup.sh update 手动升级。'
        else
            say '当前已是最新稳定版，或已安装版本更新。'
        fi
    fi
}

update_node() {
    need_root
    load_metadata
    local installed arch new_version old_version attempt verified=0 restored=1 recovery_dir
    installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null)" \
        || fail '无法读取已安装的 sing-box 版本。'
    [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "已安装版本格式不受支持：${installed}。请先检查软件包来源。"
    systemctl is-active --quiet sing-box && tls_ok \
        || fail '升级前服务或 TLS 验证未通过。请先运行 status 排查。'
    arch="$(dpkg --print-architecture)"
    ensure_dependencies
    TEMP_DIR="$(mktemp -d)"
    trap cleanup_temp EXIT

    say '查询官方最新稳定版…'
    fetch_release_metadata latest "$arch"
    new_version="$RELEASE_VERSION"
    if ! dpkg --compare-versions "$new_version" gt "$installed"; then
        say "当前版本 ${installed}；官方最新稳定版 ${new_version}。无需升级。"
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
        && systemctl restart sing-box; then
        for ((attempt = 1; attempt <= 5; attempt++)); do
            if systemctl is-active --quiet sing-box && tls_ok; then
                verified=1
                break
            fi
            sleep 2
        done
    fi
    if (( verified )); then
        say "升级完成：sing-box ${new_version}。节点域名、端口和密码未变。"
        return 0
    fi

    say '升级或验证失败，正在恢复原版本…' >&2
    cp -a -- "$TEMP_DIR/config.backup" "$CONFIG" || restored=0
    dpkg -i "$TEMP_DIR/old.deb" || restored=0
    systemctl daemon-reload || restored=0
    systemctl restart sing-box || restored=0
    if (( restored )) && systemctl is-active --quiet sing-box && tls_ok; then
        fail "升级失败，已恢复 sing-box ${old_version}；请检查 journalctl -u sing-box -n 60 --no-pager。"
    fi
    recovery_dir="$TEMP_DIR"
    TEMP_DIR=''
    fail "升级失败且未能验证恢复；原版安装包和配置备份保留在 ${recovery_dir}。请检查 systemctl status sing-box。"
}

change_password() {
    need_root
    load_metadata
    local old_password new_password backup
    old_password="$(sed -n 's/.*"password": "\([^"]*\)".*/\1/p' "$CONFIG" | head -n 1)"
    [[ "$old_password" =~ ^[0-9a-f]{48}$ ]] || fail '配置中的节点密码格式异常，已停止。'
    new_password="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ ${#new_password} -eq 48 ]] || fail '随机密码生成失败。'
    backup="$(mktemp /etc/sing-box/config.json.backup.XXXXXX)"
    if ! cp -a -- "$CONFIG" "$backup"; then
        rm -f -- "$backup"
        fail '配置备份失败，密码未修改。'
    fi
    if ! sed -i "s/\"password\": \"$old_password\"/\"password\": \"$new_password\"/" "$CONFIG" \
        || ! chown root:sing-box "$CONFIG" \
        || ! chmod 640 "$CONFIG" \
        || ! runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" \
        || ! systemctl restart sing-box \
        || ! systemctl is-active --quiet sing-box; then
        mv -f -- "$backup" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup}。"
        systemctl restart sing-box || true
        fail '修改或重启失败，已恢复原密码；请检查 systemctl status sing-box。'
    fi
    rm -f -- "$backup" || say "提醒：旧配置备份清理失败，请检查 ${backup}。" >&2
    say '密码已更换。将下面这一行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
    say "节点行也已保存到 ${SURGE_FILE}。请勿把含密码的节点行发到聊天中。"
}

change_port() {
    need_root
    [[ $# -le 1 ]] || fail '用法：bash anytls-setup.sh port [新端口]'
    load_metadata
    local old_port="$PORT" raw_port="${1:-}" new_port match_count backup_dir attempt verified=0 listeners
    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定新端口。'
        while true; do
            read -r -p "当前端口 ${old_port}；请输入新的 AnyTLS TCP 端口：" raw_port \
                || fail '已取消输入。'
            if [[ "$raw_port" =~ ^[0-9]{1,5}$ ]]; then
                new_port="$((10#$raw_port))"
                if (( new_port >= 1 && new_port <= 65535 && new_port != 80 && new_port != old_port )); then break; fi
            fi
            say "端口无效。请输入 1–65535 的数字，不能是 TCP 80 或当前端口 ${old_port}。" >&2
        done
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    new_port="$((10#$raw_port))"
    (( new_port >= 1 && new_port <= 65535 )) || fail '端口必须是 1–65535 的数字。'
    (( new_port != 80 )) || fail 'TCP 80 用于证书验证，请另选节点端口。'
    (( new_port != old_port )) || fail "新端口与当前端口相同：${old_port}。"
    listeners="$(ss -H -ltn "sport = :$new_port")" || fail "无法检查本机 TCP ${new_port}。"
    [[ -z "$listeners" ]] || fail "本机 TCP $new_port 已被占用。"
    match_count="$(grep -Fc -- "\"listen_port\": $old_port," "$CONFIG" || true)"
    [[ "$match_count" == 1 ]] || fail '配置中的当前端口不唯一或不存在，已停止以避免改错。'
    say "正在切换到 TCP ${new_port}；请确认已在服务商安全组放行该端口。"

    backup_dir="$(mktemp -d /etc/sing-box/.port-backup.XXXXXX)"
    if ! cp -a -- "$CONFIG" "$MARKER" "$backup_dir/"; then
        rm -rf -- "$backup_dir"
        fail '配置备份失败，端口未修改。'
    fi
    if ! sed -i "s/\"listen_port\": $old_port,/\"listen_port\": $new_port,/" "$CONFIG" \
        || ! chown root:sing-box "$CONFIG" \
        || ! chmod 640 "$CONFIG" \
        || ! printf '%s\n%s\n%s\n' "$DOMAIN" "$new_port" "$NODE_NAME" > "$MARKER" \
        || ! chmod 600 "$MARKER"; then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        rm -rf -- "$backup_dir"
        fail '修改端口文件失败，已恢复旧配置。'
    fi

    if runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG" && systemctl restart sing-box; then
        PORT="$new_port"
        for ((attempt = 1; attempt <= 5; attempt++)); do
            if systemctl is-active --quiet sing-box && tls_ok; then
                verified=1
                break
            fi
            sleep 2
        done
    fi
    if (( verified == 0 )); then
        cp -a -- "$backup_dir/config.json" "$CONFIG" || fail "恢复配置失败，原备份保留在 ${backup_dir}。"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER" || fail "恢复安装记录失败，原备份保留在 ${backup_dir}。"
        PORT="$old_port"
        systemctl restart sing-box || say '旧配置已恢复，但服务重启失败；请检查 systemctl status sing-box。' >&2
        rm -rf -- "$backup_dir" || say "提醒：旧配置备份清理失败，请检查 ${backup_dir}。" >&2
        fail "新端口 $new_port 启动或 TLS 验证失败，已恢复旧端口 ${old_port}；请查看 systemctl status sing-box。"
    fi
    rm -rf -- "$backup_dir" || say "提醒：旧配置备份清理失败，请检查 ${backup_dir}。" >&2
    say "已从 TCP $old_port 切换到 TCP ${new_port}。请将下面的新节点行替换到 Surge 的 [Proxy] 段："
    show_node
    say "确认 Surge 可连接后，再关闭云安全组中的旧端口 ${old_port}。TCP 80 仍需保持开放。"
    say '请勿把含密码的节点行发到聊天中。'
}

confirm_uninstall() {
    local answer
    while true; do
        read -r -p '确定卸载节点？[y/N]（直接回车默认 n）：' answer || { say '已取消卸载。'; return 1; }
        case "$answer" in
            y|Y) return 0 ;;
            n|N|'') say '已取消卸载。'; return 1 ;;
            *) say '请输入 y 或 n。' ;;
        esac
    done
}

uninstall_node() {
    need_root
    [[ -f "$MARKER" ]] || fail '未发现本脚本安装的节点，已停止以保护现有服务。'
    confirm_uninstall || return 0
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    apt-get purge -y sing-box
    rm -f -- "$CONFIG" "$MARKER" "$SURGE_FILE" /etc/sing-box/config.json.backup.*
    rm -rf -- /etc/sing-box/.port-backup.*
    rm -rf -- "$ACME_DIR"
    rmdir -- /etc/sing-box /var/lib/sing-box 2>/dev/null || true
    rm -f -- /root/anytls-uninstall.sh "$MANAGER"
    say '已移除本脚本安装的 sing-box、配置和证书数据。'
    if [[ -d /etc/sing-box || -d /var/lib/sing-box ]]; then
        say '部分目录还含有其他文件，已保留；可用 ls -la /etc/sing-box /var/lib/sing-box 检查。'
    fi
    say '云安全组规则、域名 DNS 记录和 Surge 节点如不再使用，请自行删除。'
}

case "${1:-}" in
    '') interactive_menu ;;
    help|-h|--help) print_help ;;
    install) shift; install_node "$@" ;;
    status) status_node ;;
    show) show_node ;;
    password) change_password ;;
    port) shift; change_port "$@" ;;
    version) version_node ;;
    update) update_node ;;
    uninstall) uninstall_node ;;
    *) print_help; exit 2 ;;
esac
