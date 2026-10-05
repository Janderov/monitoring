#!/usr/bin/env bash
# Installs or upgrades monitor-agent on a server over SSH, from the Mac.
# This is what the Mac app's "Add server" will do; until then run it by hand.
#
#   agent/scripts/remote-install.sh [-p <ssh port>] [-i <ssh key>] [--host <IP>] user@server
#
# Builds nothing: run agent/scripts/dist.sh first (needs Go). A new token is
# generated for a first install and printed together with the certificate
# fingerprint; save both, the Mac app needs them. Re-running on a server that
# already has the agent upgrades the binary and keeps its token.
#
# Works with the macOS system bash (3.2). Password logins are asked for once:
# all steps share one SSH connection.
set -euo pipefail

SSH_OPTS=()
CERT_HOSTS=()
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_OPTS+=(-p "$2"); shift 2 ;;
    -i) SSH_OPTS+=(-i "$2"); shift 2 ;;
    --host) CERT_HOSTS+=(--host "$2"); shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { sed -n '2,13p' "$0"; exit 2; }

DIST="$(cd "$(dirname "$0")/.." && pwd)/dist"
for f in monitor-agent-linux-amd64 monitor-agent-linux-arm64 monitor-agent.service monitor-agent-flows.service install.sh SHA256SUMS; do
  [[ -f "$DIST/$f" ]] || { echo "missing $DIST/$f, run agent/scripts/dist.sh first" >&2; exit 1; }
done

LOCAL_TMP="$(mktemp -d)"
CTL="$LOCAL_TMP/ssh-ctl"
cleanup() {
  ssh -o ControlPath="$CTL" -O exit "$TARGET" 2>/dev/null || true
  rm -rf "$LOCAL_TMP"
}
trap cleanup EXIT

SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120 ${SSH_OPTS[@]+"${SSH_OPTS[@]}"})
# scp takes -P for the port; rewrite -p.
SCP_OPTS=()
set -- ${SSH_OPTS[@]+"${SSH_OPTS[@]}"}
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-p" ]]; then SCP_OPTS+=(-P "$2"); else SCP_OPTS+=("$1" "$2"); fi
  shift 2
done
SCP=(scp -q -o ControlPath="$CTL" ${SCP_OPTS[@]+"${SCP_OPTS[@]}"})

TOKEN="$(openssl rand -hex 32)"
umask 077
printf '%s\n' "$TOKEN" > "$LOCAL_TMP/token"

echo "connecting to $TARGET..."
REMOTE_DIR="$("${SSH[@]}" "$TARGET" 'mktemp -d /tmp/monitor-agent-install.XXXXXX')"
"${SCP[@]}" "$DIST"/monitor-agent-linux-* "$DIST/monitor-agent.service" "$DIST/monitor-agent-flows.service" "$DIST/install.sh" \
  "$DIST/SHA256SUMS" "$LOCAL_TMP/token" "$TARGET:$REMOTE_DIR/"

# -t so sudo can ask for a password; the temp dir is removed whatever happens.
OUTPUT="$("${SSH[@]}" -t "$TARGET" "
  if [ \"\$(id -u)\" = 0 ]; then S=''; else S=sudo; fi
  \$S bash '$REMOTE_DIR/install.sh' --token-file '$REMOTE_DIR/token' ${CERT_HOSTS[*]+${CERT_HOSTS[*]}}
  rc=\$?
  rm -rf '$REMOTE_DIR'
  exit \$rc
" | tr -d '\r' | tee /dev/stderr)"

echo
if grep -q '^config: created' <<<"$OUTPUT"; then
  echo "Save these in the Mac app:"
  echo "  token:       $TOKEN"
  grep '^fingerprint:' <<<"$OUTPUT" | sed 's/^/  /'
else
  echo "Agent upgraded; its token and fingerprint did not change."
fi
