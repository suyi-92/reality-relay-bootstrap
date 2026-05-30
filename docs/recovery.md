# 恢复与回滚

## SSH 故障原则

不要关闭当前还能登录的 SSH 窗口。先执行：

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T -C user=admin,host=localhost,addr=127.0.0.1
```

如果新窗口无法登录，可在旧窗口回滚：

```bash
sudo CONFIRM_ROLLBACK=yes bash bootstrap.sh --phase rollback
```

## 完整 SSH 配置回滚

```bash
sudo CONFIRM_ROLLBACK=yes RESTORE_FULL_SSH_BACKUP=yes bash bootstrap.sh --phase rollback
```

## UFW 导致失联风险

如果当前旧窗口还能用，可以临时禁用 UFW：

```bash
sudo CONFIRM_ROLLBACK=yes ROLLBACK_DISABLE_UFW=yes bash bootstrap.sh --phase rollback
```

或者手动：

```bash
sudo ufw disable
```

## sing-box 配置回滚

默认 rollback 会尝试恢复最近备份中的 `/etc/sing-box/config.json`，恢复后执行 `sing-box check` 并重启。

## 233boy conf 恢复

如果之前使用了 233boy 并希望恢复其 `/etc/sing-box/conf`：

```bash
sudo CONFIRM_ROLLBACK=yes RESTORE_233BOY_CONF=yes bash bootstrap.sh --phase rollback
```
