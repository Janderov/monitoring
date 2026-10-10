#!/bin/bash
# Installs or updates the monitoring hub on a fresh Ubuntu 22.04/24.04 VPS.
# Run as root on the VPS:
#   curl -fsSL https://raw.githubusercontent.com/Janderov/monitoring/main/hub/deploy/install.sh | bash
# Running it again updates the hub to the newest code and keeps the data,
# the keys and the settings.
set -euo pipefail

DIR=/opt/monitor-hub
REPO=https://github.com/Janderov/monitoring.git
BRANCH=${HUB_BRANCH:-main}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo -i)"; exit 1; }

say "1/5 Ставлю Docker и git"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git docker.io docker-compose-v2 >/dev/null
  systemctl enable --now docker
fi
command -v git >/dev/null || apt-get install -y -qq git >/dev/null

say "2/5 Забираю код хаба"
if [ -d "$DIR/src/.git" ]; then
  git -C "$DIR/src" fetch -q origin "$BRANCH"
  git -C "$DIR/src" checkout -q -B "$BRANCH" "origin/$BRANCH"
else
  mkdir -p "$DIR"
  git clone -q --branch "$BRANCH" "$REPO" "$DIR/src"
fi
COMPOSE_DIR="$DIR/src/hub/deploy"

say "3/5 Ключи и пароли (создаются один раз)"
SECRETS="$DIR/secrets"
mkdir -p "$SECRETS" "$DIR/backups" "$DIR/import"
chmod 700 "$SECRETS"
[ -s "$SECRETS/secret-key" ] || openssl rand -base64 32 > "$SECRETS/secret-key"
[ -s "$SECRETS/db-password" ] || openssl rand -hex 24 > "$SECRETS/db-password"
if [ ! -e "$SECRETS/heartbeat-url" ]; then
  url=""
  if [ -t 0 ] || [ -e /dev/tty ]; then
    read -r -p "Адрес пульса healthchecks.io (https://hc-ping.com/…), Enter — пропустить: " url </dev/tty || true
  fi
  printf '%s\n' "$url" > "$SECRETS/heartbeat-url"
fi
# Client report links (https://ДОМЕН/r/…): optional, asked once; an empty file = no links yet.
if [ ! -e "$DIR/report-domain" ]; then
  domain=""
  if [ -t 0 ] || [ -e /dev/tty ]; then
    read -r -p "Домен для ссылок на отчёты клиентам (например reports.example.com), Enter — позже: " domain </dev/tty || true
  fi
  printf '%s\n' "$domain" > "$DIR/report-domain"
fi
domain=$(tr -d '[:space:]' < "$DIR/report-domain")
if [ -n "$domain" ]; then
  printf 'COMPOSE_PROFILES=web\nHUB_DOMAIN=%s\nHUB_PUBLIC_URL=https://%s\n' "$domain" "$domain" > "$DIR/compose.env"
else
  : > "$DIR/compose.env"
fi
chown -R 10001 "$SECRETS" "$DIR/import"
chmod 600 "$SECRETS"/*
# The compose file looks for ./secrets, ./backups and ./import next to it.
ln -sfn "$SECRETS" "$COMPOSE_DIR/secrets"
ln -sfn "$DIR/backups" "$COMPOSE_DIR/backups"
ln -sfn "$DIR/import" "$COMPOSE_DIR/import"
ln -sfn "$DIR/compose.env" "$COMPOSE_DIR/.env"

say "4/5 Собираю и запускаю (первый раз несколько минут)"
cd "$COMPOSE_DIR"
VERSION="$(git -C "$DIR/src" log -1 --format=%cd-%h --date=format:%Y%m%d)"
docker compose build --build-arg HUB_VERSION="$VERSION" hub
docker compose up -d

say "5/5 Проверяю"
sleep 10
docker compose ps
docker compose logs --tail 20 hub
cat <<MSG

Готово. Хаб $VERSION работает и будет перезапускаться сам после сбоев и перезагрузки VPS.

Что дальше:
  • Перенести серверы и историю с Mac:  $DIR/src/hub/deploy/import.sh ФАЙЛ.monitortransfer
  • Посмотреть, что делает хаб:          cd $COMPOSE_DIR && docker compose logs -f hub
  • Обновить хаб:                        запустите этот же скрипт ещё раз
  • Отчёты клиентам:                     cd $COMPOSE_DIR && docker compose exec hub monitor-hub report help

Сохраните копию $SECRETS/secret-key в надёжном месте: без него токены
агентов в базе не расшифровать (их можно заново перенести с Mac).
MSG
