-- Sample rows for checking ReportSQL against the real schema. Documentation names only.
INSERT INTO sys.org_settings (company_name, report_footer, contact_email) VALUES ('Михаил Дмитраков', 'Связь: Telegram', 'admin@example.com');
INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version) VALUES ('00000000-0000-0000-0000-0000000000a1', 'agent_token', '\x00', '\x00', 1);
INSERT INTO inv.client (id, name, timezone) VALUES ('00000000-0000-0000-0000-00000000c001', 'ООО «Пример»', 'Europe/Moscow'),
                                                    ('00000000-0000-0000-0000-00000000c002', 'Своё', 'Europe/Moscow');
UPDATE inv.client SET is_internal = true WHERE name = 'Своё';
INSERT INTO inv.client_contract (client_id, plan_name, monthly_price, sla_uptime, started_on)
  VALUES ('00000000-0000-0000-0000-00000000c001', 'Базовый', 5000, 99.900, '2026-06-01');
INSERT INTO inv.client_contact (client_id, name, email, receives_report) VALUES ('00000000-0000-0000-0000-00000000c001', 'Анна', 'anna@example.com', true);
INSERT INTO inv.server (id, name, host, agent_fingerprint, agent_token_id) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'app.example.com', '203.0.113.10', decode(repeat('00', 32), 'hex'), '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b2', 'other.example.net', '198.51.100.7', decode(repeat('00', 32), 'hex'), '00000000-0000-0000-0000-0000000000a1');
INSERT INTO inv.site (id, name, url) VALUES ('00000000-0000-0000-0000-0000000000d1', 'shop.example.com', 'https://shop.example.com/catalog'),
                                            ('00000000-0000-0000-0000-0000000000d2', 'moved.example.com', 'https://moved.example.com');
INSERT INTO inv.client_asset (client_id, asset_type, asset_id, since, until) VALUES
  ('00000000-0000-0000-0000-00000000c001', 'server', '00000000-0000-0000-0000-0000000000b1', '2026-06-01', NULL),
  ('00000000-0000-0000-0000-00000000c001', 'site', '00000000-0000-0000-0000-0000000000d1', '2026-06-01', NULL),
  -- moved to another client on 15 September: still in September's report, gone from October's
  ('00000000-0000-0000-0000-00000000c001', 'site', '00000000-0000-0000-0000-0000000000d2', '2026-06-01', '2026-09-15'),
  ('00000000-0000-0000-0000-00000000c002', 'server', '00000000-0000-0000-0000-0000000000b2', '2026-06-01', NULL);
INSERT INTO inv.domain (name, expires_at) VALUES ('example.com', '2026-11-16 12:00+03');
INSERT INTO inv.certificate (host, expires_at, checked_at) VALUES ('shop.example.com', '2026-12-19 12:00+03', now());
INSERT INTO mon.site_daily (site_id, day, checks_total, checks_ok, downtime_s, latency_avg_ms)
  SELECT '00000000-0000-0000-0000-0000000000d1', d::date, 4320, CASE WHEN d::date = '2026-09-23' THEN 4306 ELSE 4320 END,
         CASE WHEN d::date = '2026-09-23' THEN 840 ELSE 0 END, 580
  FROM generate_series('2026-08-25'::date, '2026-10-02'::date, '1 day') d;
INSERT INTO mon.server_daily (server_id, day, cpu_max, mem_max, disk_max_pct, checks_total, checks_ok)
  SELECT s, d::date, 64, 71, 58, 1440, 1440 FROM generate_series('2026-09-01'::date, '2026-09-30'::date, '1 day') d,
         unnest(ARRAY['00000000-0000-0000-0000-0000000000b1'::uuid, '00000000-0000-0000-0000-0000000000b2'::uuid]) s;
INSERT INTO mon.disk_daily (server_id, mount, day, used_bytes, total_bytes)
  SELECT '00000000-0000-0000-0000-0000000000b1', '/', d::date, 50000000, 100000000 FROM generate_series('2026-08-01'::date, '2026-09-30'::date, '1 day') d;
INSERT INTO ops.incident (object_type, object_id, object_name, key, kind, severity, message, started_at, ended_at, client_visible) VALUES
  ('site', '00000000-0000-0000-0000-0000000000d1', 'shop.example.com', 'down', 'down', 2, 'Не открывался', '2026-09-23 03:12+03', '2026-09-23 03:26+03', true),
  ('site', '00000000-0000-0000-0000-0000000000d1', 'shop.example.com', 'slow', 'slow', 1, 'Внутреннее', '2026-09-24 03:12+03', '2026-09-24 03:20+03', false),
  ('server', '00000000-0000-0000-0000-0000000000b2', 'other.example.net', 'down', 'down', 2, 'Чужой', '2026-09-23 03:12+03', '2026-09-23 03:26+03', true);
INSERT INTO ops.forecast (stable_key, object_type, object_id, kind, line, due_at, first_seen_at, last_seen_at, status, closed_at, note) VALUES
  ('b1|disk', 'server', '00000000-0000-0000-0000-0000000000b1', 'disk_full', 'Диск заполнится', '2026-09-18 12:00+03', '2026-09-04', '2026-09-11', 'prevented', '2026-09-11 15:00+03', '+18 ГБ'),
  ('d1|old', 'site', '00000000-0000-0000-0000-0000000000d1', 'tls_expiry', 'Старое', NULL, '2026-08-01', '2026-08-20', 'prevented', '2026-08-20 11:00+03', NULL),
  ('d1|domain', 'site', '00000000-0000-0000-0000-0000000000d1', 'domain_expiry', 'Домен истекает', '2026-11-16 12:00+03', '2026-09-17', '2026-10-01', 'open', NULL, NULL);
INSERT INTO mon.backup_run (server_id, target, started_at, ok, size_bytes)
  SELECT '00000000-0000-0000-0000-0000000000b1', 'shop', d + interval '2 hours', true, 1900000000 FROM generate_series('2026-09-01'::timestamptz, '2026-09-30', '1 day') d;
INSERT INTO rep.work_item (client_id, done_at, client_text) VALUES ('00000000-0000-0000-0000-00000000c001', '2026-09-11 15:00+03', 'Очищены журналы');
