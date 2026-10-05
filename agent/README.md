# monitor-agent

Агент для серверов Ubuntu. Раз в минуту читает метрики из `/proc` и список Docker-контейнеров,
хранит последние 24 часа в памяти и отдаёт их приложению на Mac по HTTPS. Ничего на сервере
не меняет.

## Сборка и тесты

```
cd agent
go test ./...
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.version=0.1.0" -o monitor-agent ./cmd/monitor-agent
```

## Установка на сервер (пока вручную)

```
scp monitor-agent deploy/install.sh deploy/monitor-agent.service root@SERVER:/tmp/
ssh root@SERVER 'cd /tmp && ./install.sh --binary ./monitor-agent --token <ключ> --host <IP сервера>'
```

Ключ генерирует приложение на Mac (до его появления подойдёт `openssl rand -hex 32`).
Скрипт печатает отпечаток сертификата, его нужно сохранить в приложении. Порт по умолчанию 9443.

## API

Все запросы требуют заголовок `Authorization: Bearer <ключ>`.

| Запрос | Ответ |
|---|---|
| `GET /v1/health` | версия агента и время его работы |
| `GET /v1/snapshot` | последний снимок: CPU, память, нагрузка, диски, сеть, аптайм, контейнеры |
| `GET /v1/history?since=<unix>` | снимки новее `since`, по 500 за раз; `more: true` значит, что нужно запросить ещё |

Проверка с Mac:

```
curl -k -H "Authorization: Bearer $TOKEN" https://SERVER:9443/v1/snapshot
```
