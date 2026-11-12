#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
# 载入管理函数，但不执行文件末尾的 main。
# shellcheck source=/dev/null
source <(sed '$d' install.sh)

test_root="$(command mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
CONFIG="$test_root/config.json"
MARKER="$test_root/.anytls-setup-owned"
SURGE_FILE="$test_root/surge.txt"

# 将系统、DNS 和 TLS 检查替换为本地模拟，避免触碰真实 VPS。
need_root() { :; }
getent() { printf '%s STREAM new.example.com\n' "$test_dns_ip"; }
public_ipv4() { printf '%s\n' '203.0.113.10'; }
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        restart)
            printf 'restart\n' >> "$test_root/restarts"
            if [[ "$test_restart_fail" == 1 && "$(rg -c '^restart$' "$test_root/restarts")" == 1 ]]; then return 1; fi
            ;;
        *) return 1 ;;
    esac
}
runuser() { return 0; }
wait_tls() {
    [[ "$test_cert_ok" == 1 && "$DOMAIN" == "$(jq -r '.certificate_providers[0].domain[0]' "$CONFIG")" ]]
}
mktemp() {
    if [[ "${1:-}" == -d && "${2:-}" == /etc/sing-box/.domain-backup.XXXXXX ]]; then
        command mktemp -d "$test_root/backup.XXXXXX"
    else
        command mktemp "$@"
    fi
}
edit_config() {
    local temporary
    temporary="$(command mktemp "$test_root/config.XXXXXX")"
    if jq "$@" "$CONFIG" > "$temporary"; then
        mv -f -- "$temporary" "$CONFIG"
    else
        rm -f -- "$temporary"
        return 1
    fi
}
setup_case() {
    local mode="${1:-domain}" ip=''
    [[ "$mode" == domain ]] || ip='203.0.113.9'
    jq -n '{
        certificate_providers: [{type: "acme", tag: "anytls-cert", domain: ["old.example.com"], provider: "letsencrypt", data_directory: "/var/lib/sing-box/acme"}],
        inbounds: [{type: "anytls", listen_port: 23456, tls: {certificate_provider: "anytls-cert"}, users: [{password: "test-secret"}]}]
    }' > "$CONFIG"
    ADDR_MODE="$mode"
    ADDR_IP="$ip"
    write_marker old.example.com 23456 test-node "$mode" "$ip"
    test_dns_ip='203.0.113.10'
    test_cert_ok=1
    test_restart_fail=0
    : > "$test_root/restarts"
}
assert_domain() {
    [[ "$(jq -r '.certificate_providers[0].domain[0]' "$CONFIG")" == "$1" ]]
    [[ "$(sed -n '1p' "$MARKER")" == "$1" ]]
}

setup_case
change_domain NEW.EXAMPLE.COM > "$test_root/output"
assert_domain new.example.com
[[ "$(rg -c '^restart$' "$test_root/restarts")" == 1 ]]
rg -q 'new.example.com, 23456.*sni=new.example.com' "$SURGE_FILE"

setup_case ip
change_domain new.example.com > "$test_root/output"
assert_domain new.example.com
rg -q '203.0.113.10, 23456.*sni=new.example.com' "$SURGE_FILE"
[[ "$(sed -n '4p' "$MARKER")" == ip ]]
[[ "$(sed -n '5p' "$MARKER")" == '203.0.113.10' ]]

setup_case
test_dns_ip='203.0.113.11'
if (change_domain new.example.com > "$test_root/output" 2>&1); then
    printf '%s\n' 'DNS 不匹配时竟然修改成功' >&2
    exit 1
fi
assert_domain old.example.com
[[ ! -s "$test_root/restarts" ]]

setup_case
test_cert_ok=0
if (change_domain new.example.com > "$test_root/output" 2>&1); then
    printf '%s\n' 'TLS 验证失败时竟然修改成功' >&2
    exit 1
fi
assert_domain old.example.com
[[ "$(rg -c '^restart$' "$test_root/restarts")" == 2 ]]

setup_case
test_restart_fail=1
if (change_domain new.example.com > "$test_root/output" 2>&1); then
    printf '%s\n' '服务重启失败时竟然修改成功' >&2
    exit 1
fi
assert_domain old.example.com
[[ "$(rg -c '^restart$' "$test_root/restarts")" == 2 ]]

printf '%s\n' '域名更换、IP 地址模式、DNS 拒绝、证书失败与重启失败回滚测试通过。'
