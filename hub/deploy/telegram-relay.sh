#!/bin/bash
# A relay to the Telegram Bot API for a hub whose server cannot reach
# api.telegram.org. Run as root on ANOTHER server that can (abroad), after an
# A record for the relay's name points at it:
#   curl -fsSL https://raw.githubusercontent.com/Janderov/monitoring/main/hub/deploy/telegram-relay.sh | bash -s tg.example.com HUB_IP [PORT]
# PORT (default 443) is for a server whose 443 is taken, e.g. by a VPN; port
# 80 must be free either way, for the HTTPS certificate.
# Then on the hub: echo 'HUB_TELEGRAM_API=https://tg.example.com[:PORT]' >> /opt/monitor-hub/hub.env
# and run install.sh again. Only HUB_IP may use the relay; it keeps no logs.
set -euo pipefail
DOMAIN=${1:?укажите имя реле, например tg.example.com}
HUB_IP=${2:?укажите IP сервера хаба}
PORT=${3:-443}
ADDR=$DOMAIN; [ "$PORT" = 443 ] || ADDR=$DOMAIN:$PORT
DIR=/opt/tg-relay

[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo -i)"; exit 1; }
command -v docker >/dev/null || { apt-get update -qq && apt-get install -y -qq docker.io >/dev/null; }
if ss -Hltn "( sport = :80 or sport = :$PORT )" | grep -q . && ! docker ps --format '{{.Names}}' | grep -qx tg-relay; then
  echo "Порт 80 или $PORT на этом сервере уже занят:"; ss -ltnp "( sport = :80 or sport = :$PORT )"; exit 1
fi

mkdir -p "$DIR"
cat > "$DIR/Caddyfile" <<CADDY
$ADDR {
	@hub remote_ip $HUB_IP
	handle @hub {
		reverse_proxy https://api.telegram.org {
			header_up Host api.telegram.org
		}
	}
	respond 403
}
CADDY
docker rm -f tg-relay >/dev/null 2>&1 || true
docker run -d --name tg-relay --restart unless-stopped -p 80:80 -p $PORT:$PORT \
  -v "$DIR/Caddyfile:/etc/caddy/Caddyfile:ro" -v tg-relay-data:/data caddy:2-alpine >/dev/null
sleep 15
code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://$ADDR/" || true)
if [ "$code" = 403 ]; then
  echo "Реле работает: https://$ADDR (пускает только $HUB_IP)."
  echo "На сервере хаба: HUB_TELEGRAM_API=https://$ADDR"
else
  echo "Реле запущено, но https://$ADDR пока не отвечает (код $code). Проверьте A-запись и: docker logs tg-relay"
fi
