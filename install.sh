#!/usr/bin/env bash
# AnyTLS for Debian/Ubuntu VPSs with a public IPv4 address.
# Usage: bash anytls-setup.sh install [domain] [port] [node_name]
#        bash anytls-setup.sh status|show|password|port [new_port]|uninstall|help
set -Eeuo pipefail
umask 077

DOMAIN=''
PORT=''
NODE_NAME=''
SING_BOX_VERSION='1.14.3'
CONFIG='/etc/sing-box/config.json'
MARKER='/etc/sing-box/.anytls-setup-owned'
ACME_DIR='/var/lib/sing-box/acme'
SURGE_FILE='/root/anytls-surge.txt'

say() { printf '%s\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || fail '请以 root 身份运行：bash /root/anytls-setup.sh ...'; }
need_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

print_help() {
    cat <<'EOF'
AnyTLS 管理命令（在 VPS 上以 root 身份运行）：
  bash /root/anytls-setup.sh install    # 新 VPS 安装；按提示输入域名和端口
  bash /root/anytls-setup.sh status     # 检查服务和证书
  bash /root/anytls-setup.sh show       # 查看 Surge 节点行（含密码）
  bash /root/anytls-setup.sh password   # 生成新密码；需更新 Surge 节点行
  bash /root/anytls-setup.sh port       # 修改节点端口；需先放行新端口并更新 Surge
  bash /root/anytls-uninstall.sh        # 卸载本脚本安装的节点
  bash /root/anytls-setup.sh help       # 再次显示本帮助
EOF
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

install_node() {
    need_root
    [[ $# -le 3 ]] || fail '用法：bash anytls-setup.sh install [域名] [端口] [节点名称]'
    DOMAIN="${1:-}"
    if [[ -z "$DOMAIN" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定域名。'
        read -r -p '请输入已解析到这台 VPS 的域名：' DOMAIN \
            || fail '未读到域名输入。'
    fi
    DOMAIN="${DOMAIN,,}"
    local raw_port="${2:-}"
    NODE_NAME="${3:-AnyTLS-$(hostname -s)}"
    [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ && "$DOMAIN" == *.* && "$DOMAIN" != .* && "$DOMAIN" != *. && "$DOMAIN" != *..* ]] \
        || fail '请输入有效的英文域名。'
    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定端口。'
        read -r -p '请输入 AnyTLS 节点 TCP 端口（1–65535，不能是 80）：' raw_port \
            || fail '未读到端口输入。'
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    PORT="$((10#$raw_port))"
    (( PORT >= 1 && PORT <= 65535 )) || fail '端口必须是 1–65535 的数字。'
    (( PORT != 80 )) || fail 'TCP 80 需要留给证书申请，请另选节点端口。'
    [[ "$NODE_NAME" != *','* && "$NODE_NAME" != *'='* && "$NODE_NAME" != *$'\n'* ]] \
        || fail '节点名称不能包含逗号、等号或换行。'
    for command_name in curl dpkg dpkg-query getent ss awk sort od tr systemctl openssl timeout runuser; do
        need_command "$command_name"
    done
    [[ -r /etc/os-release ]] || fail '无法识别系统。'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || fail '这个脚本仅支持 Debian 和 Ubuntu。'
    local arch
    arch="$(dpkg --print-architecture)"
    [[ "$arch" == 'arm64' || "$arch" == 'amd64' ]] || fail "不支持的架构：$arch"

    [[ ! -e "$MARKER" ]] || fail '已由本脚本安装；运行 status 或 show 查看。'
    if dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
        fail '检测到已有 sing-box 安装，为避免覆盖配置，已停止。'
    fi
    [[ ! -e /etc/sing-box ]] || fail '/etc/sing-box 已存在，为避免覆盖配置，已停止。'

    local dns_ips public_ip
    dns_ips="$(getent ahostsv4 "$DOMAIN" | awk '$2 == "STREAM" {print $1}' | sort -u)" \
        || fail "无法解析域名 $DOMAIN。"
    [[ -n "$dns_ips" ]] || fail "域名 $DOMAIN 没有 IPv4 A 记录。"
    public_ip="$(curl -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)" \
        || fail '无法查到此 VPS 的公网 IPv4。'
    printf '%s\n' "$dns_ips" | grep -Fxq "$public_ip" \
        || fail "域名 $DOMAIN 解析到 ${dns_ips//$'\n'/, }，当前机器公网 IP 是 $public_ip。"

    for check_port in 80 "$PORT"; do
        if [[ -n "$(ss -H -ltn "sport = :$check_port")" ]]; then
            fail "本机 TCP $check_port 已被占用。"
        fi
    done

    local package_url password
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
    package_url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box_${SING_BOX_VERSION}_linux_${arch}.deb"
    say "下载 sing-box $SING_BOX_VERSION ($arch)…"
    curl -fL --retry 3 --connect-timeout 10 -o "$TEMP_DIR/sing-box.deb" "$package_url"
    dpkg -i "$TEMP_DIR/sing-box.deb"
    systemctl stop sing-box >/dev/null 2>&1 || true
    install -d -m 755 /etc/sing-box
    printf '%s\n%s\n%s\n' "$DOMAIN" "$PORT" "$NODE_NAME" > "$MARKER"
    chmod 600 "$MARKER"
    cat > /root/anytls-uninstall.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '请以 root 身份运行。' >&2; exit 1; }
exec bash /root/anytls-setup.sh uninstall
EOF
    chmod 700 /root/anytls-uninstall.sh
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
    local attempt
    for ((attempt = 1; attempt <= 24; attempt++)); do
        if tls_ok; then
            say '完成：服务已运行，证书链和域名验证通过。'
            say 'Surge 节点（复制下一行到配置文件的 [Proxy] 段）：'
            show_node
            say "节点行已保存到 $SURGE_FILE；以后运行 bash /root/anytls-setup.sh show 可重新输出。"
            say "请在云安全组放行 TCP $PORT，并保持 TCP 80 开放以供证书续签。"
            say
            print_help
            return 0
        fi
        sleep 5
    done
    say "服务已安装，但尚未验证到有效证书。请确认云安全组放行 TCP 80 和 $PORT，然后查看日志："
    say 'journalctl -u sing-box -n 60 --no-pager'
    say '修正外部端口后执行：systemctl restart sing-box'
    say '需要清理时执行：bash /root/anytls-uninstall.sh'
    return 1
}

status_node() {
    need_root
    load_metadata
    systemctl --no-pager --full status sing-box || true
    say
    ss -lntp "sport = :$PORT" || true
    if tls_ok; then say 'TLS 证书验证：通过'; else say 'TLS 证书验证：未通过'; fi
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
    cp -a -- "$CONFIG" "$backup"
    sed -i "s/\"password\": \"$old_password\"/\"password\": \"$new_password\"/" "$CONFIG"
    chown root:sing-box "$CONFIG"
    chmod 640 "$CONFIG"
    if ! runuser -u sing-box -- /usr/bin/sing-box check -c "$CONFIG"; then
        mv -f -- "$backup" "$CONFIG"
        fail '新配置检查失败，已恢复原密码。'
    fi
    if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
        mv -f -- "$backup" "$CONFIG"
        systemctl restart sing-box || true
        fail '重启失败，已恢复原配置；请检查 systemctl status sing-box。'
    fi
    rm -f -- "$backup"
    say '密码已更换。将下面这一行替换到 Surge 配置文件的 [Proxy] 段：'
    show_node
    say "节点行也已保存到 $SURGE_FILE。请勿把含密码的节点行发到聊天中。"
}

change_port() {
    need_root
    [[ $# -le 1 ]] || fail '用法：bash anytls-setup.sh port [新端口]'
    load_metadata
    local old_port="$PORT" raw_port="${1:-}" new_port match_count backup_dir attempt verified=0
    if [[ -z "$raw_port" ]]; then
        [[ -t 0 ]] || fail '非交互运行时，请在命令中指定新端口。'
        read -r -p "当前端口 $old_port；请输入新的 AnyTLS TCP 端口：" raw_port \
            || fail '未读到端口输入。'
    fi
    [[ "$raw_port" =~ ^[0-9]{1,5}$ ]] || fail '端口必须是 1–65535 的数字。'
    new_port="$((10#$raw_port))"
    (( new_port >= 1 && new_port <= 65535 )) || fail '端口必须是 1–65535 的数字。'
    (( new_port != 80 )) || fail 'TCP 80 用于证书验证，请另选节点端口。'
    (( new_port != old_port )) || fail "新端口与当前端口相同：$old_port。"
    [[ -z "$(ss -H -ltn "sport = :$new_port")" ]] || fail "本机 TCP $new_port 已被占用。"
    match_count="$(grep -Fc -- "\"listen_port\": $old_port," "$CONFIG" || true)"
    [[ "$match_count" == 1 ]] || fail '配置中的当前端口不唯一或不存在，已停止以避免改错。'
    say "正在切换到 TCP $new_port；请确认已在服务商安全组放行该端口。"

    backup_dir="$(mktemp -d /etc/sing-box/.port-backup.XXXXXX)"
    cp -a -- "$CONFIG" "$MARKER" "$backup_dir/"
    sed -i "s/\"listen_port\": $old_port,/\"listen_port\": $new_port,/" "$CONFIG"
    chown root:sing-box "$CONFIG"
    chmod 640 "$CONFIG"
    printf '%s\n%s\n%s\n' "$DOMAIN" "$new_port" "$NODE_NAME" > "$MARKER"
    chmod 600 "$MARKER"

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
        cp -a -- "$backup_dir/config.json" "$CONFIG"
        cp -a -- "$backup_dir/.anytls-setup-owned" "$MARKER"
        rm -rf -- "$backup_dir"
        PORT="$old_port"
        systemctl restart sing-box || true
        fail "新端口 $new_port 启动或 TLS 验证失败，已恢复旧端口 $old_port；请查看 systemctl status sing-box。"
    fi
    rm -rf -- "$backup_dir"
    say "已从 TCP $old_port 切换到 TCP $new_port。请将下面的新节点行替换到 Surge 的 [Proxy] 段："
    show_node
    say "确认 Surge 可连接后，再关闭云安全组中的旧端口 $old_port。TCP 80 仍需保持开放。"
    say '请勿把含密码的节点行发到聊天中。'
}

uninstall_node() {
    need_root
    [[ -f "$MARKER" ]] || fail '未发现本脚本安装的节点，已停止以保护现有服务。'
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    apt-get purge -y sing-box
    rm -f -- "$CONFIG" "$MARKER" "$SURGE_FILE"
    rm -rf -- "$ACME_DIR"
    rmdir -- /etc/sing-box /var/lib/sing-box 2>/dev/null || true
    rm -f -- /root/anytls-uninstall.sh /root/anytls-setup.sh
    say '已移除本脚本安装的 sing-box、配置和证书数据。'
    say '云安全组规则、域名 DNS 记录和 Surge 节点如不再使用，请自行删除。'
}

case "${1:-}" in
    ''|help|-h|--help) print_help ;;
    install) shift; install_node "$@" ;;
    status) status_node ;;
    show) show_node ;;
    password) change_password ;;
    port) shift; change_port "$@" ;;
    uninstall) uninstall_node ;;
    *) print_help; exit 2 ;;
esac
