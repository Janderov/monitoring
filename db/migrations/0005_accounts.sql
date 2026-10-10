-- Кабинеты владельца и сотрудников (тред «Кабинеты админов и права»).
-- Таблицы acc.* уже есть в 0001; здесь то, что нужно для входа и выдачи прав.

-- Код из приложения подтверждён (до этого второй фактор не действует) и номер
-- 30-секундного шага последнего принятого кода: один и тот же код второй раз не пройдёт.
ALTER TABLE acc.account_mfa ADD COLUMN confirmed_at timestamptz;
ALTER TABLE acc.account_mfa ADD COLUMN last_step bigint;

-- Встроенные шаблоны ролей. Права, которых нет в шаблоне, — «нельзя».
-- Владелец может их править; удалить встроенный шаблон нельзя.
INSERT INTO acc.role_template (name, description, built_in) VALUES
  ('Наблюдатель', 'Только смотрит: состояние, графики, журнал, тревоги', true),
  ('Дежурный',    'Смотрит и берёт проблемы в работу; перезапуск и SSH — по согласованию', true),
  ('Админ',       'Обслуживает серверы клиентов; перезагрузка и удаление — по согласованию', true),
  ('Оператор VPN','Выдаёт VPN-ключи; удаление ключей — по согласованию', true);

INSERT INTO acc.role_template_permission (template_id, permission_code, mode)
SELECT t.id, p.code, p.mode
FROM acc.role_template t
JOIN (VALUES
  ('Наблюдатель', 'view', 'allow'), ('Наблюдатель', 'view_metrics', 'allow'),
  ('Наблюдатель', 'view_logs', 'allow'), ('Наблюдатель', 'alerts_receive', 'allow'),
  ('Наблюдатель', 'client_reports_view', 'allow'),

  ('Дежурный', 'view', 'allow'), ('Дежурный', 'view_metrics', 'allow'), ('Дежурный', 'view_logs', 'allow'),
  ('Дежурный', 'alerts_receive', 'allow'), ('Дежурный', 'alerts_ack', 'allow'),
  ('Дежурный', 'ssh', 'approval'), ('Дежурный', 'restart_container', 'approval'),
  ('Дежурный', 'reboot_server', 'approval'),

  ('Админ', 'view', 'allow'), ('Админ', 'view_metrics', 'allow'), ('Админ', 'view_logs', 'allow'),
  ('Админ', 'alerts_receive', 'allow'), ('Админ', 'alerts_ack', 'allow'),
  ('Админ', 'ssh', 'allow'), ('Админ', 'restart_container', 'allow'), ('Админ', 'reboot_server', 'approval'),
  ('Админ', 'install_agent', 'allow'), ('Админ', 'db_backup', 'allow'),
  ('Админ', 'vpn_keys_create', 'allow'), ('Админ', 'vpn_keys_delete', 'approval'),
  ('Админ', 'edit_objects', 'allow'), ('Админ', 'add_remove_objects', 'approval'),
  ('Админ', 'client_contacts_view', 'allow'), ('Админ', 'client_reports_view', 'allow'),
  ('Админ', 'client_reports_edit', 'allow'), ('Админ', 'client_reports_send', 'approval'),

  ('Оператор VPN', 'view', 'allow'), ('Оператор VPN', 'view_metrics', 'allow'),
  ('Оператор VPN', 'alerts_receive', 'allow'),
  ('Оператор VPN', 'vpn_keys_create', 'allow'), ('Оператор VPN', 'vpn_keys_delete', 'approval')
) AS p(template, code, mode) ON p.template = t.name;

-- Оформление по умолчанию для всех; владелец может поменять и закрепить.
INSERT INTO acc.default_preference (key, value) VALUES
  ('theme', '"system"'),
  ('density', '"compact"'),
  ('font_size', '"normal"'),
  ('start_page', '"overview"'),
  ('locale', '"ru"'),
  ('time_format', '"24h"'),
  ('units_traffic', '"bits"'),
  ('chart_default_period', '"24h"'),
  ('reduce_motion', 'false')
ON CONFLICT (key) DO NOTHING;

-- Одна строка настроек установки должна быть всегда (из неё берётся время жизни входа).
INSERT INTO sys.org_settings DEFAULT VALUES ON CONFLICT (id) DO NOTHING;
