#!/usr/bin/env bash
# Installs monitor-agent as a systemd service on Ubuntu.
#
#   sudo ./install.sh --binary ./monitor-agent --token <token from the Mac app> [--host <public IP>] [--port 9443]
#
# Prints the certificate fingerprint at the end; paste it into the Mac app.
# Re-running upgrades the binary and keeps the existing config and certificate.
set -euo pipefail

BINARY=""
TOKEN=""
HOSTS=()
PORT=9443

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --token)  TOKEN="$2"; shift 2 ;;
    --host)   HOSTS+=("$2"); shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -n "$BINARY" && -f "$BINARY" ]] || { echo "--binary path is required" >&2; exit 2; }

CONF_DIR=/etc/monitor-agent
CONF="$CONF_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! id monitor-agent >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin monitor-agent
fi

# Docker access lets the agent see AmneziaVPN and other containers.
# Note: membership in the docker group is powerful; the agent only sends GET requests.
if getent group docker >/dev/null; then
  usermod -aG docker monitor-agent
fi

install -m 0755 "$BINARY" /usr/local/bin/monitor-agent

if [[ ! -f "$CONF" ]]; then
  [[ -n "$TOKEN" ]] || { echo "--token is required on first install" >&2; exit 2; }
  host_args=()
  for h in "${HOSTS[@]}"; do host_args+=(-host "$h"); done
  /usr/local/bin/monitor-agent init -config "$CONF" -token "$TOKEN" -listen ":$PORT" "${host_args[@]}" >/dev/null
fi
chown -R root:monitor-agent "$CONF_DIR"
chmod 0750 "$CONF_DIR"
chmod 0640 "$CONF" "$CONF_DIR/key.pem"

install -m 0644 "$SCRIPT_DIR/monitor-agent.service" /etc/systemd/system/monitor-agent.service
systemctl daemon-reload
systemctl enable monitor-agent >/dev/null
systemctl restart monitor-agent

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  echo "ufw is active: allow the agent port with 'ufw allow $PORT/tcp' (ideally only from your IP)"
fi

echo "monitor-agent $(/usr/local/bin/monitor-agent version) installed and running"
echo "fingerprint: $(/usr/local/bin/monitor-agent fingerprint -config "$CONF")"
