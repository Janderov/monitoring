#!/usr/bin/env bash
# Installs or upgrades monitor-agent as a systemd service on Ubuntu.
# Normally run by remote-install.sh (or the Mac app) after copying the dist/
# bundle to the server over SSH:
#   sudo ./install.sh --token-file <file with token>
# It picks monitor-agent-linux-<arch> from its own directory and verifies it
# against SHA256SUMS. --binary <path> installs a specific file instead.
#
# Options: --host <IP or name> (repeatable, added to the certificate), --port <port> (default 9443).
# Prints the certificate fingerprint at the end; the Mac app pins it.
# Re-running upgrades the binary and keeps the existing config, certificate and token.
set -euo pipefail

BINARY=""
TOKEN=""
TOKEN_FILE=""
HOSTS=()
PORT=9443

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --token)  TOKEN="$2"; shift 2 ;;
    # A file keeps the token out of the process list.
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --host)   HOSTS+=("$2"); shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "install: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"

CONF_DIR=/etc/monitor-agent
CONF="$CONF_DIR/config.json"
HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_SRC="$HERE/monitor-agent.service"
[[ -f "$UNIT_SRC" ]] || die "monitor-agent.service must be next to install.sh"
# Optional root helper for NAT and inbound connections (older bundles lack it).
FLOWS_SRC="$HERE/monitor-agent-flows.service"

if [[ -z "$BINARY" ]]; then
  case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  BINARY="$HERE/monitor-agent-linux-$ARCH"
  [[ -f "$BINARY" ]] || die "$BINARY not found"
  if [[ -f "$HERE/SHA256SUMS" ]]; then
    # Catch a truncated or corrupted copy before replacing a working agent.
    (cd "$HERE" && grep -E " (monitor-agent-linux-$ARCH|monitor-agent(-flows)?\.service)\$" SHA256SUMS | sha256sum -c --quiet -) \
      || die "checksum mismatch, refusing to install"
  fi
fi
[[ -f "$BINARY" ]] || die "binary $BINARY not found"

if ! id monitor-agent >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin monitor-agent
fi

# Docker access lets the agent see AmneziaVPN and other containers. Membership
# in the docker group is powerful; the agent only lists containers and runs
# read-only commands (wg show, cat clientsTable) inside AmneziaVPN containers.
if getent group docker >/dev/null; then
  usermod -aG docker monitor-agent
fi

install -m 0755 "$BINARY" /usr/local/bin/monitor-agent

if [[ ! -f "$CONF" ]]; then
  init_args=()
  if [[ -n "$TOKEN_FILE" ]]; then
    init_args+=(-token-file "$TOKEN_FILE")
  elif [[ -n "$TOKEN" ]]; then
    init_args+=(-token "$TOKEN")
  else
    die "--token-file or --token is required on first install"
  fi
  for h in ${HOSTS[@]+"${HOSTS[@]}"}; do init_args+=(-host "$h"); done
  /usr/local/bin/monitor-agent init -config "$CONF" -listen ":$PORT" ${init_args[@]+"${init_args[@]}"} \
    | grep '^service:' || true
  echo "config: created"
else
  echo "config: kept (existing token and certificate)"
fi
chown -R root:monitor-agent "$CONF_DIR"
chmod 0750 "$CONF_DIR"
chmod 0640 "$CONF" "$CONF_DIR/key.pem"
chmod 0644 "$CONF_DIR/cert.pem"

install -m 0644 "$UNIT_SRC" /etc/systemd/system/monitor-agent.service
systemctl daemon-reload
systemctl enable monitor-agent >/dev/null
systemctl restart monitor-agent
if [[ -f "$FLOWS_SRC" ]]; then
  install -m 0644 "$FLOWS_SRC" /etc/systemd/system/monitor-agent-flows.service
  systemctl daemon-reload
  systemctl enable monitor-agent-flows >/dev/null
  systemctl restart monitor-agent-flows
  echo "flows helper: running"
fi

# Only nag when the firewall is on and has no rule for the agent port yet.
if command -v ufw >/dev/null && ufw status | grep -q "Status: active" \
   && ! ufw status | grep -Eq "^${PORT}(/tcp)?[[:space:]]+ALLOW"; then
  echo "ufw is active: allow the agent port with 'ufw allow $PORT/tcp' (ideally only from your IP)"
fi

echo "monitor-agent $(/usr/local/bin/monitor-agent version) installed and running"
echo "fingerprint: $(/usr/local/bin/monitor-agent fingerprint -config "$CONF")"
