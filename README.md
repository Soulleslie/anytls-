# AnyTLS 一键管理脚本

适用于使用 systemd 的 Debian、Ubuntu VPS（amd64 或 arm64）。安装时自行输入域名和 AnyTLS TCP 端口；sing-box 使用 Let's Encrypt ACME 证书，安装完成后输出可放进 Surge `[Proxy]` 段的节点行。

## 安装前

1. 将域名的 A 记录指向这台 VPS 的公网 IPv4。
2. 在服务商安全组放行 TCP 80 和准备使用的节点端口，保留现有 SSH 端口。TCP 80 供证书申请及续签使用。
3. 使用 root 登录 VPS。已有 sing-box 安装或 `/etc/sing-box` 配置时，脚本会停止，避免覆盖。

## 下载并安装

将脚本保存成 VPS 上的普通文件，再运行：

```bash
curl -fL -o /root/anytls-setup.sh '这里换成你 GitHub 仓库中 install.sh 的 Raw 链接'
bash -n /root/anytls-setup.sh
bash /root/anytls-setup.sh install
```

按提示输入域名和端口；输错格式时会重新提示。脚本会依次显示系统、域名、安装包和证书的处理进度。不要使用 `curl | bash`：安装需要从终端读取输入，且管理脚本需要保留在 VPS 上。

## 常用命令

```bash
bash /root/anytls-setup.sh           # 打开中文菜单，按数字选择操作
bash /root/anytls-setup.sh status    # 查看服务、本机 TLS 验证和证书到期时间
bash /root/anytls-setup.sh show      # 输出 Surge 节点行，包含密码
bash /root/anytls-setup.sh password  # 生成新密码，随后更新 Surge 节点
bash /root/anytls-setup.sh port      # 先放行新端口，再修改端口并更新 Surge 节点
bash /root/anytls-setup.sh version   # 查看已安装版本和脚本指定版本
bash /root/anytls-uninstall.sh       # 卸载脚本创建的节点
```

`status` 在 VPS 本机检查 TLS，不能代替从外部测试节点端口。`show`、`password` 和 `port` 会显示含密码的节点行，请勿公开粘贴。卸载不会修改云安全组、DNS 记录或 Surge 配置。

本版指定 sing-box 1.14.3，并校验官方发布包的 SHA-256。更新 sing-box 版本时，需要同时更新脚本中的版本号及对应架构的官方 SHA-256。安装中途失败时，脚本会尝试撤销新装的 sing-box 和节点文件；为补齐依赖而安装的基础工具会保留。
# anytls-
