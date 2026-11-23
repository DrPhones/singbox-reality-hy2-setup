#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 [sni_domain]"; exit 1; }

SNI="${1:-v.whatsapp.net}"
[[ "$SNI" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "ERR: Invalid SNI domain"; exit 1; }

# 1. Install dependencies & enable BBR
apt-get update -qq
apt-get install -y -qq curl openssl qrencode jq iproute2
printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/99-bbr.conf
sysctl -q --system

# 2. Verify SNI supports TLSv1.3 + ALPN h2 + valid certificate
TLS_OUT=$(echo | timeout 5 openssl s_client -connect "${SNI}:443" -servername "${SNI}" -alpn h2 -tls1_3 2>&1 || true)
grep -q "ALPN protocol: h2" <<< "$TLS_OUT" || { echo "ERR: ${SNI} failed ALPN h2 / TLSv1.3 check"; exit 1; }
grep -q "Verify return code: 0 (ok)" <<< "$TLS_OUT" || { echo "ERR: ${SNI} failed certificate verification"; exit 1; }

# 3. Install latest official sing-box .deb (amd64 / arm64)
ARCH=$(dpkg --print-architecture)
DEB_URL=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
  | jq -r --arg a "_linux_${ARCH}.deb" '.assets[] | select(.name | endswith($a)) | .browser_download_url' | head -n 1)
[[ -n "$DEB_URL" ]] || { echo "ERR: sing-box .deb not found for architecture: ${ARCH}"; exit 1; }
curl -fsSL -o /tmp/sing-box.deb "$DEB_URL"
dpkg -i /tmp/sing-box.deb >/dev/null
rm -f /tmp/sing-box.deb

# 4. Generate or reuse credentials & self-signed EC certificate for Hysteria2
mkdir -p /etc/sing-box/certs
if [[ -f /etc/sing-box/creds.env ]]; then
  # shellcheck disable=SC1091
  source /etc/sing-box/creds.env
else
  UUID=$(sing-box generate uuid)
  KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey:/ {print $2}' <<< "$KEYS")
  PUBLIC_KEY=$(awk '/PublicKey:/ {print $2}' <<< "$KEYS")
  SHORT_ID=$(sing-box generate rand --hex 8)
  HY2_PASS=$(openssl rand -hex 16)
fi
[[ ${#UUID} -eq 36 && ${#PRIVATE_KEY} -eq 43 && ${#PUBLIC_KEY} -eq 43 ]] || { echo "ERR: Credential validation failed"; exit 1; }

cat > /etc/sing-box/creds.env <<EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
HY2_PASS=${HY2_PASS}
SNI_DOMAIN=${SNI}
EOF
chmod 600 /etc/sing-box/creds.env

[[ -f /etc/sing-box/certs/hy2.key ]] || openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/certs/hy2.key 2>/dev/null
openssl req -new -x509 -days 3650 -key /etc/sing-box/certs/hy2.key -out /etc/sing-box/certs/hy2.crt -subj "/CN=${SNI}" 2>/dev/null

# 5. Write sing-box config & enforce least-privilege permissions
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "password": "${HY2_PASS}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/certs/hy2.crt",
        "key_path": "/etc/sing-box/certs/hy2.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF

if getent group sing-box >/dev/null; then
  chgrp sing-box /etc/sing-box/config.json /etc/sing-box/certs/hy2.key /etc/sing-box/certs/hy2.crt
fi
chmod 640 /etc/sing-box/config.json /etc/sing-box/certs/hy2.key
chmod 644 /etc/sing-box/certs/hy2.crt

# 6. Validate, start & verify active sockets
sing-box check -c /etc/sing-box/config.json
systemctl enable --now sing-box
systemctl restart sing-box
sleep 1
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 20 --no-pager; exit 1; }
ss -tulnp | grep -E ':443\b'

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "WARN: UFW is active; ensure TCP/UDP 443 are allowed (sudo ufw allow 443/tcp && sudo ufw allow 443/udp)."
fi

# 7. Output links & QR codes
IP=$(curl -4 -fsSL "https://checkip.amazonaws.com" || curl -4 -fsSL "https://ifconfig.me")
VLESS="vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-Reality"
HY2="hy2://${HY2_PASS}@${IP}:443?sni=${SNI}&insecure=1#Hysteria2"

printf "\n================ VLESS + REALITY (TCP 443) ================\n%s\n\n" "$VLESS"
qrencode -t ANSIUTF8 "$VLESS"
printf "\n================ HYSTERIA2 (UDP 443) ================\n%s\n\n" "$HY2"
qrencode -t ANSIUTF8 "$HY2"
