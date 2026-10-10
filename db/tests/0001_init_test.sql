-- Проверки первой миграции. Запуск: db/check.sh (применяет миграции к пустой базе и гоняет этот файл).
-- Всё в одной транзакции с откатом в конце: файл можно запускать повторно.
\set ON_ERROR_STOP 1
BEGIN;

CREATE FUNCTION pg_temp.expect(got text, want text, what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF got IS DISTINCT FROM want THEN
    RAISE EXCEPTION 'FAIL %: got %, want %', what, got, want;
  END IF;
  RAISE NOTICE 'ok   %', what;
END $$;

-- Люди, клиенты, объекты (адреса из документации, не настоящие)
INSERT INTO acc.account (id, login, display_name, kind, status) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'owner', 'Владелец', 'owner', 'active'),
  ('00000000-0000-0000-0000-0000000000a2', 'ivan',  'Иван',     'staff', 'active'),
  ('00000000-0000-0000-0000-0000000000a3', 'anna',  'Анна',     'staff', 'disabled');
INSERT INTO inv.client (id, name, is_internal) VALUES
  ('00000000-0000-0000-0000-0000000000c0', 'Своё',    true),
  ('00000000-0000-0000-0000-0000000000c1', 'Вектор',  false),
  ('00000000-0000-0000-0000-0000000000c2', 'Ромашка', false);
INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version) VALUES
  ('00000000-0000-0000-0000-0000000000f1', 'agent_token', '\x00', '\x00', 1);
INSERT INTO inv.server (id, name, host, agent_fingerprint, agent_token_id) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'shared', '203.0.113.10', decode(repeat('ab', 32), 'hex'), '00000000-0000-0000-0000-0000000000f1'),
  ('00000000-0000-0000-0000-0000000000b2', 'vector', '203.0.113.11', decode(repeat('cd', 32), 'hex'), '00000000-0000-0000-0000-0000000000f1');
INSERT INTO inv.vpn_key (id, server_id, container, public_key, name) VALUES
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b2', 'amnezia-awg2', 'pk1', 'iphone');
INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'server', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000c2', 'server', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000c1', 'server', '00000000-0000-0000-0000-0000000000b2'),
  ('00000000-0000-0000-0000-0000000000c1', 'vpn_key', '00000000-0000-0000-0000-0000000000e1');

-- Иван: клиент «Вектор» — смотреть и перезагружать; Анна отключена, но с выдачей «на всё»
INSERT INTO acc.access_grant (id, account_id, scope_type, scope_id, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a2', 'client',
   '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a3', 'all',
   NULL, '00000000-0000-0000-0000-0000000000a1');
INSERT INTO acc.grant_permission VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'view', 'allow'),
  ('00000000-0000-0000-0000-0000000000d1', 'reboot_server', 'allow'),
  ('00000000-0000-0000-0000-0000000000d1', 'vpn_keys_delete', 'approval'),
  ('00000000-0000-0000-0000-0000000000d3', 'view', 'allow');

SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a1', 'reboot_server', 'server', '00000000-0000-0000-0000-0000000000b1'), 'allow', 'владелец может всё');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'reboot_server', 'server', '00000000-0000-0000-0000-0000000000b2'), 'allow', 'выдача на клиента действует на его сервер');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'view', 'server', '00000000-0000-0000-0000-0000000000b1'), 'allow', 'общий сервер: смотреть хватает одного клиента');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'reboot_server', 'server', '00000000-0000-0000-0000-0000000000b1'), 'deny', 'общий сервер: перезагрузка требует всех клиентов');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'ssh', 'server', '00000000-0000-0000-0000-0000000000b2'), 'deny', 'невыданное право запрещено');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'vpn_keys_delete', 'vpn_key', '00000000-0000-0000-0000-0000000000e1'), 'approval', 'VPN-ключ: удаление с подтверждением');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a3', 'view', 'server', '00000000-0000-0000-0000-0000000000b2'), 'deny', 'отключённый сотрудник не может ничего');

-- Выдача на сам сервер главнее выдачи на клиента
INSERT INTO acc.access_grant (id, account_id, scope_type, scope_id, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'server',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1');
INSERT INTO acc.grant_permission VALUES ('00000000-0000-0000-0000-0000000000d2', 'reboot_server', 'approval');
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'reboot_server', 'server', '00000000-0000-0000-0000-0000000000b1'), 'approval', 'выдача на сервер главнее клиента');

-- Истёкшая выдача не действует
UPDATE acc.access_grant SET expires_at = now() - interval '1 minute' WHERE id = '00000000-0000-0000-0000-0000000000d1';
SELECT pg_temp.expect(acc.permission_mode('00000000-0000-0000-0000-0000000000a2', 'view', 'server', '00000000-0000-0000-0000-0000000000b2'), 'deny', 'истёкшая выдача не действует');

-- Владелец только один, клиент «Своё» только один
DO $$ BEGIN
  INSERT INTO acc.account (login, display_name, kind) VALUES ('owner2', 'Второй', 'owner');
  RAISE EXCEPTION 'FAIL второй владелец создан';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'ok   второго владельца нет';
END $$;

-- Открытая проблема по одному ключу только одна
INSERT INTO ops.incident (object_type, object_id, object_name, key, kind, severity, message, started_at)
VALUES ('server', '00000000-0000-0000-0000-0000000000b1', 'shared', 'disk:/', 'disk_full', 1, 'диск 91%', now());
DO $$ BEGIN
  INSERT INTO ops.incident (object_type, object_id, object_name, key, kind, severity, message, started_at)
  VALUES ('server', '00000000-0000-0000-0000-0000000000b1', 'shared', 'disk:/', 'disk_full', 1, 'диск 92%', now());
  RAISE EXCEPTION 'FAIL две открытые проблемы';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'ok   открытая проблема одна';
END $$;
UPDATE ops.incident SET ended_at = started_at + interval '90 seconds';
SELECT pg_temp.expect((SELECT duration_s::text FROM ops.incident), '90', 'длительность проблемы считается сама');

-- id по умолчанию — UUIDv7
SELECT pg_temp.expect((SELECT uuid_extract_version(id)::text FROM ops.incident), '7', 'id генерируются как UUIDv7');

-- Метрики пишутся в партицию сегодняшнего дня; журнал и аудит — в партицию месяца
INSERT INTO mon.server_sample (server_id, ts, cpu) VALUES ('00000000-0000-0000-0000-0000000000b1', now(), 12.5);
INSERT INTO ops.event (ts, object_type, kind, key, severity, message) VALUES (now(), 'server', 'info', 'x', 1, 'test');
INSERT INTO ops.audit_log (actor_kind, actor_name, action, object_type, result) VALUES ('system', 'Мониторинг', 'login', 'app', 'done');
SELECT pg_temp.expect((SELECT count(*)::text FROM mon.server_sample), '1', 'запись в сегодняшнюю партицию');

-- Через 40 дней сегодняшняя партиция метрик удаляется, а журнал остаётся
SELECT pg_temp.expect(
  (SELECT count(*)::text FROM sys.maintain_partitions(now() + interval '40 days')
   WHERE action = 'dropped' AND partition_name = 'mon.server_sample_' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD')),
  '1', 'старая партиция метрик удаляется');
SELECT pg_temp.expect((SELECT count(*)::text FROM mon.server_sample), '0', 'старые метрики ушли вместе с партицией');
SELECT pg_temp.expect((SELECT count(*)::text FROM ops.event), '1', 'журнал за 40 дней не тронут');
SELECT pg_temp.expect(
  (SELECT count(*)::text FROM sys.maintain_partitions(now() + interval '40 days') WHERE action = 'created'),
  '0', 'повторный вызов ничего не создаёт');

ROLLBACK;
\echo 'all checks passed'
