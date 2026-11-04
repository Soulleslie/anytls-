# AnyTLS 节点管理脚本

在 Debian 或 Ubuntu VPS 上一键安装 AnyTLS 节点，安装完成后输出可直接放入 Surge `[Proxy]` 段的节点行。脚本提供中文管理菜单，可以启动、停止、重启服务，修改密码、端口和节点名称，升级 sing-box，更新脚本本身，以及卸载并清理残留。

适用环境：使用 systemd 的 Debian/Ubuntu、`amd64` 或 `arm64` 架构，并拥有公网 IPv4。以下命令均在 VPS 上以 root 身份运行。

## 安装前准备

1. 准备自己的域名或子域名，将 **A 记录**指向这台 VPS 的公网 IPv4。输入域名时只填 `sg.example.com` 这样的域名，不要加 `https://`。
2. 在云服务商安全组中放行 **TCP 80** 和你准备使用的 **AnyTLS TCP 端口**；如果 VPS 还启用了系统防火墙，也要放行这两个端口。保持现有 SSH 端口开放。
3. 确保 TCP 80 和准备使用的节点端口没有被 VPS 上的其他程序占用。TCP 80 供证书申请与续签使用。

脚本检测到已有 sing-box 软件包或 `/etc/sing-box` 配置时会停止，避免覆盖现有服务。

## 一键安装

复制下面一整行，在 VPS 上运行：

```bash
wget -O /root/anytls-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/install.sh && chmod +x /root/anytls-setup.sh && /root/anytls-setup.sh
```

没有 `wget` 时可以用 `curl`：

```bash
curl -fL -o /root/anytls-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/install.sh && chmod +x /root/anytls-setup.sh && /root/anytls-setup.sh
```

脚本会打开中文菜单，输入 `1` 安装，然后按提示操作：

1. 输入已解析到这台 VPS 的域名。
2. 输入节点端口；直接回车会随机选一个 20000–60000 之间未被占用的端口。
3. 输入节点名称，即 Surge 中显示的名字；直接回车使用 `AnyTLS-主机名`。
4. 选择节点行的服务器地址：`1` 域名（默认），`2` IP。选 IP 时 `sni` 仍是域名，证书校验不受影响。
5. 选择是否开启 TCP Fast Open，直接回车不开启。
6. 确认安装信息，并确认安全组已放行端口后，输入 `y` 开始安装。

脚本会检查系统、域名解析和本机端口，从 sing-box 官方 GitHub 获取**最新稳定版**（不选预发布版），校验安装包 SHA-256，配置 sing-box，并等待证书签发（会显示已等待的秒数）。任何一步失败，脚本都会撤销本次安装。

安装完成后会创建快捷命令 `anytls`，以后直接输入 `anytls` 就能打开管理菜单。

不要使用 `curl | bash`：安装需要从终端读取输入，管理脚本也需要保留在 VPS 上。如果粘贴命令后出现 `[200~` 和 `command not found`，先按 Ctrl+C 清空当前行，再重新粘贴。

## 将节点加入 Surge

安装成功后，脚本会输出一整行节点配置。将这行复制到 Surge 配置文件的 `[Proxy]` 段。下面只是格式示例，实际域名、端口、密码以脚本输出为准：

```ini
AnyTLS-SG = anytls, sg.example.com, 12003, password=你的实际密码, skip-cert-verify=false, tfo=false, sni=sg.example.com
```

以后可运行 `anytls show` 再次查看。**节点行包含密码，请勿发布到 GitHub、聊天或截图中。**

## 管理菜单

运行 `anytls`（或 `bash /root/anytls-setup.sh`）打开菜单：

```
==============================
 AnyTLS 节点管理脚本 [v2.1.0]
==============================
  0. 更新脚本
——————————————————————————————
  1. 安装节点
  2. 卸载节点（含清理残留）
  3. 升级 sing-box
——————————————————————————————
  4. 启动服务
  5. 停止服务
  6. 重启服务
——————————————————————————————
  7. 修改密码
  8. 修改端口
  9. 修改节点名称
 10. 切换服务器地址（域名/IP）
 11. 开关 TCP Fast Open
——————————————————————————————
 12. 查看节点行
 13. 查看运行状态
 14. 查看运行日志
——————————————————————————————
 00. 退出
==============================
 当前状态：● 已安装 [sing-box 1.14.4]  ● 运行中
 当前节点：AnyTLS-SG（sg.example.com:12003）
```

每项操作完成后按回车返回菜单。sing-box 有新版本时，第 3 项后面会显示“可升级”。也可以直接带序号运行，例如 `anytls 13` 查看运行状态。

## 命令行

| 命令 | 作用 |
| --- | --- |
| `anytls` | 打开管理菜单 |
| `anytls status` | 查看服务、端口、TLS 验证、证书剩余天数、运行时长、sing-box 版本、节点地址模式和 TFO 状态 |
| `anytls show` | 输出 Surge 节点行，**包含密码** |
| `anytls password` | 生成新密码；随后替换 Surge 中的旧节点行 |
| `anytls port [新端口]` | 修改节点端口；先放行新端口，完成后更新 Surge |
| `anytls rename [新名称]` | 修改节点名称；无需重启服务，完成后更新 Surge |
| `anytls addr [ip\|domain]` | 节点行服务器地址改用 IP 或域名；无需重启服务，完成后更新 Surge |
| `anytls tfo [on\|off]` | 开关 TCP Fast Open；完成后更新 Surge |
| `anytls start` / `stop` / `restart` | 启动、停止、重启服务 |
| `anytls log` | 查看最近 50 行日志；`anytls log -f` 实时查看，`anytls log 200` 查看 200 行 |
| `anytls version` | 查看已安装版本及官方最新稳定版 |
| `anytls update` | 手动升级 sing-box；升级后检查服务和 TLS |
| `anytls self-update` | 更新本管理脚本 |
| `anytls uninstall` | 卸载节点并清理残留 |
| `anytls help` | 显示全部命令 |

如果 `anytls` 命令不存在，可用 `bash /root/anytls-setup.sh` 代替，例如 `bash /root/anytls-setup.sh status`。

## 更新

- **更新管理脚本**：菜单输入 `0`，或运行 `anytls self-update`。脚本会下载最新版并检查语法，确认后替换旧脚本，再自动打开新版菜单。节点配置、密码和端口不受影响。
- **升级 sing-box**：菜单输入 `3`，或运行 `anytls update`。**已安装的节点不会自动升级 sing-box。**升级时，脚本先下载并校验新版和当前版本的官方安装包，检查新版是否接受现有配置；升级后验证服务与 TLS，失败时自动恢复旧版。

如果 VPS 上是 v2.0.0 之前的旧脚本（没有“更新脚本”选项），先运行一次下面的命令换成新版：

```bash
wget -O /root/anytls-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/install.sh && chmod +x /root/anytls-setup.sh && /root/anytls-setup.sh
```

已经安装的节点会直接进入管理菜单，不会重新安装，也不会改动现有节点。之后就可以用菜单里的“更新脚本”了。

## 服务器地址：域名或 IP

节点行开头的服务器地址可以用域名，也可以用 IP；`sni` 始终是域名，所以加密和证书校验都不受影响。

- **域名（默认）**：VPS 换 IP 后只需修改 DNS 解析，Surge 不用改。
- **IP**：连接时少一次 DNS 查询，也不受 DNS 污染影响；但 VPS 换 IP 后要运行 `anytls addr ip` 并更新 Surge。`anytls status` 会在本机公网 IP 变化时提醒。

无论用哪种，域名的 A 记录都不能删，证书续期需要它。

## TCP Fast Open

TFO 需要 sing-box 入站和内核参数 `net.ipv4.tcp_fastopen` 同时开启才生效。`anytls tfo on` 会两处一起开启，并把内核设置写入 `/etc/sysctl.d/99-anytls-tfo.conf`（重启后保留）；`anytls tfo off` 或卸载时会恢复开启前的内核参数。

节点行里的 `tfo=` 跟随服务端实际状态：开启时为 `tfo=true`，否则为 `tfo=false`。TFO 只能省掉新建连接时的 1 次往返，而 AnyTLS 会复用连接，收益很小；部分网络会丢弃握手时携带数据的包，所以默认不开启。

## 证书续期

证书由 sing-box 的 ACME 配置自动续期，到期前约 30 天自动更新，无需手动操作。需要满足三个条件：sing-box 服务保持运行、域名 A 记录指向这台 VPS、TCP 80 能从外网访问。`anytls status` 会显示证书还剩多少天；剩余天数偏少时会提示检查 TCP 80。

## 卸载

菜单输入 `2`，或运行 `anytls uninstall`。脚本会提示 `确定卸载节点并清理全部残留？[y/N]`：输入 `y` 并按回车才会卸载，直接回车会取消。

卸载会清理：

- sing-box 程序、系统服务和 `sing-box` 系统用户
- `/etc/sing-box`（配置、安装记录、备份）和 `/var/lib/sing-box`（证书、缓存）
- `/root/anytls-surge.txt`、`/root/anytls-uninstall.sh`、`/root/anytls-setup.sh` 和更新时留下的临时文件
- 快捷命令 `/usr/local/bin/anytls`
- TCP Fast Open 设置 `/etc/sysctl.d/99-anytls-tfo.conf`（如有），内核参数恢复为开启前的值

卸载不会修改域名 DNS 记录、云安全组规则、系统防火墙规则或 Surge 中的配置，这些不再使用时请自行删除。安装时为补齐依赖而安装的基础工具（如 `jq`、`curl`）会保留。

## 常见问题

- **证书签发失败**：检查域名 A 记录是否指向本机公网 IPv4，以及 TCP 80 是否能从公网访问。查看日志：`anytls log`。修正后重新安装。
- **`status` 正常但 Surge 连不上**：检查安全组和系统防火墙是否放行节点端口，并确认 Surge 中的域名、端口和密码与脚本输出一致。
- **修改密码、端口、名称、地址或 TFO 后旧节点失效**：运行 `anytls show`，将新输出的整行节点配置替换到 Surge。
- **修改端口后连不上**：确认新端口已放行。确认新端口可连接后，再关闭旧端口的安全组规则。

脚本从官方 GitHub Release API 读取稳定版和安装包 SHA-256；如果无法取得版本、安装包或校验值，会停止安装或升级。
