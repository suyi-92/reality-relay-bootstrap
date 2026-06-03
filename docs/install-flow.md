# 安装流程

## 1. 准备配置

```bash
cp config.example.env config.env
nano config.env
cp home-proxies.example.csv home-proxies.csv
nano home-proxies.csv
cp upstream-nodes.example.txt upstream-nodes.txt
nano upstream-nodes.txt
```

`443` 不写入 CSV。CSV 只管理 `51043` 起的家宽出口端口。字段顺序为 `tag,listen_port,type,server,server_port,username,password,network`；分步骤模式直接编辑 `home-proxies.csv`，一键模式可选择逐个填写或一次性粘贴多行 CSV（可带表头，空行结束）。

`upstream-nodes.txt` 是可选文件，用来接入上游节点分享链接。支持 `hysteria2://`、`vless://...security=none...` 和 `vless://...security=reality...`。可写 `tag,listen_port,node_url`，也可逐行只写节点链接让脚本自动分配端口。

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
2. 复制 `home-proxies.csv` 到 `/etc/reality-relay-bootstrap/home-proxies.csv`，如果存在也会复制 `upstream-nodes.txt`。
3. 生成 VLESS UUID、Reality keypair、short-id。
4. 生成 `/etc/sing-box/config.json`。
5. 执行 `sing-box check`。
6. 通过后重启 sing-box。
7. 输出 `/root/reality-relay-bootstrap-nodes.txt` 和 `/root/reality-relay-bootstrap-clash.yaml`。

## 5. 防火墙

```bash
sudo bash bootstrap.sh --phase firewall
```

UFW 只放行 SSH、`DIRECT_PORT`、`home-proxies.csv` 和 `upstream-nodes.txt` 中实际使用的 `listen_port`。服务商安全组也要手动放行同样端口。

如果 `ENABLE_SUBSCRIPTION_SERVER=true`，还会放行 `SUBSCRIPTION_PORT`，默认是 `51040`。

## 6. 验证

```bash
sudo bash bootstrap.sh --phase validate
```
