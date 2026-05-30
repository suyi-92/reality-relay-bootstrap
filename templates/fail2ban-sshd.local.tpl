# /etc/fail2ban/jail.d/sshd.local
# Template only. The script renders SSH_PORT dynamically.

[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
backend = systemd
usedns = no

[sshd]
enabled = true
port = {{SSH_PORT}}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
