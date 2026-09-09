# Managed SSH policy block at the start of /etc/ssh/sshd_config.
# Template only. The script renders root/SFTP_USER dynamically.

PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no

AllowUsers {{ALLOW_USERS}}

MaxAuthTries 3
MaxSessions 2
LoginGraceTime 30

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

ClientAliveInterval 300
ClientAliveCountMax 2
