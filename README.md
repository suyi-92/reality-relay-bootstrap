# Reality Relay Bootstrap

这是一套面向全新 Ubuntu/Debian VPS 的可复现部署脚本，目标是把 **SSH 安全初始化 + fail2ban + UFW + sing-box VLESS+Reality 多入口/多出口 + 客户端节点生成 + 回滚验证** 做成分阶段执行的项目，而不是一次性把服务器改到不可恢复状态。

默认支持：Ubuntu 22.04、Ubuntu 24.04、Debian 13。其他系统会停止并提示。

## 设计原则

1. **不锁机优先**：SSH 拆成 phase1 和 final。phase1 只创建用户并开启公钥登录，不禁 root、不禁密码。只有另开窗口确认 admin key 登录成功后，才能用 `CONFIRM_ADMIN_KEY_LOGIN=yes` 执行 final。
2. **先备份后修改**：SSH、fail2ban、UFW、sing-box 配置都会备份到 `/root/our-server-bootstrap-backups/`。
3. **先检查后重启**：`sshd -t` 通过后才 reload SSH；`sing-box check -c /etc/sing-box/config.json` 通过后才 restart sing-box。
4. **默认最小开放端口**：UFW 只放行当前 SSH 端口、`DIRECT_PORT`、CSV 里的实际 `listen_port`，不默认开放整个 51043-51060 范围。
5. **敏感信息不进普通日志**：VLESS UUID、Reality 私钥、家宽代理密码不会打印到 `/var/log/our-server-bootstrap.log`。节点输出文件权限为 600。
6. **233boy 可选且不强依赖**：默认使用 sing-box 官方 APT 源。只有显式启用 `USE_233BOY_INSTALLER=true` 并设置 `CONFIRM_USE_233BOY_INSTALLER=yes` 时才调用 233boy 安装脚本。调用后会隔离 `/etc/sing-box/conf`，由本项目接管 `/etc/sing-box/config.json`。

## 项目结构

```text
our-server-bootstrap/
  README.md
  config.example.env
  home-proxies.example.csv
  bootstrap.sh
  scripts/
    00-lib.sh
    01-preflight.sh
    02-create-admin.sh
    03-ssh-hardening-phase1.sh
    04-ssh-hardening-final.sh
    05-install-fail2ban.sh
    06-install-ufw.sh
    07-install-singbox.sh
    08-generate-singbox-config.py
    09-apply-firewall.sh
    10-validate.sh
    11-output-nodes.py
    11-output-nodes-wrapper.sh
    12-rollback.sh
  templates/
    sshd-hardening.conf.tpl
    fail2ban-sshd.local.tpl
    clash-mihomo.yaml.tpl
  docs/
    install-flow.md
    recovery.md
    client-setup.md
```

## 第一次使用

```bash
sudo apt update
sudo apt install -y unzip nano
unzip our-server-bootstrap-vless-reality.zip
cd our-server-bootstrap

cp config.example.env config.env
nano config.env

cp home-proxies.example.csv home-proxies.csv
nano home-proxies.csv
```

先 dry-run：

```bash
sudo bash bootstrap.sh --phase preflight --dry-run
sudo bash bootstrap.sh --phase singbox --dry-run
sudo bash bootstrap.sh --phase firewall --dry-run
```

## config.env 必填项

```bash
SERVER_ALIAS="my-vps"
SERVER_IP="你的服务器公网IP"
SSH_PORT="22"
ADMIN_USER="admin"
ADMIN_PUBKEY="ssh-ed25519 AAAA... 你的本地公钥"
MODE_443="direct"
```

如果 root 已经有正确公钥，`ADMIN_PUBKEY` 可以留空，脚本会复制 `/root/.ssh/authorized_keys` 给 admin。但更推荐明确填写 `ADMIN_PUBKEY`。

## VLESS+Reality 参数

默认参数：

```bash
PROXY_PROTOCOL="vless-reality"
VLESS_UUID_PATH="/etc/our-singbox/vless-uuid.txt"
VLESS_FLOW="xtls-rprx-vision"
REALITY_PRIVATE_KEY_PATH="/etc/our-singbox/reality-private.key"
REALITY_PUBLIC_KEY_PATH="/etc/our-singbox/reality-public.key"
REALITY_SHORT_ID_PATH="/etc/our-singbox/reality-short-id.txt"
REALITY_SERVER_NAME="www.microsoft.com"
REALITY_HANDSHAKE_SERVER="www.microsoft.com"
REALITY_HANDSHAKE_PORT="443"
REALITY_MAX_TIME_DIFFERENCE="1m"
CLIENT_FINGERPRINT="chrome"
CLIENT_UDP="false"
CLIENT_ALPN="h2,http/1.1"
```

首次执行 `--phase singbox` 会自动生成：

```text
/etc/our-singbox/vless-uuid.txt
/etc/our-singbox/reality-private.key
/etc/our-singbox/reality-public.key
/etc/our-singbox/reality-short-id.txt
```

这些文件权限为 600。不要公开 Reality 私钥、UUID、CSV 和节点文件。

## 443 模式

```bash
MODE_443="direct"
```

表示 443 永远走中转机自身公网出口。

```bash
MODE_443="smart"
SMART_AI_HOME_TAG=""
```

表示 443 入口中，AI 域名走指定家宽出口；`SMART_AI_HOME_TAG` 为空时使用 CSV 第一行家宽出口，非 AI 国外流量走中转机自身出口，国内/私有地址 reject。

## home-proxies.csv

格式固定：

```csv
tag,listen_port,type,server,server_port,username,password,network
home-01,51043,socks5,proxy1.example.com,1080,user1,"pass,with,comma",tcp
home-02,51044,http,proxy2.example.com,8080,user2,password2,tcp
```

规则：

- `443` 不能写进 CSV，它由 `DIRECT_PORT` 固定生成。
- `listen_port` 不能重复。
- `listen_port` 必须在 `HOME_PORT_START` 到 `HOME_PORT_END` 范围内。
- `type` 只支持 `socks5` 或 `http`。
- 密码里如果有英文逗号，必须用英文双引号包起来，例如 `"abc,123"`。
- CSV 含有家宽代理账号密码，不要公开。

## 标准执行流程

```bash
sudo bash bootstrap.sh --phase preflight
sudo bash bootstrap.sh --phase ssh-phase1

# 另开窗口测试 admin key 登录成功后：
sudo CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final

sudo bash bootstrap.sh --phase fail2ban
sudo bash bootstrap.sh --phase singbox
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-nodes
```

## SSH 二阶段说明

`ssh-phase1` 会创建 admin、安装 SSH 公钥、可选创建 SFTP-only 用户、写入 phase1 drop-in，只开启公钥登录，不禁 root、不禁密码。

不要关闭当前 SSH 窗口。另开 Windows PowerShell 测试：

```powershell
ssh -p 22 -o PreferredAuthentications=publickey -o PasswordAuthentication=no admin@服务器IP
```

登录后执行：

```bash
whoami
sudo whoami
```

只有确认输出为 `admin` 和 `root` 后，才执行：

```bash
sudo CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
```

## 安装 sing-box 与生成配置

默认官方 APT 安装：

```bash
sudo bash bootstrap.sh --phase singbox
```

可选使用 233boy 作为 core/管理工具基础：

```bash
USE_233BOY_INSTALLER="true"
INSTALL_SINGBOX_METHOD="233boy"
sudo CONFIRM_USE_233BOY_INSTALLER=yes bash bootstrap.sh --phase singbox
```

启用 233boy 后，本项目会隔离 `/etc/sing-box/conf` 为 `/etc/sing-box/conf.233boy.disabled.TIMESTAMP`，避免 233boy 默认 VLESS-REALITY 配置和本项目多入口配置同时生效。

## 新增/删除家宽出口

新增：编辑 `home-proxies.csv`，增加一行新端口，然后执行：

```bash
sudo bash bootstrap.sh --phase singbox
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-nodes
```

删除：从 CSV 删除对应行，再执行同样命令。UFW 会继续保留旧规则；如需删除旧端口规则，请用 `sudo ufw status numbered` 查看编号后手动删除。

## 查看节点信息

```bash
sudo cat /root/our-singbox-nodes.txt
sudo cat /root/our-singbox-clash.yaml
```

输出节点包括：

- `Relay-Direct-443` 或 `Smart-443`
- 每个 CSV 行一个节点，例如 `home-01-51043`

Mihomo/Clash 节点字段为：

```yaml
name: home-01-51043
type: vless
server: 服务器IP
port: 51043
uuid: "..."
flow: xtls-rprx-vision
tls: true
servername: www.microsoft.com
client-fingerprint: chrome
udp: false
reality-opts:
  public-key: "..."
  short-id: "..."
alpn:
  - h2
  - http/1.1
```

## 防火墙和服务商安全组

脚本只会开放实际端口：

```text
SSH:        tcp/$SSH_PORT
VLESS:      tcp/$DIRECT_PORT
VLESS:      tcp/CSV 中每个 listen_port
```

服务商安全组/云防火墙也必须手动放行同样端口。

## 验证

```bash
sudo bash bootstrap.sh --phase validate
```

验证内容：

- `sshd -t`
- `sshd -T`
- fail2ban 状态
- UFW 状态
- `sing-box check -c /etc/sing-box/config.json`
- sing-box systemd 状态
- 监听端口
- 每个家宽代理本身是否可用：`curl -x socks5h/http https://ifconfig.me`

Windows PowerShell：

```powershell
Test-NetConnection 服务器IP -Port 443
Test-NetConnection 服务器IP -Port 51043
ssh -p 22 -o PreferredAuthentications=publickey -o PasswordAuthentication=no admin@服务器IP
ssh -p 22 root@服务器IP
ssh -p 22 -o PubkeyAuthentication=no -o PreferredAuthentications=password admin@服务器IP
```

## 回滚

```bash
sudo CONFIRM_ROLLBACK=yes bash bootstrap.sh --phase rollback
```

可选：

```bash
sudo CONFIRM_ROLLBACK=yes RESTORE_FULL_SSH_BACKUP=yes bash bootstrap.sh --phase rollback
sudo CONFIRM_ROLLBACK=yes ROLLBACK_DISABLE_UFW=yes bash bootstrap.sh --phase rollback
sudo CONFIRM_ROLLBACK=yes RESTORE_233BOY_CONF=yes bash bootstrap.sh --phase rollback
```

## 安全提醒

不要公开：

- `/etc/our-singbox/vless-uuid.txt`
- `/etc/our-singbox/reality-private.key`
- `home-proxies.csv`
- `/root/our-singbox-nodes.txt`
- `/root/our-singbox-clash.yaml`
