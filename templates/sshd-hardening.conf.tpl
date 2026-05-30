# /etc/ssh/sshd_config.d/00-reality-relay-bootstrap-hardening.conf
# Template only. The script renders ADMIN_USER/SFTP_USER dynamically.

PermitRootLogin no
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
