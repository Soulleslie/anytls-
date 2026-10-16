# AnyTLS 节点管理脚本

在 Debian 或 Ubuntu VPS 上安装 AnyTLS 节点，安装完成后输出可直接放入 Surge `[Proxy]` 段的节点行。脚本提供中文菜单，也支持查看状态、修改密码和端口、卸载节点。

适用环境：使用 systemd 的 Debian/Ubuntu、`amd64` 或 `arm64` 架构，并拥有公网 IPv4。以下命令均在 VPS 上以 root 身份运行。

## 安装前准备

1. 准备自己的域名或子域名，将 **A 记录**指向这台 VPS 的公网 IPv4。输入域名时只填 `sg.example.com` 这样的域名，不要加 `https://`。
2. 在云服务商安全组中放行 **TCP 80** 和你准备使用的 **AnyTLS TCP 端口**；如果 VPS 还启用了系统防火墙，也要放行这两个端口。保持现有 SSH 端口开放。
3. 确保 TCP 80 和准备使用的节点端口没有被 VPS 上的其他程序占用。TCP 80 供证书申请与续签使用；节点端口由你安装时输入。

脚本检测到已有 sing-box 软件包或 `/etc/sing-box` 配置时会停止，避免覆盖现有服务。

## 安装

在 VPS 上依次运行以下命令：

```bash
curl -fL -o /root/anytls-setup.sh 'https://github.com/Soulleslie/anytls-/raw/refs/heads/main/install.sh'
test -s /root/anytls-setup.sh
bash -n /root/anytls-setup.sh
bash /root/anytls-setup.sh
```

确认每行没有报错，再运行下一行。脚本会打开中文菜单；输入 `1` 安装，再按提示输入域名和端口。也可以直接运行 `bash /root/anytls-setup.sh install`，同样会提示输入域名和端口。

脚本会检查系统、域名解析和本机端口，从 sing-box 官方 GitHub 获取**最新稳定版**（不选预发布版），校验安装包 SHA-256，配置 sing-box，并等待证书签发。域名或端口格式输错时会重新提示。

不要使用 `curl | bash`：安装需要从终端读取输入，管理脚本也需要保留在 VPS 上。如果下载时提示 `curl: command not found`，先运行 `apt-get update && apt-get install -y curl ca-certificates`。

## 将节点加入 Surge

安装成功后，脚本会输出一整行节点配置。将这行复制到 Surge 配置文件的 `[Proxy]` 段。下面只是格式示例，实际域名、端口、密码以脚本输出为准：

```ini
AnyTLS-SG = anytls, sg.example.com, 12003, password=你的实际密码, skip-cert-verify=false, tfo=true, sni=sg.example.com
```

以后可运行 `bash /root/anytls-setup.sh show` 再次查看。**节点行包含密码，请勿发布到 GitHub、聊天或截图中。**

## 日常管理

运行 `bash /root/anytls-setup.sh` 可打开中文菜单。也可直接运行：

| 命令 | 作用 |
| --- | --- |
| `bash /root/anytls-setup.sh status` | 查看服务、监听端口、本机 TLS 验证和证书到期时间 |
| `bash /root/anytls-setup.sh show` | 输出 Surge 节点行，**包含密码** |
| `bash /root/anytls-setup.sh password` | 生成新密码；随后替换 Surge 中的旧节点行 |
| `bash /root/anytls-setup.sh port` | 修改节点端口；先放行新端口，完成后更新 Surge |
| `bash /root/anytls-setup.sh version` | 查看已安装版本及官方最新稳定版 |
| `bash /root/anytls-setup.sh update` | 手动升级 sing-box；升级后检查服务和 TLS |
| `bash /root/anytls-uninstall.sh` | 卸载本脚本安装的节点 |

**已安装的节点不会自动升级 sing-box。**运行 `update` 时，脚本先下载并校验新版和当前版本的官方安装包，检查新版是否接受现有配置；升级后验证服务与 TLS，失败时尝试恢复旧版。节点域名、端口和密码不随程序升级改变。

如果 VPS 上仍是以前保存的旧管理脚本，请先在该 VPS 上更新脚本，再手动升级：

```bash
curl -fL -o /root/anytls-setup.new.sh 'https://github.com/Soulleslie/anytls-/raw/refs/heads/main/install.sh'
test -s /root/anytls-setup.new.sh
bash -n /root/anytls-setup.new.sh
install -m 700 /root/anytls-setup.new.sh /root/anytls-setup.sh
bash /root/anytls-setup.sh version
bash /root/anytls-setup.sh update
```

证书由 sing-box 的 ACME 配置自动续签，与程序版本升级是两回事。请保持 sing-box 服务运行、域名解析正确，并让 TCP 80 能从外部访问。`status` 在 VPS 本机检查服务与 TLS；还需在 Surge 中测试外部连接。

## 卸载范围

卸载命令会停止并移除本脚本安装的 sing-box、节点配置、证书数据、保存的 Surge 节点行和管理脚本。它不会修改域名 DNS 记录、云安全组规则、系统防火墙规则或 Surge 中的配置。无论从中文菜单还是直接运行卸载命令，脚本都会提示 `确定卸载节点？[y/N]`：输入 `y` 并按回车才会卸载；输入 `n` 或直接按回车都会取消。

## 常见问题

- **证书签发失败**：检查域名 A 记录是否指向本机公网 IPv4，以及 TCP 80 是否能从公网访问。查看日志：`journalctl -u sing-box -n 60 --no-pager`。修正后重新运行安装命令。
- **`status` 正常但 Surge 连不上**：检查安全组和系统防火墙是否放行节点端口，并确认 Surge 中的域名、端口和密码与脚本输出一致。
- **修改密码后旧节点失效**：运行 `show`，将新输出的整行节点配置替换到 Surge。
- **修改端口后连不上**：确认新端口已放行，运行 `show` 更新 Surge。确认新端口可连接后，再关闭旧端口的安全组规则。

脚本从官方 GitHub Release API 读取稳定版和安装包 SHA-256；如果无法取得版本、安装包或校验值，会停止安装或升级。安装失败时，脚本会尝试撤销本次创建的节点文件和服务；为补齐依赖而安装的基础工具会保留。
