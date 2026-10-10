-- Первая миграция базы хаба мониторинга. PostgreSQL 18+.
-- Пояснения и решения: docs/db-schema.md. Утверждено Михаилом 2026-10-10.
-- Правило как в Store.swift: вышедшую миграцию не меняем, изменения — новым файлом 0002_…sql.
-- Хаб выполняет файл целиком одним скриптом (в нём есть функции с $$, делить по «;» нельзя) и сам
-- ведёт учёт применённых миграций в своей таблице public.schema_migrations.
--
-- Соглашения: id — uuid версии 7 (встроенная в PostgreSQL 18 uuidv7(): id идут по времени,
-- индексы не разбухают); время — timestamptz, в базе всё в UTC; дни отчётов — date в часовом поясе
-- клиента; деньги — numeric(12,2). Расширение одно — citext (входит в PostgreSQL).
-- Удаление объектов «мягкое» (archived_at): история остаётся.
-- Схемы (папки таблиц):
--   sys — настройки, секреты, файлы, служебное состояние хаба
--   acc — люди, вход, права, персонализация
--   inv — клиенты и объекты (серверы, сайты, VPN-ключи, домены)
--   mon — метрики и проверки (временные ряды и сводки)
--   ops — проблемы, события, прогнозы, аудит
--   ntf — уведомления (Telegram, почта, push, macOS)
--   rep — месячные отчёты клиентам

CREATE EXTENSION IF NOT EXISTS citext;
CREATE SCHEMA sys; CREATE SCHEMA acc; CREATE SCHEMA inv; CREATE SCHEMA mon;
CREATE SCHEMA ops; CREATE SCHEMA ntf; CREATE SCHEMA rep;

-- ═════════════════════════════ sys ═════════════════════════════

-- Секреты, которые хабу нужны без человека: токены агентов, пароли сайтов за HTTP-авторизацией,
-- TOTP-секреты сотрудников. Только шифротекст: AES-256-GCM, AAD = id || kind.
-- Ключ шифрования НЕ в базе: systemd credential на хабе (файл 0400). Украденная копия базы
-- или бэкап без ключа бесполезны. Ротация: key_version + фоновое перешифрование.
-- Глобальные секреты (токен Telegram-бота, адрес внешнего пульса) — тоже systemd credential, не здесь.
-- SSH-ключи root на хаб не переносятся: перезагрузки, контейнеры, VPN-ключи и установка агента
-- остаются за Mac под Рутокеном (взлом хаба не должен давать root на всех серверах).
CREATE TABLE sys.secret (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  kind        text NOT NULL CHECK (kind IN ('agent_token','site_password','totp','api_token','other')),
  ciphertext  bytea NOT NULL,
  nonce       bytea NOT NULL,
  key_version int   NOT NULL,
  label       text  NOT NULL DEFAULT '',   -- «токен агента wise1», без значения
  created_at  timestamptz NOT NULL DEFAULT now(),
  rotated_at  timestamptz
);

-- Файлы (PDF отчётов, логотип, аватары): содержимое на диске хаба, в базе описание и хэш.
CREATE TABLE sys.file (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  kind        text NOT NULL CHECK (kind IN ('report_pdf','logo','avatar','export')),
  storage_key text NOT NULL UNIQUE,
  mime        text NOT NULL,
  size_bytes  bigint NOT NULL,
  sha256      bytea NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Настройки всей установки (одна строка, меняет владелец): название, брендинг отчётов, политика входа.
CREATE TABLE sys.org_settings (
  id                      boolean PRIMARY KEY DEFAULT true CHECK (id),
  company_name            text NOT NULL DEFAULT '',
  logo_file_id            uuid REFERENCES sys.file,
  brand_color             text,
  report_footer           text NOT NULL DEFAULT '',
  contact_email           text,
  contact_phone           text,
  default_timezone        text NOT NULL DEFAULT 'Europe/Moscow',
  default_locale          text NOT NULL DEFAULT 'ru',
  require_mfa             boolean NOT NULL DEFAULT true,
  session_timeout_minutes int NOT NULL DEFAULT 720,
  password_policy         jsonb NOT NULL DEFAULT '{}',
  default_thresholds      jsonb NOT NULL DEFAULT
    '{"disk_percent":90,"cpu_percent":90,"cpu_minutes":5,"memory_percent":90,"tls_days":14,"domain_days":14}',
  updated_at              timestamptz NOT NULL DEFAULT now(),
  updated_by              uuid
);

-- Служебное состояние, которое переживает перезапуск хаба (было kv в SQLite):
-- lastGoodRound, смещение getUpdates Telegram-бота и т.п.
CREATE TABLE sys.kv (
  key text PRIMARY KEY, value jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());

-- Самоконтроль хаба: видно «хаб жив, но опрос завис». 7 дней.
CREATE TABLE sys.job_run (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job         text NOT NULL,              -- poll_round, rollup, prune, forecast, report, backup, partitions
  started_at  timestamptz NOT NULL,
  finished_at timestamptz,
  ok          boolean,
  detail      jsonb NOT NULL DEFAULT '{}',-- для пульса: servers_ok/total, sites_ok/total
  error       text
);
CREATE INDEX job_run_job_time ON sys.job_run (job, started_at DESC);

-- Перенос истории из SQLite на Mac (идемпотентный, можно повторять).
CREATE TABLE sys.import_batch (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  source      text NOT NULL,              -- имя Mac
  source_table text NOT NULL,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  rows        bigint NOT NULL DEFAULT 0,
  status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','done','failed')),
  error       text
);
-- Старые текстовые id из servers.json и clients.json → новые uuid.
CREATE TABLE sys.legacy_id (
  kind      text NOT NULL CHECK (kind IN ('server','site','vpn_key')),  -- для vpn_key legacy_id = публичный ключ
  legacy_id text NOT NULL,
  id        uuid NOT NULL,
  PRIMARY KEY (kind, legacy_id)
);

-- ═════════════════════════════ acc ═════════════════════════════

CREATE TABLE acc.account (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  login             citext NOT NULL UNIQUE,
  display_name      text NOT NULL,
  email             citext,
  kind              text NOT NULL CHECK (kind IN ('owner','staff')),  -- 'client' (кабинет клиента) — позже
  status            text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','active','disabled')),
  access_expires_at timestamptz,          -- доступ до даты
  note              text NOT NULL DEFAULT '',
  avatar_file_id    uuid REFERENCES sys.file,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES acc.account,
  disabled_at       timestamptz,
  disabled_by       uuid REFERENCES acc.account,
  last_login_at     timestamptz
);
CREATE UNIQUE INDEX account_one_owner ON acc.account ((true)) WHERE kind = 'owner';
ALTER TABLE sys.org_settings ADD FOREIGN KEY (updated_by) REFERENCES acc.account;

CREATE TABLE acc.account_password (
  account_id  uuid PRIMARY KEY REFERENCES acc.account ON DELETE CASCADE,
  hash        text NOT NULL,              -- argon2id
  changed_at  timestamptz NOT NULL DEFAULT now(),
  must_change boolean NOT NULL DEFAULT false
);
CREATE TABLE acc.account_mfa (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id   uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  type         text NOT NULL CHECK (type IN ('totp','webauthn','rutoken')),
  secret_id    uuid REFERENCES sys.secret,     -- totp
  public_key   bytea,                          -- webauthn / rutoken
  label        text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  CHECK (num_nonnulls(secret_id, public_key) = 1)
);
CREATE TABLE acc.recovery_code (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  code_hash  text NOT NULL,
  used_at    timestamptz
);
CREATE TABLE acc.invite (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,       -- sha256 ссылки-приглашения
  expires_at timestamptz NOT NULL,        -- 48 ч
  used_at    timestamptz,
  created_by uuid NOT NULL REFERENCES acc.account
);
CREATE TABLE acc.session (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id   uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE,
  device_name  text NOT NULL DEFAULT '',
  ip           inet,
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  step_up_at   timestamptz,               -- когда последний раз ввёл код 2FA повторно (перед опасным действием)
  revoked_at   timestamptz                -- отключение сотрудника = revoked_at всем его сессиям
);
CREATE INDEX session_live ON acc.session (account_id) WHERE revoked_at IS NULL;

-- Справочник прав (сид-данные внизу файла).
CREATE TABLE acc.permission (
  code         text PRIMARY KEY,
  grp          text NOT NULL,
  title        text NOT NULL,
  danger_level smallint NOT NULL DEFAULT 0 CHECK (danger_level BETWEEN 0 AND 2),
  sort         int NOT NULL DEFAULT 0
);

-- Шаблоны ролей: «Наблюдатель», «Дежурный», «Админ», «Оператор VPN» и свои.
CREATE TABLE acc.role_template (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  name        text NOT NULL UNIQUE,
  description text NOT NULL DEFAULT '',
  built_in    boolean NOT NULL DEFAULT false,
  created_by  uuid REFERENCES acc.account,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE acc.role_template_permission (
  template_id     uuid NOT NULL REFERENCES acc.role_template ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES acc.permission,
  mode            text NOT NULL CHECK (mode IN ('allow','approval','deny')),
  PRIMARY KEY (template_id, permission_code)
);

-- Выдача доступа: кому, на что (всё / клиент / сервер / сайт), до какого времени.
-- Права выдачи — в grant_permission (копия шаблона, которую можно подправить галочками).
-- Как решается «можно ли» — функция acc.permission_mode() ниже.
CREATE TABLE acc.access_grant (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id  uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  scope_type  text NOT NULL CHECK (scope_type IN ('all','client','server','site')),
  scope_id    uuid,
  template_id uuid REFERENCES acc.role_template ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid NOT NULL REFERENCES acc.account,
  expires_at  timestamptz,
  CHECK ((scope_type = 'all') = (scope_id IS NULL))
);
CREATE UNIQUE INDEX access_grant_scope ON acc.access_grant
  (account_id, scope_type, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'));
CREATE TABLE acc.grant_permission (
  grant_id        uuid NOT NULL REFERENCES acc.access_grant ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES acc.permission,
  mode            text NOT NULL CHECK (mode IN ('allow','approval','deny')),
  PRIMARY KEY (grant_id, permission_code)
);

-- Опасное действие с mode='approval' ждёт подтверждения владельца.
CREATE TABLE acc.approval_request (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  requested_by    uuid NOT NULL REFERENCES acc.account,
  permission_code text NOT NULL REFERENCES acc.permission,
  object_type     text NOT NULL,
  object_id       uuid,
  detail          jsonb NOT NULL DEFAULT '{}',
  reason          text NOT NULL DEFAULT '',
  status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected','expired','executed')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,   -- например, через 30 минут
  decided_by      uuid REFERENCES acc.account,
  decided_at      timestamptz,
  executed_audit_id uuid
);
CREATE INDEX approval_pending ON acc.approval_request (created_at) WHERE status = 'pending';

-- Личные SSH-ключи сотрудников. Раскладывает их на серверы Mac владельца (под Рутокеном),
-- хаб только хранит задания: отзыв на хабе мгновенный, снятие с серверов — когда Mac онлайн.
CREATE TABLE acc.staff_ssh_key (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id  uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  public_key  text NOT NULL,
  fingerprint text NOT NULL UNIQUE,
  label       text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz
);

-- Персонализация. Владелец задаёт значения по умолчанию; locked = сотрудник не может поменять.
-- Ключ-значение, чтобы новые настройки добавлялись без миграции базы. Ключи:
-- theme (system|light|dark), accent, density (compact|normal), font_size, start_page, locale (ru|en),
-- timezone, time_format, date_format, units_traffic (бит/байт), chart_default_period,
-- map_mode_default, map_layers_default, table_columns.<таблица>, saved_filters, pinned_objects,
-- sidebar_order, dashboard_layout, sound, reduce_motion.
-- Настройки уведомлений — отдельная типизированная таблица ntf.prefs (их читает движок оповещений).
CREATE TABLE acc.default_preference (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  locked     boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE acc.preference (
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  key        text NOT NULL,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, key)
);

-- Дежурства: кому идут ночные тревоги в эту смену.
CREATE TABLE acc.duty_shift (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  starts_at  timestamptz NOT NULL,
  ends_at    timestamptz NOT NULL,
  CHECK (ends_at > starts_at)
);

-- ═════════════════════════════ inv ═════════════════════════════

-- Клиент — тот, за чьи серверы, сайты и VPN вы отвечаете. Своя инфраструктура — клиент «Своё»
-- (is_internal, ровно один), так у каждого объекта всегда есть клиент и фильтры одинаковые.
CREATE TABLE inv.client (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  name        text NOT NULL UNIQUE,
  short_name  text,
  kind        text NOT NULL DEFAULT 'company' CHECK (kind IN ('company','person')),
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','ended')),
  is_internal boolean NOT NULL DEFAULT false,
  color       text,                       -- метка на карте: blue, green, orange…
  legal_name  text,
  inn         text,
  timezone    text NOT NULL DEFAULT 'Europe/Moscow',
  notes       text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES acc.account,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);
CREATE UNIQUE INDEX client_one_internal ON inv.client ((true)) WHERE is_internal;

CREATE TABLE inv.client_contact (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  client_id        uuid NOT NULL REFERENCES inv.client ON DELETE CASCADE,
  name             text NOT NULL,
  role             text NOT NULL DEFAULT 'other' CHECK (role IN ('owner','tech','billing','other')),
  email            citext,
  phone            text,
  telegram         text,                 -- как ввели в приложении: @username или ссылка
  telegram_chat_id bigint,              -- появляется после привязки через бота
  receives_report  boolean NOT NULL DEFAULT true,
  receives_alerts  boolean NOT NULL DEFAULT false,  -- задел: решение Михаила 2026-10-10 — тревоги клиентам пока не шлём
  sort             int NOT NULL DEFAULT 0
);

-- Договор и тариф с историей: отчёт за прошлый месяц берёт тариф, действовавший тогда.
CREATE TABLE inv.client_contract (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  client_id     uuid NOT NULL REFERENCES inv.client ON DELETE CASCADE,
  plan_name     text NOT NULL,            -- «Базовый»
  monthly_price numeric(12,2) NOT NULL,
  currency      char(3) NOT NULL DEFAULT 'RUB',
  billing_day   smallint CHECK (billing_day BETWEEN 1 AND 31),
  sla_uptime    numeric(6,3),             -- обещанная доступность, %, например 99.500
  started_on    date NOT NULL,
  ended_on      date,
  CHECK (ended_on IS NULL OR ended_on >= started_on)
);

CREATE TABLE inv.server (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  name              text NOT NULL,
  host              text NOT NULL,
  agent_port        int  NOT NULL DEFAULT 9443,
  agent_fingerprint bytea NOT NULL CHECK (length(agent_fingerprint) = 32),  -- sha256 сертификата агента
  agent_token_id    uuid NOT NULL REFERENCES sys.secret,
  agent_version     text,
  ssh_target        text,                 -- user@host:port, без секретов
  provider          text,
  country           char(2),
  role              text,                 -- vpn, sites, db, proxy
  monthly_cost      numeric(12,2),        -- сколько сервер стоит вам
  currency          char(3),
  pay_day           smallint CHECK (pay_day BETWEEN 1 AND 31),
  thresholds        jsonb NOT NULL DEFAULT '{}',  -- только переопределённые поля
  tags              text[] NOT NULL DEFAULT '{}', -- сюда переезжает старое поле group
  position          int NOT NULL DEFAULT 0,
  paused            boolean NOT NULL DEFAULT false,
  maintenance_until timestamptz,          -- тревоги молчат во время работ
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES acc.account,
  archived_at       timestamptz
);

CREATE TABLE inv.site (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  hosting_server_id uuid REFERENCES inv.server ON DELETE SET NULL,  -- где сайт живёт
  name              text NOT NULL,
  url               text NOT NULL,
  expect_status     int[],                -- null = 2xx/3xx/401/403 считаются «жив» (как сейчас)
  expect_text       text,
  auth_user         text,
  auth_password_id  uuid REFERENCES sys.secret,
  thresholds        jsonb NOT NULL DEFAULT '{}',  -- domain_days, tls_days, latency_ms
  tags              text[] NOT NULL DEFAULT '{}',
  position          int NOT NULL DEFAULT 0,
  paused            boolean NOT NULL DEFAULT false,
  maintenance_until timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES acc.account,
  archived_at       timestamptz
);

-- Ключ VPN как отдельная сущность. Приватный ключ не хранится: конфиг отдаётся один раз.
CREATE TABLE inv.vpn_key (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  server_id           uuid NOT NULL REFERENCES inv.server,
  container           text NOT NULL,      -- amnezia-awg2
  protocol            text NOT NULL DEFAULT 'awg',
  public_key          text NOT NULL,
  name                text NOT NULL,
  address             cidr,
  owner_name          text,               -- человек, у которого ключ
  expires_at          timestamptz,
  traffic_limit_bytes bigint,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES acc.account,
  revoked_at          timestamptz,
  revoked_by          uuid REFERENCES acc.account,
  UNIQUE (server_id, public_key)
);

-- Чьё это: объект → клиент(ы), с историей. Общий сервер может обслуживать нескольких клиентов
-- (share_pct — доля стоимости, пусто = поровну). until нужен, чтобы отчёт за прошлый месяц
-- считался по тому, что принадлежало клиенту тогда. Новые объекты по умолчанию — клиенту «Своё».
CREATE TABLE inv.client_asset (
  client_id  uuid NOT NULL REFERENCES inv.client,
  asset_type text NOT NULL CHECK (asset_type IN ('server','site','vpn_key','check')),
  asset_id   uuid NOT NULL,
  share_pct  numeric(5,2) CHECK (share_pct > 0 AND share_pct <= 100),
  since      date NOT NULL DEFAULT current_date,
  until      date,
  PRIMARY KEY (client_id, asset_type, asset_id, since),
  CHECK (until IS NULL OR until >= since)
);
CREATE INDEX client_asset_current ON inv.client_asset (asset_type, asset_id) WHERE until IS NULL;

-- Точки проверки: каждый агент, сам хаб, Mac («из дома»). Пустой список у сайта = все точки.
CREATE TABLE inv.probe (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  kind         text NOT NULL CHECK (kind IN ('agent','hub','mac')),
  server_id    uuid UNIQUE REFERENCES inv.server ON DELETE CASCADE,
  name         text NOT NULL,
  country      char(2),
  version      text,
  last_seen_at timestamptz,
  CHECK ((kind = 'agent') = (server_id IS NOT NULL))
);
CREATE TABLE inv.site_probe (
  site_id  uuid NOT NULL REFERENCES inv.site ON DELETE CASCADE,
  probe_id uuid NOT NULL REFERENCES inv.probe ON DELETE CASCADE,
  PRIMARY KEY (site_id, probe_id)
);

-- Сроки, на которых строятся прогнозы.
CREATE TABLE inv.domain (
  name       citext PRIMARY KEY,
  registrar  text,
  expires_at timestamptz,
  checked_at timestamptz,
  error      text
);
CREATE TABLE inv.certificate (
  host       citext NOT NULL,
  port       int NOT NULL DEFAULT 443,
  issuer     text,
  expires_at timestamptz,
  checked_at timestamptz NOT NULL,
  error      text,
  PRIMARY KEY (host, port)
);

-- Задания для Mac: поставить или снять ключ сотрудника на сервере.
CREATE TABLE acc.staff_ssh_key_install (
  key_id       uuid NOT NULL REFERENCES acc.staff_ssh_key ON DELETE CASCADE,
  server_id    uuid NOT NULL REFERENCES inv.server ON DELETE CASCADE,
  want         text NOT NULL CHECK (want IN ('installed','removed')),
  installed_at timestamptz,
  removed_at   timestamptz,
  last_error   text,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (key_id, server_id)
);

-- ═════════════════════════════ mon ═════════════════════════════
-- Сырые ряды режутся на партиции по дню: старый день удаляется одной командой DROP за миллисекунды,
-- база не разбухает. Партиции на 7 дней вперёд создаёт задача хаба (без расширений).
-- Сводки по часу — партиции по месяцу, 1 год. Дневные сводки — без партиций, ≥ 2 лет (отчёты, тренды).
-- Внешние ключи на сырых рядах не ставятся (скорость записи); целостность держит хаб.

CREATE TABLE mon.latest_snapshot (
  server_id uuid PRIMARY KEY REFERENCES inv.server ON DELETE CASCADE,
  ts        timestamptz NOT NULL,
  snapshot  jsonb NOT NULL                -- последний снимок агента целиком
);

-- Ключевые метрики раз в минуту, 30 дней.
CREATE TABLE mon.server_sample (
  server_id   uuid NOT NULL,
  ts          timestamptz NOT NULL,
  cpu real, iowait real, steal real, mem real, swap real,
  disk_max    real,                       -- самый заполненный диск, %
  load1       real,
  rx_bps real, tx_bps real,
  vpn_clients smallint,
  PRIMARY KEY (server_id, ts)
) PARTITION BY RANGE (ts);

-- Дошёл ли опрос до агента и кто опрашивал (хаб или Mac), 30 дней.
CREATE TABLE mon.poll (
  server_id  uuid NOT NULL,
  probe_id   uuid NOT NULL,
  ts         timestamptz NOT NULL,
  ok         boolean NOT NULL,
  latency_ms real,
  error      text,
  PRIMARY KEY (server_id, probe_id, ts)
) PARTITION BY RANGE (ts);

-- Диски по точкам монтирования (раз в 5 минут, 30 дней) — для прогноза «заполнится через N дней».
CREATE TABLE mon.disk_sample (
  server_id   uuid NOT NULL,
  mount       text NOT NULL,
  ts          timestamptz NOT NULL,
  used_bytes  bigint NOT NULL,
  total_bytes bigint NOT NULL,
  PRIMARY KEY (server_id, mount, ts)
) PARTITION BY RANGE (ts);

-- Контейнеры: CPU и память раз в минуту, 7 дней (дальше container_hourly).
CREATE TABLE mon.container_sample (
  server_id uuid NOT NULL,
  container text NOT NULL,
  ts        timestamptz NOT NULL,
  cpu       real,
  mem_bytes bigint,
  running   boolean NOT NULL,
  PRIMARY KEY (server_id, container, ts)
) PARTITION BY RANGE (ts);

-- Проверки сайтов из каждой точки, 30 дней.
CREATE TABLE mon.site_check (
  site_id    uuid NOT NULL,
  probe_id   uuid NOT NULL,
  ts         timestamptz NOT NULL,
  ok         boolean NOT NULL,
  status     smallint,
  latency_ms real,
  error      text,
  PRIMARY KEY (site_id, probe_id, ts)
) PARTITION BY RANGE (ts);

-- Задержка между серверами, 3 дня (дальше link_hourly).
CREATE TABLE mon.link_sample (
  server_id  uuid NOT NULL,
  peer_id    uuid NOT NULL,
  ts         timestamptz NOT NULL,
  ok         boolean NOT NULL,
  latency_ms real,
  PRIMARY KEY (server_id, peer_id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE mon.server_hourly (
  server_id uuid NOT NULL, hour timestamptz NOT NULL,
  cpu_avg real, cpu_max real, mem_avg real, mem_max real, disk_max real,
  load1_avg real, rx_avg real, tx_avg real, vpn_max smallint,
  samples smallint NOT NULL, polls_ok smallint NOT NULL, polls_total smallint NOT NULL,
  PRIMARY KEY (server_id, hour)
) PARTITION BY RANGE (hour);
CREATE TABLE mon.container_hourly (
  server_id uuid NOT NULL, container text NOT NULL, hour timestamptz NOT NULL,
  cpu_avg real, cpu_max real, mem_avg bigint, mem_max bigint, running_minutes smallint,
  PRIMARY KEY (server_id, container, hour)
) PARTITION BY RANGE (hour);
CREATE TABLE mon.site_hourly (
  site_id uuid NOT NULL, probe_id uuid NOT NULL, hour timestamptz NOT NULL,
  ok smallint NOT NULL, total smallint NOT NULL, latency_avg real, latency_p95 real,
  PRIMARY KEY (site_id, probe_id, hour)
) PARTITION BY RANGE (hour);
CREATE TABLE mon.link_hourly (
  server_id uuid NOT NULL, peer_id uuid NOT NULL, hour timestamptz NOT NULL,
  ok smallint NOT NULL, total smallint NOT NULL, latency_ms real,
  PRIMARY KEY (server_id, peer_id, hour)
) PARTITION BY RANGE (hour);

-- Дневные итоги (≥ 2 лет): графики за год, отчёты, долгие прогнозы. Считаются раз в сутки
-- за вчера и пересчитываются за 2 прошлых дня (поздние данные агента).
CREATE TABLE mon.server_daily (
  server_id uuid NOT NULL REFERENCES inv.server ON DELETE CASCADE, day date NOT NULL,
  cpu_avg real, cpu_max real, mem_avg real, mem_max real, disk_max_pct real,
  rx_bytes bigint, tx_bytes bigint, vpn_max smallint, reboots smallint NOT NULL DEFAULT 0,
  checks_total int NOT NULL, checks_ok int NOT NULL, downtime_s int NOT NULL DEFAULT 0,
  PRIMARY KEY (server_id, day)
);
CREATE TABLE mon.site_daily (
  site_id uuid NOT NULL REFERENCES inv.site ON DELETE CASCADE, day date NOT NULL,
  checks_total int NOT NULL, checks_ok int NOT NULL,
  downtime_s int NOT NULL DEFAULT 0,      -- «упал» = не отвечает из ≥ 2 стран
  latency_avg_ms real, latency_p95_ms real,
  PRIMARY KEY (site_id, day)
);
CREATE TABLE mon.disk_daily (
  server_id uuid NOT NULL REFERENCES inv.server ON DELETE CASCADE, mount text NOT NULL, day date NOT NULL,
  used_bytes bigint NOT NULL, total_bytes bigint NOT NULL,
  PRIMARY KEY (server_id, mount, day)
);
CREATE TABLE mon.db_daily (
  server_id uuid NOT NULL REFERENCES inv.server ON DELETE CASCADE,
  container text NOT NULL, db_name text NOT NULL, day date NOT NULL,
  size_bytes bigint NOT NULL, connections_max int, connections_limit int,
  PRIMARY KEY (server_id, container, db_name, day)
);

-- Трафик VPN-ключей: последний счётчик и сумма по дням (1 год).
CREATE TABLE mon.vpn_counter (
  vpn_key_id        uuid PRIMARY KEY REFERENCES inv.vpn_key ON DELETE CASCADE,
  rx bigint NOT NULL, tx bigint NOT NULL,
  seen_at           timestamptz NOT NULL,
  last_handshake_at timestamptz
);
CREATE TABLE mon.vpn_traffic_daily (
  vpn_key_id uuid NOT NULL REFERENCES inv.vpn_key ON DELETE CASCADE,
  day date NOT NULL, rx bigint NOT NULL DEFAULT 0, tx bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (vpn_key_id, day)
);

-- Резервные копии с историей (сейчас агент отдаёт только «последняя и сколько»).
CREATE TABLE mon.backup_run (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  server_id         uuid NOT NULL REFERENCES inv.server ON DELETE CASCADE,
  target            text NOT NULL,        -- контейнер / база
  kind              text NOT NULL DEFAULT 'nightly' CHECK (kind IN ('nightly','manual')),
  started_at        timestamptz NOT NULL,
  finished_at       timestamptz,
  ok                boolean,
  size_bytes        bigint,
  error             text,
  restore_tested_at timestamptz
);
CREATE INDEX backup_run_server ON mon.backup_run (server_id, started_at DESC);

-- ═════════════════════════════ ops ═════════════════════════════

-- Внутреннее состояние движка тревог: условие замечено, но ещё не подтверждено (bad_streak),
-- или уже горит. Переживает перезапуск хаба, чтобы не было повторных оповещений.
CREATE TABLE ops.alert_state (
  object_type   text NOT NULL,
  object_id     uuid NOT NULL,
  key           text NOT NULL,            -- disk:/, down, tls, svc:nginx (как в Alerts.swift)
  severity      smallint NOT NULL,
  message       text NOT NULL,
  first_seen_at timestamptz NOT NULL,
  last_seen_at  timestamptz NOT NULL,
  bad_streak    int NOT NULL DEFAULT 1,
  incident_id   uuid,                     -- заполняется, когда тревога «зажглась»
  PRIMARY KEY (object_type, object_id, key)
);

-- Проблема (инцидент): зажглась → взяли в работу → решена. Открытые = экран «Проблемы».
-- На неё ссылаются Telegram (ответ «решено» в ту же ветку), журнал и месячный отчёт.
CREATE TABLE ops.incident (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  object_type    text NOT NULL CHECK (object_type IN ('server','site','vpn_key','domain','hub')),
  object_id      uuid,
  object_name    text NOT NULL,           -- снимок имени
  key            text NOT NULL,
  kind           text NOT NULL,           -- down, slow, tls, domain, disk_full, backup_failed, service, container…
  severity       smallint NOT NULL CHECK (severity IN (1,2)),  -- 1 предупреждение, 2 критично
  message        text NOT NULL,
  started_at     timestamptz NOT NULL,
  ended_at       timestamptz,
  duration_s     int GENERATED ALWAYS AS (extract(epoch FROM ended_at - started_at)::int) STORED,
  cause          text,                    -- можно дописать руками для отчёта
  resolution     text,                    -- что сделали
  resolved_by    uuid REFERENCES acc.account,   -- null = прошло само
  client_visible boolean NOT NULL DEFAULT true,
  last_notified_at timestamptz,
  reminders      int NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX incident_open ON ops.incident (object_type, object_id, key) WHERE ended_at IS NULL;
CREATE INDEX incident_object_time ON ops.incident (object_id, started_at DESC);
CREATE INDEX incident_time ON ops.incident (started_at DESC);
ALTER TABLE ops.alert_state ADD FOREIGN KEY (incident_id) REFERENCES ops.incident ON DELETE SET NULL;

-- Кто взял проблему. Первый ack останавливает напоминания всем и показывает «взял Иван».
CREATE TABLE ops.incident_ack (
  incident_id uuid NOT NULL REFERENCES ops.incident ON DELETE CASCADE,
  account_id  uuid NOT NULL REFERENCES acc.account,
  acked_at    timestamptz NOT NULL DEFAULT now(),
  via         text NOT NULL CHECK (via IN ('telegram','app','web')),
  PRIMARY KEY (incident_id, account_id)
);

-- Журнал «События»: зажглось/погасло/напоминание, перезагрузки, контейнеры. ≥ 1 года, партиции по месяцу.
CREATE TABLE ops.event (
  id          bigint GENERATED ALWAYS AS IDENTITY,
  ts          timestamptz NOT NULL,
  object_type text NOT NULL,
  object_id   uuid,
  kind        text NOT NULL,              -- fired, resolved, reminder, info, reboot, container_start…
  key         text NOT NULL,
  severity    smallint NOT NULL,
  message     text NOT NULL,
  incident_id uuid,
  actor_id    uuid,                       -- null = система
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX event_ts ON ops.event (ts DESC);
CREATE INDEX event_object_ts ON ops.event (object_id, ts DESC);

-- Прогноз с историей: открыт → предотвращён / случился / отклонён. Основа блока
-- «Предотвращено» в отчёте: исчез до due_at и без инцидента = prevented.
CREATE TABLE ops.forecast (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  stable_key       text NOT NULL,         -- как ForecastItem.id сейчас
  object_type      text NOT NULL,
  object_id        uuid,
  kind             text NOT NULL,         -- disk_full, tls_expiry, domain_expiry, payment, backup_stale,
                                          -- security_updates, reboot_pending, db_growth
  line             text NOT NULL,
  due_at           timestamptz,           -- когда случилось бы; null для заметок «обслуживание»
  confidence       real,
  detail           jsonb NOT NULL DEFAULT '{}',
  first_seen_at    timestamptz NOT NULL,
  last_seen_at     timestamptz NOT NULL,
  last_notified_at timestamptz,
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','prevented','happened','dismissed')),
  closed_at        timestamptz,
  closed_by        uuid REFERENCES acc.account,
  incident_id      uuid REFERENCES ops.incident,
  note             text,                  -- для клиента: «почистили логи, +18 ГБ»
  client_visible   boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX forecast_open_key ON ops.forecast (stable_key) WHERE status = 'open';
CREATE INDEX forecast_object ON ops.forecast (object_id, first_seen_at DESC);

-- Аудит: каждое действие человека и каждый отказ. Только добавление: у роли хаба нет
-- UPDATE/DELETE на эту таблицу. Партиции по месяцу, ≥ 1 года. Входы, неудачные входы,
-- смена прав, выдача и отзыв доступа — тоже сюда.
CREATE TABLE ops.audit_log (
  id          uuid NOT NULL DEFAULT uuidv7(),
  ts          timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid,
  actor_kind  text NOT NULL CHECK (actor_kind IN ('owner','staff','system')),
  actor_name  text NOT NULL,              -- снимок имени
  session_id  uuid,
  ip          inet,
  device      text,
  action      text NOT NULL,              -- код права или login, login_failed, grant_changed…
  object_type text NOT NULL,
  object_id   uuid,
  object_name text NOT NULL DEFAULT '',
  client_ids  uuid[] NOT NULL DEFAULT '{}', -- снимок: чьи это объекты были в момент действия
  detail      jsonb NOT NULL DEFAULT '{}',
  result      text NOT NULL CHECK (result IN ('done','failed','denied','pending_approval')),
  error       text,
  approval_id uuid,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX audit_ts ON ops.audit_log (ts DESC);
CREATE INDEX audit_actor ON ops.audit_log (actor_id, ts DESC);
CREATE INDEX audit_object ON ops.audit_log (object_id, ts DESC);
CREATE INDEX audit_clients ON ops.audit_log USING gin (client_ids);

-- ═════════════════════════════ ntf ═════════════════════════════

-- Привязка человека или контакта клиента к Telegram (одноразовый код из бота).
CREATE TABLE ntf.telegram_link (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id  uuid REFERENCES acc.account ON DELETE CASCADE,
  contact_id  uuid REFERENCES inv.client_contact ON DELETE CASCADE,
  chat_id     bigint NOT NULL,
  tg_username text,
  linked_at   timestamptz NOT NULL DEFAULT now(),
  unlinked_at timestamptz,
  blocked_bot boolean NOT NULL DEFAULT false,  -- бот получил 403
  CHECK (num_nonnulls(account_id, contact_id) = 1)
);
CREATE UNIQUE INDEX telegram_link_chat ON ntf.telegram_link (chat_id) WHERE unlinked_at IS NULL;
CREATE UNIQUE INDEX telegram_link_account ON ntf.telegram_link (account_id) WHERE unlinked_at IS NULL;
CREATE TABLE ntf.link_code (
  code_hash  bytea PRIMARY KEY,
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,        -- +10 минут
  used_at    timestamptz
);

-- Устройства для push (iPhone позже) и других каналов, кроме Telegram.
CREATE TABLE ntf.device (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id  uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('push_ios','macos','email')),
  target      text NOT NULL,              -- токен устройства / адрес почты
  label       text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  disabled_at timestamptz
);

-- Личные настройки уведомлений: что и когда слать. О чём слать решают права:
-- человек получает тревоги по объектам, на которые у него есть право alerts_receive.
CREATE TABLE ntf.prefs (
  account_id        uuid PRIMARY KEY REFERENCES acc.account ON DELETE CASCADE,
  min_severity      smallint NOT NULL DEFAULT 1 CHECK (min_severity IN (1,2)),
  timezone          text,                 -- null = из профиля
  quiet_from        time,
  quiet_to          time,
  quiet_days        smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
  critical_in_quiet boolean NOT NULL DEFAULT true,
  on_duty_only      boolean NOT NULL DEFAULT false,
  digest_enabled    boolean NOT NULL DEFAULT true,   -- утренний «Прогноз»
  digest_time       time NOT NULL DEFAULT '09:00',
  group_window_s    int NOT NULL DEFAULT 60,         -- склеивать тревоги за минуту в одно сообщение
  channels          text[] NOT NULL DEFAULT '{telegram,macos}'
);

-- «Не беспокоить» по клиенту / объекту / проблеме, до времени или навсегда.
CREATE TABLE ntf.mute (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  account_id uuid NOT NULL REFERENCES acc.account ON DELETE CASCADE,
  scope_type text NOT NULL CHECK (scope_type IN ('client','server','site','incident')),
  scope_id   uuid NOT NULL,
  until      timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mute_account ON ntf.mute (account_id);

-- Единая очередь и история отправок во все каналы: тревоги, напоминания, дайджест, отчёты.
-- Хаб пишет событие и строки очереди в одной транзакции; отправщик берёт queued через
-- FOR UPDATE SKIP LOCKED. dedup_key не даёт отправить дважды после перезапуска. 1 год.
CREATE TABLE ntf.delivery (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  queued_at     timestamptz NOT NULL DEFAULT now(),
  kind          text NOT NULL CHECK (kind IN ('fired','reminder','resolved','digest','escalation',
                                              'bundle','report','approval','service')),
  account_id    uuid REFERENCES acc.account ON DELETE SET NULL,
  contact_id    uuid REFERENCES inv.client_contact ON DELETE SET NULL,
  channel       text NOT NULL CHECK (channel IN ('telegram','email','push_ios','macos')),
  target        text NOT NULL,            -- снимок: chat_id / адрес
  incident_id   uuid REFERENCES ops.incident ON DELETE SET NULL,
  report_id     uuid,
  dedup_key     text NOT NULL UNIQUE,
  payload       jsonb NOT NULL,
  status        text NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','sent','failed','dropped_quiet','dropped_muted')),
  attempts      smallint NOT NULL DEFAULT 0,
  next_attempt_at timestamptz,
  sent_at       timestamptz,
  external_id   text,                     -- message_id в Telegram: ответить «решено» в ту же ветку
  error         text,
  CHECK (num_nonnulls(account_id, contact_id) <= 1)
);
CREATE INDEX delivery_queue ON ntf.delivery (next_attempt_at) WHERE status = 'queued';
CREATE INDEX delivery_incident ON ntf.delivery (incident_id, account_id);

-- ═════════════════════════════ rep ═════════════════════════════

CREATE TABLE rep.client_report_settings (
  client_id     uuid PRIMARY KEY REFERENCES inv.client ON DELETE CASCADE,
  enabled       boolean NOT NULL DEFAULT true,
  day_of_month  smallint NOT NULL DEFAULT 1 CHECK (day_of_month BETWEEN 1 AND 28),
  send_time     time NOT NULL DEFAULT '09:00',
  mode          text NOT NULL DEFAULT 'review' CHECK (mode IN ('review','auto')), -- review = сначала вам
  locale        text NOT NULL DEFAULT 'ru',
  sections      jsonb NOT NULL DEFAULT
    '{"summary":true,"uptime":true,"incidents":true,"prevented":true,"work_done":true,"forecasts":true,"recommendations":true}',
  attach_pdf    boolean NOT NULL DEFAULT true,
  link_ttl_days int NOT NULL DEFAULT 365,
  extra_note    text NOT NULL DEFAULT ''
);

-- Отчёт за период — неизменяемый снимок цифр в data: удалили сайт или почистили историю,
-- отчёт не меняется. Перегенерация создаёт новую версию, старая становится superseded.
CREATE TABLE rep.client_report (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  client_id        uuid NOT NULL REFERENCES inv.client,
  period_start     date NOT NULL,
  period_end       date NOT NULL,
  template_version int NOT NULL DEFAULT 1,
  status           text NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','approved','sent','failed','superseded')),
  summary_status   text CHECK (summary_status IN ('ok','issues','critical')),
  data             jsonb NOT NULL,
  admin_comment    text NOT NULL DEFAULT '',
  pdf_file_id      uuid REFERENCES sys.file,
  generated_at     timestamptz NOT NULL DEFAULT now(),
  generated_by     uuid REFERENCES acc.account,   -- null = по расписанию
  approved_at      timestamptz,
  approved_by      uuid REFERENCES acc.account,
  supersedes_id    uuid REFERENCES rep.client_report,
  CHECK (period_end >= period_start)
);
CREATE UNIQUE INDEX client_report_period ON rep.client_report (client_id, period_start)
  WHERE status <> 'superseded';
ALTER TABLE ntf.delivery ADD FOREIGN KEY (report_id) REFERENCES rep.client_report ON DELETE SET NULL;

-- Ссылки для клиента: на конкретный отчёт или постоянная «все мои отчёты». Храним хэш токена.
CREATE TABLE rep.report_link (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  scope          text NOT NULL CHECK (scope IN ('report','client')),
  report_id      uuid REFERENCES rep.client_report ON DELETE CASCADE,
  client_id      uuid REFERENCES inv.client ON DELETE CASCADE,
  token_hash     bytea NOT NULL UNIQUE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES acc.account,
  expires_at     timestamptz,
  revoked_at     timestamptz,
  revoked_by     uuid REFERENCES acc.account,
  last_opened_at timestamptz,
  open_count     int NOT NULL DEFAULT 0,
  CHECK ((scope = 'report') = (report_id IS NOT NULL) AND (scope = 'client') = (client_id IS NOT NULL))
);

-- Работы для клиента («обновили пакеты безопасности, перезагрузка 3 мин ночью»).
-- Отдельно от аудита: аудит неизменяем, а пометку «показать клиенту» ставят потом.
-- Входы, права и секреты сюда не попадают никогда.
CREATE TABLE rep.work_item (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  client_id      uuid NOT NULL REFERENCES inv.client,
  object_type    text,
  object_id      uuid,
  done_at        timestamptz NOT NULL,
  client_text    text NOT NULL,
  minutes        int,
  author_id      uuid REFERENCES acc.account,
  audit_id       uuid,                    -- если взято из журнала действий
  client_visible boolean NOT NULL DEFAULT true
);
CREATE INDEX work_item_client ON rep.work_item (client_id, done_at);

-- ═════════════════════════════ проверка прав ═════════════════════════════
-- Режим права для человека над объектом: 'allow' | 'approval' | 'deny'.
--  • владелец может всё;
--  • выдачи с истёкшим сроком и отключённые люди не считаются;
--  • самый узкий уровень побеждает: объект (сайт/сервер; для VPN-ключа — его сервер) > клиент > всё;
--  • на одном уровне строже побеждает: deny > approval > allow;
--  • общий сервер нескольких клиентов: «посмотреть» (danger_level 0) — хватает доступа к одному
--    клиенту; опасное действие — нужен доступ ко всем его клиентам (или выдача на сам сервер).
CREATE FUNCTION acc.permission_mode(p_account uuid, p_perm text, p_type text, p_id uuid)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  acct   acc.account;
  danger smallint;
  obj_ids uuid[];          -- объект и (для vpn_key) его сервер
  clients uuid[];
  m      int;
  per_client int[];
BEGIN
  SELECT * INTO acct FROM acc.account WHERE id = p_account;
  IF acct IS NULL OR acct.status <> 'active' OR acct.access_expires_at < now() THEN RETURN 'deny'; END IF;
  IF acct.kind = 'owner' THEN RETURN 'allow'; END IF;
  SELECT danger_level INTO danger FROM acc.permission WHERE code = p_perm;
  IF danger IS NULL THEN RETURN 'deny'; END IF;

  obj_ids := ARRAY[p_id];
  IF p_type = 'vpn_key' THEN
    obj_ids := obj_ids || (SELECT server_id FROM inv.vpn_key WHERE id = p_id);
  END IF;

  -- 1. выдача на сам объект (0 deny, 1 approval, 2 allow)
  SELECT min(CASE gp.mode WHEN 'deny' THEN 0 WHEN 'approval' THEN 1 ELSE 2 END) INTO m
  FROM acc.access_grant g JOIN acc.grant_permission gp ON gp.grant_id = g.id
  WHERE g.account_id = p_account AND gp.permission_code = p_perm
    AND g.scope_type IN ('server','site') AND g.scope_id = ANY (obj_ids)
    AND (g.expires_at IS NULL OR g.expires_at > now());
  IF m IS NOT NULL THEN RETURN (ARRAY['deny','approval','allow'])[m + 1]; END IF;

  -- 2. выдачи на клиентов объекта
  SELECT array_agg(DISTINCT ca.client_id) INTO clients FROM inv.client_asset ca
  WHERE ca.until IS NULL AND ca.asset_id = ANY (obj_ids);
  IF clients IS NOT NULL THEN
    SELECT array_agg(cm) INTO per_client FROM (
      SELECT c AS client_id,
             (SELECT min(CASE gp.mode WHEN 'deny' THEN 0 WHEN 'approval' THEN 1 ELSE 2 END)
              FROM acc.access_grant g JOIN acc.grant_permission gp ON gp.grant_id = g.id
              WHERE g.account_id = p_account AND gp.permission_code = p_perm
                AND g.scope_type = 'client' AND g.scope_id = c
                AND (g.expires_at IS NULL OR g.expires_at > now())) AS cm
      FROM unnest(clients) AS c) s;
    IF EXISTS (SELECT 1 FROM unnest(per_client) x WHERE x IS NOT NULL) THEN
      IF EXISTS (SELECT 1 FROM unnest(per_client) x WHERE x = 0) THEN RETURN 'deny'; END IF;
      IF danger = 0 THEN
        RETURN (ARRAY['deny','approval','allow'])[(SELECT max(x) FROM unnest(per_client) x) + 1];
      END IF;
      IF EXISTS (SELECT 1 FROM unnest(per_client) x WHERE x IS NULL) THEN RETURN 'deny'; END IF;
      RETURN (ARRAY['deny','approval','allow'])[(SELECT min(x) FROM unnest(per_client) x) + 1];
    END IF;
  END IF;

  -- 3. выдача «на всё»
  SELECT min(CASE gp.mode WHEN 'deny' THEN 0 WHEN 'approval' THEN 1 ELSE 2 END) INTO m
  FROM acc.access_grant g JOIN acc.grant_permission gp ON gp.grant_id = g.id
  WHERE g.account_id = p_account AND gp.permission_code = p_perm AND g.scope_type = 'all'
    AND (g.expires_at IS NULL OR g.expires_at > now());
  RETURN coalesce((ARRAY['deny','approval','allow'])[m + 1], 'deny');
END $$;

-- ═════════════════════════════ партиции: нарезка и очистка ═════════════════════════════
-- Хаб раз в час вызывает SELECT * FROM sys.maintain_partitions(); — функция создаёт партиции
-- на несколько шагов вперёд и удаляет те, что целиком старше срока хранения. Удаление партиции —
-- мгновенный DROP, база не разбухает. Запись вне созданных партиций отклоняется, поэтому хаб
-- отбрасывает запоздавшие данные старше срока хранения (догрузку агента за последние дни это не задевает).
CREATE TABLE sys.partition_policy (
  parent text PRIMARY KEY,               -- 'mon.server_sample'
  step   text NOT NULL CHECK (step IN ('day','month')),
  keep   interval NOT NULL,              -- сколько хранить
  ahead  int NOT NULL DEFAULT 7 CHECK (ahead > 0)  -- сколько шагов создавать вперёд
);
INSERT INTO sys.partition_policy (parent, step, keep, ahead) VALUES
  ('mon.server_sample',    'day',   '30 days', 7),
  ('mon.poll',             'day',   '30 days', 7),
  ('mon.disk_sample',      'day',   '30 days', 7),
  ('mon.site_check',       'day',   '30 days', 7),
  ('mon.container_sample', 'day',   '7 days',  7),
  ('mon.link_sample',      'day',   '3 days',  7),
  ('mon.server_hourly',    'month', '1 year',  2),
  ('mon.container_hourly', 'month', '1 year',  2),
  ('mon.site_hourly',      'month', '1 year',  2),
  ('mon.link_hourly',      'month', '1 year',  2),
  ('ops.event',            'month', '2 years', 2),
  ('ops.audit_log',        'month', '3 years', 2);

-- Партиции называются <таблица>_YYYYMMDD (по дню) или <таблица>_YYYYMM (по месяцу), границы в UTC.
CREATE FUNCTION sys.maintain_partitions(p_now timestamptz DEFAULT now())
RETURNS TABLE (action text, partition_name text) LANGUAGE plpgsql AS $$
DECLARE
  pol    sys.partition_policy;
  sch    text;
  tbl    text;
  unit   interval;
  fmt    text;
  start  timestamp;
  lo     timestamp;
  hi     timestamp;
  pname  text;
  child  record;
BEGIN
  FOR pol IN SELECT * FROM sys.partition_policy ORDER BY parent LOOP
    sch  := split_part(pol.parent, '.', 1);
    tbl  := split_part(pol.parent, '.', 2);
    unit := CASE pol.step WHEN 'day' THEN interval '1 day' ELSE interval '1 month' END;
    fmt  := CASE pol.step WHEN 'day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END;
    start := date_trunc(pol.step, p_now AT TIME ZONE 'UTC');

    -- создать текущую и ahead следующих
    FOR i IN 0 .. pol.ahead LOOP
      lo := start + unit * i;
      hi := lo + unit;
      pname := tbl || '_' || to_char(lo, fmt);
      IF to_regclass(format('%I.%I', sch, pname)) IS NULL THEN
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                       sch, pname, sch, tbl, lo AT TIME ZONE 'UTC', hi AT TIME ZONE 'UTC');
        action := 'created'; partition_name := sch || '.' || pname; RETURN NEXT;
      END IF;
    END LOOP;

    -- удалить партиции, которые целиком старше срока хранения
    FOR child IN
      SELECT c.relname FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      WHERE i.inhparent = to_regclass(pol.parent)
        AND c.relname ~ ('^' || tbl || '_[0-9]+$')
    LOOP
      lo := to_timestamp(substr(child.relname, length(tbl) + 2), fmt)::timestamp;
      hi := lo + unit;
      IF hi AT TIME ZONE 'UTC' <= p_now - pol.keep THEN
        EXECUTE format('DROP TABLE %I.%I', sch, child.relname);
        action := 'dropped'; partition_name := sch || '.' || child.relname; RETURN NEXT;
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ═════════════════════════════ сид-данные ═════════════════════════════

INSERT INTO acc.permission (code, grp, title, danger_level, sort) VALUES
  ('view',                  'Просмотр', 'Видеть объект и его состояние',        0, 10),
  ('view_metrics',          'Просмотр', 'Графики и история метрик',              0, 20),
  ('view_logs',             'Просмотр', 'Журнал событий и действий',             0, 30),
  ('alerts_receive',        'Тревоги',  'Получать тревоги',                      0, 40),
  ('alerts_ack',            'Тревоги',  'Брать проблему в работу',               0, 50),
  ('ssh',                   'Серверы',  'Вход по SSH',                           2, 60),
  ('restart_container',     'Серверы',  'Перезапуск контейнера',                 1, 70),
  ('reboot_server',         'Серверы',  'Перезагрузка сервера',                  2, 80),
  ('install_agent',         'Серверы',  'Установка и обновление агента',         1, 90),
  ('db_backup',             'Серверы',  'Бэкапы баз',                            1, 100),
  ('vpn_keys_create',       'VPN',      'Создавать VPN-ключи',                   1, 110),
  ('vpn_keys_delete',       'VPN',      'Удалять VPN-ключи',                     2, 120),
  ('edit_objects',          'Объекты',  'Менять настройки серверов и сайтов',    1, 130),
  ('add_remove_objects',    'Объекты',  'Добавлять и убирать серверы и сайты',   2, 140),
  ('view_secrets',          'Объекты',  'Видеть пароли и токены',                2, 150),
  ('client_contacts_view',  'Клиенты',  'Видеть контакты клиента',               0, 160),
  ('client_reports_view',   'Клиенты',  'Видеть отчёты и черновики',             0, 170),
  ('client_reports_edit',   'Клиенты',  'Править отчёт и комментарий',           1, 180),
  ('client_reports_send',   'Клиенты',  'Отправлять отчёт клиенту',              1, 190),
  ('manage_billing',        'Клиенты',  'Тарифы и договоры',                     2, 200),
  ('manage_staff',          'Команда',  'Сотрудники и их права',                 2, 210);

-- ═════════════════════════════ роли базы ═════════════════════════════
-- monitor_owner — владелец схем, только миграции.
-- monitor_hub   — служба хаба: чтение и запись; ops.audit_log только INSERT и SELECT.
-- monitor_read  — только чтение (отчёты, разбор, будущий веб-кабинет на чтение).
-- monitor_backup — pg_dump.
-- Пример: REVOKE UPDATE, DELETE, TRUNCATE ON ops.audit_log FROM monitor_hub;

-- Первые партиции, чтобы хаб мог писать сразу после миграции.
DO $$ BEGIN PERFORM sys.maintain_partitions(); END $$;
