#!/bin/bash
# A relay to the Telegram Bot API for a hub whose server cannot reach
# api.telegram.org. Run as root on ANOTHER server that can (abroad), after an
# A record for the relay's name points at it:
#   curl -fsSL https://raw.githubusercontent.com/Janderov/monitoring/main/hub/deploy/telegram-relay.sh | bash -s tg.example.com HUB_IP
# Then on the hub: echo 'HUB_TELEGRAM_API=https://tg.example.com' >> /opt/monitor-hub/hub.env
# and run install.sh again. Only HUB_IP may use the relay; it keeps no logs.
set -euo pipefail
DOMAIN=${1:?укажите имя реле, например tg.example.com}
HUB_IP=${2:?укажите IP сервера хаба}
DIR=/opt/tg-relay

[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo -i)"; exit 1; }
command -v docker >/dev/null || { apt-get update -qq && apt-get install -y -qq docker.io >/dev/null; }
if ss -Hltn '( sport = :80 or sport = :443 )' | grep -q . && ! docker ps --format '{{.Names}}' | grep -qx tg-relay; then
  echo "Порт 80 или 443 на этом сервере уже занят:"; ss -ltnp '( sport = :80 or sport = :443 )'; exit 1
fi

mkdir -p "$DIR"
cat > "$DIR/Caddyfile" <<CADDY
$DOMAIN {
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
docker run -d --name tg-relay --restart unless-stopped -p 80:80 -p 443:443 \
  -v "$DIR/Caddyfile:/etc/caddy/Caddyfile:ro" -v tg-relay-data:/data caddy:2-alpine >/dev/null
sleep 15
code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://$DOMAIN/" || true)
if [ "$code" = 403 ]; then
  echo "Реле работает: https://$DOMAIN (пускает только $HUB_IP)."
else
  echo "Реле запущено, но https://$DOMAIN пока не отвечает (код $code). Проверьте A-запись и: docker logs tg-relay"
fi
