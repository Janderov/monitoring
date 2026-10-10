#!/bin/bash
# Moves servers, sites, their agent tokens and the history from the Mac onto
# the hub. On the Mac: Settings → «Перенос» → export; copy the file here
# (scp file.monitortransfer root@HUB:/opt/monitor-hub/import/) and run:
#   /opt/monitor-hub/src/hub/deploy/import.sh /opt/monitor-hub/import/file.monitortransfer
# Safe to run again: servers and sites are updated, history is added once.
set -euo pipefail
FILE=${1:?укажите файл переноса}
NAME=${2:-Mac}
DIR=/opt/monitor-hub
case "$FILE" in
  "$DIR/import/"*) ;;
  *) cp "$FILE" "$DIR/import/"; FILE="$DIR/import/$(basename "$FILE")" ;;
esac
chown 10001 "$FILE"
read -r -s -p "Пароль файла переноса: " PASSWORD </dev/tty; echo
cd "$DIR/src/hub/deploy"
printf '%s\n' "$PASSWORD" | docker compose run --rm -T hub import "/import/$(basename "$FILE")" "$NAME"
echo "Готово. Хаб подхватит серверы в течение минуты: docker compose logs -f hub"
