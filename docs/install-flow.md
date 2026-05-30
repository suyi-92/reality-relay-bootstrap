# 安装流程

## 1. 准备配置

```bash
cp config.example.env config.env
nano config.env
cp home-proxies.example.csv home-proxies.csv
nano home-proxies.csv
```

`443` 不写入 CSV。CSV 只管理 `51043` 起的家宽出口端口。

## 2. SSH 初始化与加固

```bash
sudo bash bootstrap.sh --phase preflight
sudo bash bootstrap.sh --phase ssh-phase1
```

保留当前 SSH 窗口，另开窗口测试：

```powershell
ssh -p 22 -o PreferredAuthentications=publickey -o PasswordAuthentication=no admin@服务器IP
```

确认 `whoami` 为 `admin` 且 `sudo whoami` 为 `root` 后：

```bash
sudo CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
```

## 3. fail2ban

```bash
sudo bash bootstrap.sh --phase fail2ban
```

## 4. sing-box VLESS+Reality

```bash
sudo bash bootstrap.sh --phase singbox
```

此阶段会：

1. 安装 sing-box。
2. 复制 `home-proxies.csv` 到 `/etc/our-singbox/home-proxies.csv`。
3. 生成 VLESS UUID、Reality keypair、short-id。
4. 生成 `/etc/sing-box/config.json`。
5. 执行 `sing-box check`。
6. 通过后重启 sing-box。
7. 输出 `/root/our-singbox-nodes.txt` 和 `/root/our-singbox-clash.yaml`。

## 5. 防火墙

```bash
sudo bash bootstrap.sh --phase firewall
```

UFW 只放行 SSH、`DIRECT_PORT`、CSV 中实际 `listen_port`。服务商安全组也要手动放行同样端口。

## 6. 验证

```bash
sudo bash bootstrap.sh --phase validate
```
