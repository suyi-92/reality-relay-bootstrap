# 客户端配置与测试

部署后生成：

```bash
/root/reality-relay-bootstrap-nodes.txt
/root/reality-relay-bootstrap-clash.yaml
```

两个文件包含 VLESS UUID、Reality public key、short-id 等节点信息，权限为 600，不要公开。

如果开启简单订阅端口：

```bash
ENABLE_SUBSCRIPTION_SERVER="true"
SUBSCRIPTION_PORT="51040"
```

执行 `sudo bash bootstrap.sh --phase output-nodes` 后，Clash/Mihomo 可使用：

```text
http://服务器IP:51040/clash.yaml
```

这是无鉴权 HTTP 文件服务，建议只在服务商安全组里放行你的常用来源 IP。
如果同时配置了 IPv4 和 IPv6，IPv4 订阅只返回 IPv4 节点，IPv6 订阅返回 IPv4 + IPv6 双栈节点。

如果 `PROXY_IP_VERSION="ipv6"` 或 `PROXY_IP_VERSION="dual"`，生成的 Clash/Mihomo 配置会启用 `ipv6: true`；默认 `ipv4` 会保持 `ipv6: false`。

## Clash/Mihomo 节点字段

每个节点类似：

```yaml
name: home-01
type: vless
server: 服务器IP
port: 51043
uuid: "自动生成的 VLESS UUID"
flow: xtls-rprx-vision
tls: true
servername: www.microsoft.com
client-fingerprint: chrome
udp: false
reality-opts:
  public-key: "自动生成的 Reality public key"
  short-id: "自动生成的 short-id"
alpn:
  - h2
  - http/1.1
```

443 节点：

- `MODE_443=direct`：使用 `SERVER_ALIAS`
- `MODE_443=smart`：使用 `SERVER_ALIAS`

CSV 行节点：

- `home-01,51043,...` -> `home-01`

## Windows PowerShell 测端口

```powershell
Test-NetConnection 服务器IP -Port 443
Test-NetConnection 服务器IP -Port 51043
```

## Clash/Mihomo 测出口 IP

导入 `/root/reality-relay-bootstrap-clash.yaml` 后，在本地执行：

```powershell
curl.exe -x http://127.0.0.1:7890 https://ifconfig.me
```

切换不同节点，出口 IP 应该对应：

- `SERVER_ALIAS` 对应的节点（例如 `my-vps`）：中转机自身公网 IP
- 家宽 `tag` 对应的节点（例如 `home-xx`）：对应家宽代理出口 IP

## 常见问题

1. 端口不通：检查服务商安全组、UFW、sing-box 监听。
2. 只有某个家宽节点失败：先在服务器执行 `validate`，看该家宽代理本身是否可用。
3. VLESS+Reality 握手失败：确认客户端 `servername`、`public-key`、`short-id`、`uuid` 与服务端输出一致。
4. HTTP 家宽代理不支持 UDP：默认 `CLIENT_UDP=false`，先用 TCP 跑通。
