# VLESS + REALITY + Vision 节点管理脚本

这是参照 [Soulleslie/anytls-](https://github.com/Soulleslie/anytls-) 的交互和运维思路编写的 Xray-core 管理脚本，用于在 Debian/Ubuntu VPS 上安装 **VLESS + REALITY + XTLS Vision**。

与原 AnyTLS 脚本的主要区别：REALITY 不申请 TLS 证书，因此不要求自有域名，也不需要开放 TCP 80。安装时需要选择一个支持 TLS 1.3、可从 VPS 正常访问的伪装站点域名（SNI）。

## 功能

- 从 `XTLS/Xray-core` 官方 GitHub Release 获取最新稳定版
- 使用 GitHub Release 的 SHA-256 digest 校验安装包
- 支持 `amd64` 和 `arm64` 的 Debian/Ubuntu
- 安装前检测现有 Xray 文件和服务，不覆盖已有配置
- 自动生成 UUID、X25519 密钥和 Short ID
- 输出标准 `vless://` 客户端导入链接
- 中文菜单管理启动、停止、重启、日志和状态
- 修改端口、SNI、UUID、REALITY 密钥和节点名称
- 升级失败、配置修改失败和首次安装失败时回滚
- 卸载时只清理本脚本拥有的文件

## 安装前准备

1. 使用带公网 IPv4 的 Debian 或 Ubuntu VPS，以 root 身份执行。
2. 在云服务商安全组中放行准备使用的 TCP 端口。若使用系统防火墙，也需放行该端口。
3. 默认优先使用 TCP 443；若已占用，脚本会给出随机高位端口。
4. 准备一个支持 TLS 1.3 的伪装站点域名。直接回车时使用 `www.amazon.com`，脚本会在安装前实际验证。更理想的选择是与你的 VPS 网络位置相近、长期稳定且不使用 Cloudflare CDN 的大型站点。

## 一键安装

使用下面的方式下载并运行。不要使用 `curl | bash`，因为脚本需要从终端读取安装参数，并会作为管理脚本保留在 VPS 上。

```bash
wget -O /root/vless-reality-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/vless-reality-vision/install.sh && chmod +x /root/vless-reality-setup.sh && /root/vless-reality-setup.sh
```

使用 curl：

```bash
curl -fL -o /root/vless-reality-setup.sh https://raw.githubusercontent.com/Soulleslie/anytls-/main/vless-reality-vision/install.sh && chmod +x /root/vless-reality-setup.sh && /root/vless-reality-setup.sh
```

脚本安装完成后会创建快捷命令：

```bash
vless-reality
```

## 非交互安装

参数顺序为端口、伪装域名、节点名称：

```bash
/root/vless-reality-setup.sh install 443 www.amazon.com Reality-SG
```

## 常用命令

```text
vless-reality show                 显示 vless:// 导入链接
vless-reality status               检查服务、配置、端口和伪装站点
vless-reality port 8443            修改监听端口
vless-reality sni www.apple.com    修改 REALITY 伪装域名
vless-reality uuid                 重新生成 UUID
vless-reality rotate-keys          轮换 REALITY 密钥和 Short ID
vless-reality rename Reality-US    修改节点名称
vless-reality refresh-ip           刷新链接中的公网 IPv4
vless-reality update               升级 Xray-core
vless-reality log -f               实时查看日志
vless-reality uninstall            卸载并清理
```

导入链接同时保存在 `/root/vless-reality-link.txt`，其中包含 UUID，请不要发布到 GitHub、聊天或截图中。

## 客户端要求

客户端需要支持 VLESS、REALITY、`xtls-rprx-vision` 和 uTLS 指纹。导入后应确认这些关键参数：

```text
network: tcp
security: reality
flow: xtls-rprx-vision
fingerprint: chrome
SNI: 安装时选择的伪装域名
public key / short id: 使用脚本输出值
```

## 文件位置

```text
/usr/local/bin/xray                     Xray-core
/usr/local/etc/xray/config.json         服务端配置
/etc/systemd/system/xray.service        systemd 服务
/root/vless-reality-setup.sh            管理脚本
/usr/local/bin/vless-reality            快捷命令
/root/vless-reality-link.txt            客户端导入链接
```

本脚本不会自动修改 UFW、iptables、云安全组或 DNS。
