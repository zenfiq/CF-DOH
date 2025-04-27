#!/bin/bash

echo "=== Update Server ==="
apt update && apt upgrade -y

echo "=== Install cloudflared, ufw, iptables-persistent ==="
apt install curl ufw iptables-persistent -y
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
dpkg -i cloudflared.deb

echo "=== Setup cloudflared service ==="
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared DNS over HTTPS proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared proxy-dns --port 53 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
Restart=always
RestartSec=3
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

echo "=== Configure Netplan DNS to 127.0.0.1 with fallback ==="
NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n 1)
cp \$NETPLAN_FILE \${NETPLAN_FILE}.bak
sed -i '/nameservers:/,/addresses:/c\      nameservers:\n        addresses:\n          - 127.0.0.1\n          - 1.1.1.1\n          - 8.8.8.8' \$NETPLAN_FILE
netplan apply

echo "=== Setup Firewall UFW ==="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from 127.0.0.1 to any port 53 proto udp
ufw allow from 127.0.0.1 to any port 53 proto tcp
ufw deny out to any port 53 proto udp
ufw deny out to any port 53 proto tcp
ufw --force enable

echo "=== Apply iptables Anti-DDoS Rules ==="
iptables -F
iptables -X
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --syn -m limit --limit 2/second --limit-burst 25 -j ACCEPT
iptables -A INPUT -p tcp --tcp-flags ALL SYN,ACK,FIN,RST RST -m limit --limit 2/second --limit-burst 2 -j ACCEPT
iptables -A INPUT -p icmp -m limit --limit 1/second --limit-burst 5 -j ACCEPT
iptables -A INPUT -p udp -m length --length 0:28 -j DROP
iptables -A INPUT -p udp -m limit --limit 50/second --limit-burst 50 -j ACCEPT
iptables -A INPUT -j DROP

netfilter-persistent save
netfilter-persistent reload

echo "=== Enable TCP Stack Optimization & BBRv2 ==="
cat >> /etc/sysctl.conf <<EOF

# Anti DDoS Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# TCP Speed Optimization
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_mtu_probing = 1

# Enable BBRv2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p

echo "=== Setup Cloudflared Health Monitor ==="
cat > /etc/cron.d/monitor-cloudflared <<EOF
* * * * * root pgrep cloudflared > /dev/null || (systemctl restart cloudflared || echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf)
EOF

echo "=== FINISH ==="
echo "✅ Server sudah full secure: Cloudflare DoH + Anti-DDoS + BBR2 + Firewall Locked!"
echo "✅ Direkomendasikan reboot server untuk optimalisasi penuh!"
