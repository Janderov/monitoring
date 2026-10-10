#!/usr/bin/env bash
# Telegram for the hub.
#   telegram.sh token   — ввести или сменить токен бота (ввод не виден), хаб перезапустится
#   telegram.sh link    — ссылка, чтобы привязать свой Telegram (на 10 минут)
set -euo pipefail
DIR=/opt/monitor-hub
cd "$DIR/src/hub/deploy"
case "${1:-}" in
  token)
    read -r -s -p "Токен от @BotFather: " token </dev/tty; echo
    printf '%s\n' "$token" > "$DIR/secrets/telegram-bot-token"
    chown 10001 "$DIR/secrets/telegram-bot-token"; chmod 600 "$DIR/secrets/telegram-bot-token"
    docker compose up -d --force-recreate hub
    sleep 8
    docker compose logs --tail 20 hub | grep -i telegram || true
    ;;
  link)
    docker compose exec hub monitor-hub telegram-link ${2:-}
    ;;
  *)
    echo "использование: telegram.sh token | telegram.sh link [логин]"; exit 1 ;;
esac
