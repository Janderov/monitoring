/* The cabinet: one page, hash routes, no framework. Every piece of text from
   the hub goes through text nodes (h()), never innerHTML. */
'use strict';

const root = document.documentElement;
const app = document.getElementById('app');
const S = { me: null, perms: null };

// MARK: DOM

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  add(el, kids);
  return el;
}
function add(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k === null || k === undefined || k === false) continue;
    el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return el;
}
function clear(el, ...kids) { el.replaceChildren(); return add(el, kids); }

function toast(text) {
  const t = h('div', { class: 'toast', role: 'status' }, text);
  document.body.append(t);
  setTimeout(() => t.remove(), 3200);
}

function dialog(build) {
  return new Promise(resolve => {
    const back = h('div', { class: 'backdrop' });
    const box = h('div', { class: 'dialog', role: 'dialog', 'aria-modal': 'true' });
    const close = v => { back.remove(); document.removeEventListener('keydown', esc); resolve(v); };
    const esc = e => { if (e.key === 'Escape') close(null); };
    document.addEventListener('keydown', esc);
    back.addEventListener('mousedown', e => { if (e.target === back) close(null); });
    add(box, [build(close)]);
    back.append(box);
    document.body.append(back);
    const f = box.querySelector('input, select, textarea, button.primary');
    if (f) f.focus();
  });
}

function confirmBox(title, text, okLabel = 'Да', danger = false) {
  return dialog(close => [
    h('h3', {}, title), text ? h('p', {}, text) : null,
    h('div', { class: 'actions' }, h('span', { class: 'grow' }),
      h('button', { onclick: () => close(false) }, 'Отмена'),
      h('button', { class: danger ? 'primary danger' : 'primary', onclick: () => close(true) }, okLabel)),
  ]);
}

/** Asks for the code from the phone; null when cancelled. */
function askCode(error) {
  return dialog(close => {
    const input = h('input', { class: 'code-input', inputmode: 'numeric', autocomplete: 'one-time-code', maxlength: 8,
                               'aria-label': 'Код из приложения' });
    const go = e => { e.preventDefault(); const v = input.value.replace(/\s/g, ''); if (v) close(v); };
    return h('form', { class: 'form', onsubmit: go },
      h('h3', {}, 'Код из приложения на телефоне'),
      h('p', { class: 'mute' }, 'Это действие важное, поэтому нужен свежий код.'),
      error ? h('p', { class: 'err' }, error) : null,
      input,
      h('div', { class: 'actions' }, h('span', { class: 'grow' }),
        h('button', { type: 'button', onclick: () => close(null) }, 'Отмена'),
        h('button', { class: 'primary', type: 'submit' }, 'Подтвердить')));
  });
}

function copyBox(value) {
  const input = h('input', { value, readonly: true, onfocus: e => e.target.select() });
  return h('div', { class: 'copybox' }, input,
    h('button', { onclick: async () => {
      try { await navigator.clipboard.writeText(value); toast('Скопировано'); }
      catch { input.select(); document.execCommand('copy'); toast('Скопировано'); }
    } }, 'Копировать'));
}

function inviteDialog(r, name) {
  const url = /^https?:/.test(r.invite_url || '') ? r.invite_url : location.origin + r.invite_path;
  return dialog(close => [
    h('h3', {}, 'Ссылка для входа'),
    h('p', {}, `Отправьте ${name ? name + ' ' : ''}эту ссылку лично (в мессенджере). Она работает 48 часов и только один раз.`),
    copyBox(url),
    h('p', { class: 'mute small' }, 'По ссылке человек задаст пароль и подключит приложение для кодов на телефоне.'),
    h('div', { class: 'actions' }, h('span', { class: 'grow' }), h('button', { class: 'primary', onclick: () => close(true) }, 'Готово')),
  ]);
}

// MARK: API

class Cancelled extends Error {}

async function api(method, path, body, opts = {}) {
  const headers = { 'X-Requested-With': 'cabinet', Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (opts.code) headers['X-TOTP'] = opts.code;
  const r = await fetch(path, { method, headers, credentials: 'same-origin',
                                body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }
  if (r.ok) return data;
  if (r.status === 428 && data && data.need_code) {
    const code = await askCode(opts.code ? 'Код не подошёл. Дождитесь нового кода.' : null);
    if (!code) throw new Cancelled();
    return api(method, path, body, { ...opts, code });
  }
  if (r.status === 403 && opts.code && data && /^Код/.test(data.error || '')) {
    const code = await askCode(data.error);
    if (!code) throw new Cancelled();
    return api(method, path, body, { ...opts, code });
  }
  if (r.status === 401 && !opts.anon) {
    S.me = null;
    location.hash = '#/login';
    throw new Cancelled();
  }
  const e = new Error((data && data.error) || `Хаб ответил ошибкой ${r.status}`);
  e.status = r.status;
  throw e;
}
const GET = (p, o) => api('GET', p, undefined, o);
const POST = (p, b, o) => api('POST', p, b === undefined ? {} : b, o);
const PUT = (p, b, o) => api('PUT', p, b, o);
const PATCH = (p, b, o) => api('PATCH', p, b, o);
const DEL = (p, o) => api('DELETE', p, undefined, o);

/** Runs an action from a button: shows errors, ignores a cancelled code. */
async function act(fn, btn) {
  if (btn) btn.disabled = true;
  try { return await fn(); }
  catch (e) { if (!(e instanceof Cancelled)) toast(e.message); return undefined; }
  finally { if (btn) btn.disabled = false; }
}

// MARK: Formatting

const pref = k => (S.me && S.me.prefs && S.me.prefs.values ? S.me.prefs.values[k] : undefined);

function fmtTime(iso, withDate = true) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  const tz = pref('timezone') || undefined;
  const opt = { hour: '2-digit', minute: '2-digit', hour12: pref('time_format') === '12h', timeZone: tz };
  const time = d.toLocaleTimeString('ru-RU', opt);
  if (!withDate) return time;
  const p = new Intl.DateTimeFormat('ru-RU', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: tz })
    .formatToParts(d).reduce((a, x) => (a[x.type] = x.value, a), {});
  const date = pref('date_format') === 'yyyy-mm-dd' ? `${p.year}-${p.month}-${p.day}` : `${p.day}.${p.month}.${p.year}`;
  return `${date} ${time}`;
}
function fmtDate(iso) { return iso ? fmtTime(iso).split(' ')[0] : '—'; }
function ago(iso) {
  if (!iso) return '—';
  const s = (Date.now() - new Date(iso)) / 1000;
  if (s < 60) return 'только что';
  if (s < 3600) return `${Math.floor(s / 60)} мин назад`;
  if (s < 86400) return `${Math.floor(s / 3600)} ч назад`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)} дн назад`;
  return fmtDate(iso);
}
const pct = v => (v === null || v === undefined ? '—' : `${Math.round(v)}%`);
/** yyyy-mm-dd for a date input. */
function isoDay(d) { return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }
function inMonths(n) { const d = new Date(); d.setMonth(d.getMonth() + n); return isoDay(d); }

const STATUS = { active: ['Работает', 'g'], invited: ['Приглашён', 'a'], disabled: ['Отключён', ''] };
const statusPill = s => { const [t, c] = STATUS[s] || [s, '']; return h('span', { class: 'pill ' + c }, t); };
/** The switches shown next to the role (2А); the rest is in «Подробно» (2Б). */
const KEY_PERMS = ['alerts_ack', 'ssh', 'restart_container', 'reboot_server', 'vpn_keys_create', 'client_reports_send'];
const MODES = [['deny', 'Нет'], ['allow', 'Можно'], ['approval', 'С согласия']];
const MODE_SHORT = { deny: '—', allow: 'да', approval: 'согл.' };
const RESULT = { done: ['Сделано', 'g'], failed: ['Ошибка', 'r'], denied: ['Запрещено', 'r'], pending_approval: ['Ждёт согласия', 'y'] };
const ACTIONS = {
  login: 'Вход', login_failed: 'Неудачный вход', logout: 'Выход', signup: 'Регистрация по ссылке',
  password_changed: 'Смена пароля', recovery_codes_renewed: 'Новые запасные коды', session_revoked: 'Сеанс завершён',
  sessions_revoked: 'Все сеансы завершены', step_up_failed: 'Неверный код', staff_created: 'Сотрудник приглашён',
  staff_changed: 'Данные сотрудника изменены', staff_disabled: 'Доступ отключён', staff_enabled: 'Доступ включён',
  login_reset: 'Вход сброшен', invite_renewed: 'Новая ссылка-приглашение', grants_changed: 'Права изменены',
  template_created: 'Шаблон создан', template_changed: 'Шаблон изменён', template_deleted: 'Шаблон удалён',
  approval_granted: 'Согласовано', approval_rejected: 'Отклонено', ssh_key_added: 'SSH-ключ добавлен',
  ssh_key_revoked: 'SSH-ключ отозван', org_settings_changed: 'Настройки компании', defaults_changed: 'Общие настройки оформления',
  owner_invite: 'Ссылка владельца', owner_reset: 'Сброс входа владельца', alerts_ack: 'Проблема взята в работу',
};
const actionTitle = (code, title) => ACTIONS[code] || title || code;

function empty(text) { return h('div', { class: 'empty' }, text); }
function table(head, rows, emptyText) {
  if (!rows.length) return h('div', { class: 'scroll' }, empty(emptyText || 'Пусто'));
  return h('div', { class: 'scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, head.map(x => h('th', {}, x)))), h('tbody', {}, rows)));
}
function seg(options, value, onpick, extraClass) {
  const box = h('div', { class: 'seg', role: 'radiogroup' });
  const paint = v => { for (const b of box.children) { const on = b.dataset.v === v; b.classList.toggle('on', on); b.setAttribute('aria-checked', on); } };
  for (const [v, label] of options) {
    box.append(h('button', { type: 'button', role: 'radio', 'data-v': v, class: extraClass ? `m-${v}` : null,
                             onclick: () => { paint(v); onpick(v); } }, label));
  }
  paint(value);
  return box;
}
function row(label, hint, ...control) {
  return h('div', { class: 'row' }, h('div', { class: 'lbl' }, label, hint ? h('small', {}, hint) : null), control);
}
function field(label, input) { return h('label', { class: 'field' }, h('span', {}, label), input); }

// MARK: Preferences on the page

function applyPrefs() {
  const v = (S.me && S.me.prefs && S.me.prefs.values) || {};
  const set = (attr, val, none) => (val && val !== none ? root.setAttribute(attr, val) : root.removeAttribute(attr));
  set('data-theme', v.theme, 'system');
  set('data-accent', v.accent, 'system');
  set('data-density', v.density, 'compact');
  set('data-font', v.font_size, 'normal');
  set('data-reduce-motion', v.reduce_motion === true ? 'true' : null);
  document.title = (S.me && S.me.org && S.me.org.company_name) || 'Мониторинг';
}

// MARK: Routing

const START = { overview: '#/overview', problems: '#/overview', events: '#/overview', staff: '#/staff', audit: '#/audit' };
const canStaff = () => S.me && S.me.can.manage_staff !== 'deny';
const isOwner = () => S.me && S.me.account.kind === 'owner';

async function loadMe() {
  try { S.me = await GET('/api/me', { anon: true }); }
  catch { S.me = null; }
  applyPrefs();
  return S.me;
}

async function route() {
  const hash = (location.hash || '#/').split('?')[0];
  const parts = hash.slice(2).split('/');
  if (parts[0] === 'invite') return pageInvite(parts[1] || '');
  if (parts[0] === 'login') return pageLogin();
  if (!S.me && !(await loadMe())) { location.hash = '#/login'; return; }
  if (!parts[0]) { location.hash = START[pref('start_page')] || '#/overview'; return; }
  const pages = {
    overview: pageOverview, staff: parts[1] === 'new' ? pageNewStaff : parts[1] ? m => pageStaff(m, parts[1]) : pageStaffList,
    templates: pageTemplates, approvals: pageApprovals, audit: pageAudit, profile: pageProfile,
    appearance: pageAppearance, notify: pageNotify, company: pageCompany,
  };
  const page = pages[parts[0]] || pageOverview;
  const main = shell(parts[0]);
  clear(main, h('p', { class: 'mute' }, 'Загружаю…'));
  try { await page(main); }
  catch (e) { if (!(e instanceof Cancelled)) clear(main, h('div', { class: 'note bad' }, e.message)); }
}
window.addEventListener('hashchange', route);

function shell(current) {
  const me = S.me;
  const link = (id, label, badge) => h('a', { href: '#/' + id, class: id === current ? 'on' : null,
                                                'aria-current': id === current ? 'page' : null },
    label, badge ? h('span', { class: 'badge' }, badge) : null);
  const side = h('nav', { class: 'side', 'aria-label': 'Разделы' },
    h('div', { class: 'brand' }, (me.org && me.org.company_name) || 'Мониторинг',
      h('small', {}, me.account.displayName || me.account.login)),
    link('overview', 'Обзор'),
    canStaff() ? [h('div', { class: 'label' }, 'Команда'), link('staff', 'Сотрудники'), link('templates', 'Шаблоны ролей')] : null,
    link('approvals', isOwner() ? 'Согласования' : 'Мои запросы', isOwner() && me.pending_approvals ? me.pending_approvals : null),
    link('audit', 'Журнал действий'),
    h('div', { class: 'label' }, 'Настройки'),
    link('profile', 'Профиль и вход'), link('appearance', 'Оформление'), link('notify', 'Уведомления'),
    isOwner() ? link('company', 'Компания') : null,
    h('div', { class: 'foot' },
      h('button', { class: 'link', onclick: logout }, 'Выйти'),
      h('span', {}, 'Хаб ' + (me.version || ''))));
  const main = h('main', { class: 'main', id: 'main' });
  const menu = h('button', { class: 'menu-btn', 'aria-label': 'Меню', onclick: () => side.classList.toggle('open') }, '☰');
  side.addEventListener('click', e => { if (e.target.closest('a')) side.classList.remove('open'); });
  clear(app, h('div', { class: 'shell' }, side, h('div', { class: 'content' }, h('div', { class: 'topbar' }, menu), main)));
  return main;
}

function header(main, title, sub, ...right) {
  add(main, [h('div', { class: 'head' }, h('div', { class: 'grow' }, h('h1', {}, title), sub ? h('div', { class: 'mute' }, sub) : null), right)]);
}

async function logout() {
  await act(() => POST('/api/auth/logout'));
  S.me = null;
  location.hash = '#/login';
}

// MARK: Login

function pageLogin() {
  let ticket = null;
  const err = h('p', { class: 'err', role: 'alert' });
  const card = h('div', { class: 'card' });
  const stepPassword = () => {
    const login = h('input', { autocomplete: 'username', autocapitalize: 'off', spellcheck: 'false', required: true });
    const password = h('input', { type: 'password', autocomplete: 'current-password', required: true });
    const btn = h('button', { class: 'primary', type: 'submit' }, 'Дальше');
    clear(card, h('form', { class: 'form', onsubmit: async e => {
      e.preventDefault(); err.textContent = '';
      btn.disabled = true;
      try {
        const r = await POST('/api/auth/login', { login: login.value, password: password.value }, { anon: true });
        ticket = r.ticket; stepCode();
      } catch (x) { err.textContent = x.message; } finally { btn.disabled = false; }
    } }, h('h1', {}, 'Вход'), h('p', { class: 'mute' }, 'Кабинет мониторинга серверов и сайтов.'),
      field('Логин', login), field('Пароль', password), err, btn));
    login.focus();
  };
  const stepCode = () => {
    const code = h('input', { class: 'code-input', inputmode: 'numeric', autocomplete: 'one-time-code', required: true });
    const btn = h('button', { class: 'primary', type: 'submit' }, 'Войти');
    err.textContent = '';
    clear(card, h('form', { class: 'form', onsubmit: async e => {
      e.preventDefault(); err.textContent = '';
      btn.disabled = true;
      try {
        await POST('/api/auth/code', { ticket, code: code.value }, { anon: true });
        await loadMe();
        location.hash = START[pref('start_page')] || '#/overview';
      } catch (x) {
        err.textContent = x.message;
        if (x.status === 401) setTimeout(stepPassword, 1500);
      } finally { btn.disabled = false; }
    } }, h('h1', {}, 'Код с телефона'),
      h('p', { class: 'mute' }, 'Откройте приложение для кодов и введите 6 цифр. Если телефона нет под рукой, введите один из запасных кодов.'),
      code, err, btn,
      h('button', { type: 'button', class: 'link', onclick: stepPassword }, 'Назад')));
    code.focus();
  };
  clear(app, h('div', { class: 'center' }, card));
  stepPassword();
}

// MARK: Signing up by invite

async function pageInvite(token) {
  const card = h('div', { class: 'card wide' }, h('p', { class: 'mute' }, 'Проверяю ссылку…'));
  clear(app, h('div', { class: 'center' }, card));
  let info;
  try { info = await GET('/api/invite/' + encodeURIComponent(token), { anon: true }); }
  catch (e) { clear(card, h('h1', {}, 'Ссылка не работает'), h('p', {}, e.message)); return; }
  const err = h('p', { class: 'err', role: 'alert' });
  const steps = n => h('div', { class: 'steps' }, `Шаг ${n} из 3`);

  const stepPassword = () => {
    const p1 = h('input', { type: 'password', autocomplete: 'new-password', required: true, minlength: 12 });
    const p2 = h('input', { type: 'password', autocomplete: 'new-password', required: true });
    const btn = h('button', { class: 'primary', type: 'submit' }, 'Дальше');
    clear(card, h('form', { class: 'form', onsubmit: async e => {
      e.preventDefault(); err.textContent = '';
      if (p1.value !== p2.value) { err.textContent = 'Пароли не совпадают'; return; }
      btn.disabled = true;
      try {
        const r = await POST(`/api/invite/${encodeURIComponent(token)}/password`, { password: p1.value }, { anon: true });
        stepPhone(r);
      } catch (x) { err.textContent = x.message; } finally { btn.disabled = false; }
    } }, steps(1), h('h1', {}, `Здравствуйте, ${info.displayName}`),
      h('p', {}, 'Ваш логин: ', h('b', { class: 'mono' }, info.login)),
      h('p', { class: 'mute' }, `Придумайте пароль: не короче 12 знаков, без логина внутри. Удобно взять несколько слов через дефис. Ссылка действует до ${fmtTime(info.expiresAt)}.`),
      field('Пароль', p1), field('Ещё раз', p2), err, btn));
    p1.focus();
  };

  const stepPhone = enrol => {
    const code = h('input', { class: 'code-input', inputmode: 'numeric', autocomplete: 'one-time-code', required: true });
    const btn = h('button', { class: 'primary', type: 'submit' }, 'Проверить код');
    let qr = null;
    if (window.qrcode) {
      const q = window.qrcode(0, 'M'); q.addData(enrol.otpauth_uri); q.make();
      qr = h('div', { class: 'qr' }, h('img', { src: q.createDataURL(5, 8), alt: 'QR-код для приложения', width: 200, height: 200 }));
    }
    const secret = enrol.secret.replace(/(.{4})/g, '$1 ').trim();
    err.textContent = '';
    clear(card, h('form', { class: 'form', onsubmit: async e => {
      e.preventDefault(); err.textContent = '';
      btn.disabled = true;
      try {
        const r = await POST(`/api/invite/${encodeURIComponent(token)}/code`, { code: code.value }, { anon: true });
        stepCodes(r.recovery_codes);
      } catch (x) { err.textContent = x.message; } finally { btn.disabled = false; }
    } }, steps(2), h('h1', {}, 'Коды с телефона'),
      h('p', {}, 'Установите на телефон приложение для кодов: Яндекс Ключ, Google Authenticator или любое другое. Нажмите в нём «добавить» и наведите камеру на этот рисунок.'),
      qr, h('p', { class: 'mute small' }, 'Если камера не работает, введите ключ вручную:'), copyBox(secret),
      field('Код из приложения (6 цифр)', code), err, btn));
    code.focus();
  };

  const stepCodes = codes => {
    const ok = h('input', { type: 'checkbox' });
    const go = h('button', { class: 'primary', disabled: true, onclick: async () => { await loadMe(); location.hash = '#/'; } }, 'Войти в кабинет');
    ok.addEventListener('change', () => { go.disabled = !ok.checked; });
    const text = 'Запасные коды для входа в кабинет «Мониторинг»\n' + codes.join('\n') + '\n';
    clear(card, steps(3), h('h1', {}, 'Запасные коды'),
      h('p', {}, 'Если телефон потеряется, войти можно одним из этих кодов. Каждый работает один раз. Сохраните их в надёжном месте (менеджер паролей или распечатка).'),
      h('div', { class: 'codes' }, codes.map(c => h('div', {}, c))),
      h('div', { class: 'actions' },
        h('button', { onclick: () => download('zapasnye-kody.txt', text) }, 'Скачать файлом'),
        h('button', { onclick: () => navigator.clipboard.writeText(text).then(() => toast('Скопировано')) }, 'Копировать')),
      h('label', { class: 'actions' }, ok, 'Я сохранил коды'), go);
  };
  stepPassword();
}

function download(name, text) {
  const a = h('a', { href: URL.createObjectURL(new Blob([text], { type: 'text/plain' })), download: name });
  document.body.append(a); a.click(); a.remove();
}

// MARK: Overview

async function pageOverview(main) {
  const d = await GET('/api/overview');
  clear(main);
  header(main, 'Обзор', `Серверов: ${d.servers.length}, сайтов: ${d.sites.length}`,
    h('button', { onclick: () => route() }, 'Обновить'));
  const canAck = S.me.can.alerts_ack !== 'deny';
  const sev = s => (s >= 2 ? h('span', { class: 'pill r' }, 'Критично') : h('span', { class: 'pill y' }, 'Внимание'));
  add(main, [h('h2', {}, 'Проблемы сейчас'), table(['', 'Объект', 'Что случилось', 'С', 'В работе', ''],
    d.incidents.map(i => h('tr', {},
      h('td', {}, sev(i.severity)), h('td', {}, i.object_name), h('td', {}, i.message),
      h('td', { class: 'nowrap' }, ago(i.started_at)),
      h('td', {}, (i.acked_by || []).join(', ') || h('span', { class: 'mute' }, 'никто')),
      h('td', {}, canAck && !(i.acked_by || []).includes(S.me.account.displayName)
        ? h('button', { onclick: e => act(async () => { await POST(`/api/incidents/${i.id}/ack`); toast('Взято в работу'); route(); }, e.target) }, 'Беру')
        : null))), 'Проблем нет')]);

  const dot = o => {
    const c = o.paused ? '' : o.severity >= 2 ? 'r' : o.severity >= 1 ? 'y' : 'g';
    return h('span', { class: 'dot ' + c, title: o.paused ? 'На паузе' : '' });
  };
  const stale = s => s.seen_at && (Date.now() - new Date(s.seen_at)) > 5 * 60000;
  add(main, [h('h2', {}, 'Серверы'), table(['Сервер', 'Адрес', 'Клиент', 'CPU', 'Память', 'Диск', 'Данные'],
    d.servers.map(s => h('tr', {},
      h('td', { class: 'nowrap' }, dot(s), s.name, s.country ? h('span', { class: 'mute' }, ' ' + s.country) : null),
      h('td', { class: 'mono' }, s.host || '—'), h('td', {}, (s.clients || []).join(', ') || '—'),
      h('td', { class: 'num' }, pct(s.cpu)), h('td', { class: 'num' }, pct(s.mem)), h('td', { class: 'num' }, pct(s.disk)),
      h('td', { class: 'nowrap ' + (stale(s) ? 'err' : 'mute') }, s.seen_at ? ago(s.seen_at) : 'нет данных')))
    , 'Нет доступных серверов')]);
  add(main, [h('h2', {}, 'Сайты'), table(['Сайт', 'Адрес', 'Клиент', 'Проблем'],
    d.sites.map(s => h('tr', {},
      h('td', { class: 'nowrap' }, dot(s), s.name), h('td', { class: 'mono' }, s.url),
      h('td', {}, (s.clients || []).join(', ') || '—'), h('td', { class: 'num' }, s.problems || 0))),
    'Нет доступных сайтов')]);
}

// MARK: Staff

async function pageStaffList(main) {
  const list = await GET('/api/staff');
  clear(main);
  header(main, 'Сотрудники', 'Кто входит в кабинет и что ему можно.',
    h('button', { class: 'primary', onclick: () => { location.hash = '#/staff/new'; } }, 'Пригласить сотрудника…'));
  add(main, [table(['Имя', 'Состояние', 'Роль', 'Где', 'Доступ до', 'Был в сети'], list.map(p => {
    const expired = p.access_expires_at && new Date(p.access_expires_at) < new Date();
    return h('tr', { class: 'click', tabindex: 0, onclick: () => { location.hash = '#/staff/' + p.id; },
                     onkeydown: e => { if (e.key === 'Enter') location.hash = '#/staff/' + p.id; } },
      h('td', {}, p.display_name, h('div', { class: 'mute small mono' }, p.login)),
      h('td', {}, p.kind === 'owner' ? h('span', { class: 'pill a' }, 'Владелец') : statusPill(p.status),
        p.status === 'invited' && p.invite_expires_at ? h('div', { class: 'mute small' }, 'ссылка до ' + fmtTime(p.invite_expires_at)) : null),
      h('td', {}, p.kind === 'owner' ? 'Все права' : (p.roles || []).join(', ') || h('span', { class: 'mute' }, 'свой набор')),
      h('td', {}, p.kind === 'owner' ? 'Всё' : (p.scopes || []).join(', ') || h('span', { class: 'mute' }, 'нигде')),
      h('td', { class: 'nowrap ' + (expired ? 'err' : '') }, p.kind === 'owner' ? '—' : p.access_expires_at ? fmtDate(p.access_expires_at) : 'без срока'),
      h('td', { class: 'nowrap' }, p.last_seen ? [ago(p.last_seen.at), h('div', { class: 'mute small' }, p.last_seen.device || '')] : '—'));
  }), 'Пока никого нет')]);
}

async function rightsData() {
  if (!S.perms) S.perms = await GET('/api/permissions');
  const [templates, scopes] = await Promise.all([GET('/api/templates'), GET('/api/scopes')]);
  return { perms: S.perms.filter(p => !p.owner_only), ownerOnly: S.perms.filter(p => p.owner_only), templates, scopes };
}

/** The rights editor: 2А (a role template per area, with switches) and 2Б (the full table, «Подробно»). */
function rightsEditor(data, initial) {
  const { perms, templates, scopes } = data;
  let detailed = false;
  const grants = initial.map(g => ({ scope_type: g.scope_type, scope_id: g.scope_id || null, template_id: g.template_id || null,
                                     expires_at: g.expires_at || null, permissions: { ...g.permissions } }));
  const box = h('div', { class: 'stack' });
  const tmpl = id => templates.find(t => t.id === id);
  const modeOf = (g, code) => g.permissions[code] || 'deny';
  const fromTemplate = (g, code) => { const t = tmpl(g.template_id); return t ? (t.permissions[code] || 'deny') : null; };

  const scopeKey = g => (g.scope_type === 'all' ? 'all' : `${g.scope_type}:${g.scope_id}`);
  const scopeName = g => {
    if (g.scope_type === 'all') return 'Все объекты';
    const list = g.scope_type === 'client' ? scopes.clients : g.scope_type === 'server' ? scopes.servers : scopes.sites;
    const o = list.find(x => x.id === g.scope_id);
    const kind = { client: 'Клиент', server: 'Сервер', site: 'Сайт' }[g.scope_type];
    return `${kind}: ${o ? o.name : '?'}`;
  };
  const scopeSelect = g => {
    const opt = (v, label) => h('option', { value: v, selected: v === scopeKey(g) }, label);
    const sel = h('select', { 'aria-label': 'Где действуют права', onchange: e => {
      const [t, id] = e.target.value.split(':'); g.scope_type = t; g.scope_id = id || null; paint();
    } },
      opt('all', 'Все объекты'),
      scopes.clients.length ? h('optgroup', { label: 'Клиент целиком' }, scopes.clients.map(c => opt('client:' + c.id, c.name))) : null,
      scopes.servers.length ? h('optgroup', { label: 'Один сервер' }, scopes.servers.map(s => opt('server:' + s.id, s.name))) : null,
      scopes.sites.length ? h('optgroup', { label: 'Один сайт' }, scopes.sites.map(s => opt('site:' + s.id, s.name))) : null);
    return sel;
  };
  const templateSelect = g => h('select', { 'aria-label': 'Шаблон роли', onchange: e => {
    g.template_id = e.target.value || null;
    const t = tmpl(g.template_id);
    if (t) g.permissions = { ...t.permissions };
    paint();
  } }, h('option', { value: '' }, 'Свой набор'),
    templates.map(t => h('option', { value: t.id, selected: t.id === g.template_id }, t.name)));

  const paint2A = () => grants.map((g, i) => {
    const changed = perms.filter(p => { const t = fromTemplate(g, p.code); return t !== null && t !== modeOf(g, p.code); });
    return h('div', { class: 'group' },
      h('div', { class: 'row' }, h('div', { class: 'lbl' }, h('b', {}, 'Где'), h('small', {}, 'Права ниже действуют только здесь')), scopeSelect(g),
        h('button', { class: 'danger', onclick: () => { grants.splice(i, 1); paint(); } }, 'Убрать')),
      h('div', { class: 'row' }, h('div', { class: 'lbl' }, h('b', {}, 'Роль'),
        h('small', {}, changed.length ? `Изменено от шаблона: ${changed.length}` : 'Готовый набор прав, ниже можно поправить')),
        templateSelect(g),
        changed.length ? h('button', { class: 'link', onclick: () => { g.permissions = { ...tmpl(g.template_id).permissions }; paint(); } }, 'Вернуть как в шаблоне') : null),
      h('div', { class: 'title' }, 'Главные переключатели'),
      perms.filter(p => KEY_PERMS.includes(p.code) || changed.includes(p)).map(p => {
        const t = fromTemplate(g, p.code);
        const r = row(p.title, p.danger >= 2 ? 'Опасное: перед ним сотрудник вводит код' : null,
          seg(MODES, modeOf(g, p.code), v => { g.permissions[p.code] = v; paint(); }, true));
        if (t !== null && t !== modeOf(g, p.code)) r.classList.add('changed');
        return r;
      }),
      h('div', { class: 'row' }, h('span', { class: 'mute small' }, 'Остальные права берутся из роли. Все сразу видно по кнопке «Подробно».')));
  });

  const paint2B = () => {
    if (!grants.length) return [];
    return [h('div', { class: 'scroll' }, h('table', { class: 'matrix' },
      h('thead', {}, h('tr', {}, h('th', {}, 'Право'), grants.map(g => h('th', { class: 'rot', title: scopeName(g) }, scopeName(g))))),
      h('tbody', {}, perms.map(p => h('tr', {}, h('td', {}, p.title, p.danger >= 2 ? h('span', { class: 'mute' }, ' ⚠') : null),
        grants.map(g => {
          const m = modeOf(g, p.code);
          return h('td', {}, h('button', { class: 'cell m-' + m, title: `${scopeName(g)}: ${p.title}`,
            'aria-label': `${scopeName(g)}, ${p.title}: ${MODES.find(x => x[0] === m)[1]}`,
            onclick: () => { const order = ['deny', 'allow', 'approval']; g.permissions[p.code] = order[(order.indexOf(m) + 1) % 3]; paint(); } },
          MODE_SHORT[m]));
        })))))),
    h('p', { class: 'mute small' }, 'Нажимайте на клетку: «—» нельзя, «да» можно, «согл.» только после вашего согласия.')];
  };

  const paint = () => {
    clear(box,
      h('div', { class: 'actions' },
        h('button', { onclick: () => {
          const used = new Set(grants.map(scopeKey));
          const free = scopes.clients.find(c => !used.has('client:' + c.id));
          const def = templates.find(t => t.name === 'Наблюдатель') || templates[0];
          grants.push({ scope_type: used.has('all') && free ? 'client' : used.has('all') ? 'server' : 'all',
                        scope_id: used.has('all') ? (free ? free.id : (scopes.servers[0] || {}).id) : null,
                        template_id: def ? def.id : null, expires_at: null, permissions: def ? { ...def.permissions } : {} });
          paint();
        } }, '+ Добавить область'),
        h('span', { class: 'grow' }),
        seg([['a', 'Коротко'], ['b', 'Подробно']], detailed ? 'b' : 'a', v => { detailed = v === 'b'; paint(); })),
      grants.length ? null : h('div', { class: 'note warn' }, 'Прав нет: человек сможет войти, но ничего не увидит.'),
      detailed ? paint2B() : paint2A(),
      data.ownerOnly.length ? h('p', { class: 'lock' }, '🔒 Только у владельца: ' + data.ownerOnly.map(p => p.title.toLowerCase()).join(', ') + '.') : null);
  };
  paint();
  box.value = () => grants.map(g => ({ ...g, permissions: Object.fromEntries(perms.map(p => [p.code, modeOf(g, p.code)])) }));
  return box;
}

async function pageNewStaff(main) {
  const data = await rightsData();
  clear(main);
  header(main, 'Новый сотрудник', 'Он получит ссылку, задаст пароль и подключит коды на телефоне.');
  const name = h('input', { required: true, autocomplete: 'off' });
  const login = h('input', { required: true, autocapitalize: 'off', spellcheck: 'false', pattern: '[a-z0-9._\\-]{3,32}',
                             title: 'Латиница, цифры, точка, дефис; 3–32 знака' });
  const email = h('input', { type: 'email' });
  const note = h('input', { placeholder: 'Например: фрилансер, на время проекта' });
  const until = h('input', { type: 'date', value: inMonths(3), min: isoDay(new Date()) });
  const forever = h('input', { type: 'checkbox', onchange: () => { until.disabled = forever.checked; } });
  name.addEventListener('input', () => {
    if (login.dataset.touched) return;
    login.value = translit(name.value.trim().split(/\s+/)[0] || '').slice(0, 32);
  });
  login.addEventListener('input', () => { login.dataset.touched = '1'; });
  const def = data.templates.find(t => t.name === 'Наблюдатель') || data.templates[0];
  const rights = rightsEditor(data, def ? [{ scope_type: 'all', template_id: def.id, permissions: def.permissions }] : []);
  const btn = h('button', { class: 'primary', type: 'submit' }, 'Создать и получить ссылку');
  add(main, [h('form', { class: 'stack', onsubmit: e => {
    e.preventDefault();
    act(async () => {
      const r = await POST('/api/staff', {
        display_name: name.value.trim(), login: login.value.trim().toLowerCase(), email: email.value.trim() || null,
        note: note.value.trim() || null, access_expires_at: forever.checked ? null : until.value, grants: rights.value(),
      });
      await inviteDialog(r, name.value.trim());
      location.hash = '#/staff/' + r.id;
    }, btn);
  } },
    h('div', { class: 'group' },
      row('Имя', 'Как его видите вы и журнал', name), row('Логин', 'Им он входит', login),
      row('Почта', 'Необязательно', email), row('Заметка', 'Видно только вам', note),
      row('Доступ до', 'В этот день доступ выключится сам', until, h('label', { class: 'actions' }, forever, 'без срока'))),
    h('h2', {}, 'Права'), rights,
    h('div', { class: 'actions' }, btn, h('a', { href: '#/staff' }, 'Отмена')))]);
  name.focus();
}

function translit(s) {
  const m = { а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm',
              н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'h', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'sch',
              ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya' };
  return s.toLowerCase().split('').map(c => (c in m ? m[c] : c)).join('').replace(/[^a-z0-9._-]/g, '');
}

async function pageStaff(main, id) {
  const [d, data] = await Promise.all([GET('/api/staff/' + id), rightsData()]);
  const p = d.account;
  const owner = p.kind === 'owner';
  const self = p.id === S.me.account.id;
  clear(main);
  header(main, p.display_name, [p.login, ' · ', owner ? 'владелец' : STATUS[p.status][0].toLowerCase(),
    p.created_by ? ` · пригласил ${p.created_by} ${fmtDate(p.created_at)}` : ''],
    h('a', { href: '#/staff' }, '← Все сотрудники'));
  const reload = () => pageStaff(main, id);

  if (owner) {
    add(main, [h('div', { class: 'note' }, self ? 'Это вы. У владельца все права, их нельзя ограничить.' : 'У владельца все права.')]);
  } else {
    const actions = h('div', { class: 'actions' });
    const btn = (label, fn, cls) => h('button', { class: cls, onclick: e => act(fn, e.target) }, label);
    if (p.status === 'disabled') {
      actions.append(btn('Включить доступ', async () => {
        const r = await POST(`/api/staff/${id}/enable`);
        if (r && r.invite_path) await inviteDialog(r, p.display_name);
        toast('Доступ включён'); reload();
      }, 'primary'));
    } else {
      actions.append(btn('Отключить доступ', async () => {
        if (!await confirmBox('Отключить доступ?', `${p.display_name} сразу выйдет из кабинета, его SSH-ключи будут сняты с серверов, а запросы на согласование отменены. Включить обратно можно в любой момент.`, 'Отключить', true)) return;
        await POST(`/api/staff/${id}/disable`); toast('Доступ отключён'); reload();
      }, 'danger'));
      if (p.status === 'invited') actions.append(btn('Новая ссылка-приглашение', async () => {
        await inviteDialog(await POST(`/api/staff/${id}/invite`), p.display_name); reload();
      }));
      else actions.append(btn('Сбросить вход…', async () => {
        if (!await confirmBox('Сбросить пароль и коды?', 'Старые пароль, коды и сеансы перестанут работать. Вы получите новую ссылку, по которой человек всё настроит заново (например, если он потерял телефон).', 'Сбросить', true)) return;
        await inviteDialog(await POST(`/api/staff/${id}/reset`), p.display_name); reload();
      }));
      actions.append(btn('Завершить все сеансы', async () => { await DEL(`/api/staff/${id}/sessions`); toast('Сеансы завершены'); reload(); }));
    }
    add(main, [actions]);

    const name = h('input', { value: p.display_name });
    const email = h('input', { type: 'email', value: p.email || '' });
    const note = h('input', { value: p.note || '' });
    const until = h('input', { type: 'date', value: p.access_expires_at ? isoDay(new Date(p.access_expires_at)) : '' });
    const forever = h('input', { type: 'checkbox', checked: !p.access_expires_at, onchange: () => { until.disabled = forever.checked; } });
    until.disabled = forever.checked;
    const save = h('button', { onclick: e => act(async () => {
      await PATCH(`/api/staff/${id}`, { display_name: name.value.trim(), email: email.value.trim(), note: note.value.trim(),
                                        access_expires_at: forever.checked ? '' : until.value });
      toast('Сохранено'); reload();
    }, e.target) }, 'Сохранить');
    add(main, [h('h2', {}, 'Данные'), h('div', { class: 'group' },
      row('Имя', null, name), row('Почта', null, email), row('Заметка', 'Видно только вам', note),
      row('Доступ до', 'В этот день доступ выключится сам', until, h('label', { class: 'actions' }, forever, 'без срока')),
      row('Вход', null, h('span', { class: p.mfa ? 'ok' : 'mute' }, p.mfa ? 'Пароль и коды настроены' : 'Ещё не зарегистрировался'),
        p.invite_expires_at ? h('span', { class: 'mute' }, ' · ссылка до ' + fmtTime(p.invite_expires_at)) : null),
      h('div', { class: 'row' }, h('span', { class: 'grow' }), save))]);

    const rights = rightsEditor(data, d.grants);
    const saveRights = h('button', { class: 'primary', onclick: e => act(async () => {
      await PUT(`/api/staff/${id}/grants`, { grants: rights.value() });
      toast('Права сохранены'); reload();
    }, e.target) }, 'Сохранить права');
    add(main, [h('h2', {}, 'Права'), rights, h('div', { class: 'actions', style: 'margin-top:10px' }, saveRights,
      h('span', { class: 'mute small' }, 'Попросим код с телефона.'))]);
  }

  add(main, [h('h2', {}, 'Сеансы'), sessionsTable(d.sessions, null)]);
  add(main, [h('h2', {}, 'SSH-ключи'), keysTable(d.ssh_keys, owner ? null : async k => {
    if (!await confirmBox('Отозвать ключ?', 'Ключ будет снят со всех серверов при следующей синхронизации с Mac владельца.', 'Отозвать', true)) return;
    await DEL(`/api/staff/${id}/ssh-keys/${k.id}`); toast('Ключ отозван'); reload();
  })]);
  add(main, [h('p', {}, h('a', { href: '#/audit?actor=' + id }, 'Действия этого человека в журнале →'))]);
}

function sessionsTable(list, onEnd) {
  return table(['Устройство', 'Адрес', 'Вход', 'Последний раз', ''], list.map(s => h('tr', {},
    h('td', {}, s.device || 'Неизвестно', s.current ? h('span', { class: 'pill g' }, ' это вы') : null),
    h('td', { class: 'mono' }, s.ip || '—'), h('td', { class: 'nowrap' }, fmtTime(s.created_at)),
    h('td', { class: 'nowrap' }, ago(s.last_seen_at)),
    h('td', {}, onEnd && !s.current ? h('button', { onclick: e => act(() => onEnd(s), e.target) }, 'Завершить') : null))),
  'Активных сеансов нет');
}

function keysTable(list, onRevoke) {
  return table(['Название', 'Отпечаток', 'Серверы', 'Добавлен', ''], list.map(k => h('tr', {},
    h('td', {}, k.label || k.type), h('td', { class: 'mono small' }, k.fingerprint),
    h('td', { class: 'nowrap' }, `${k.servers_installed} из ${k.servers_wanted}`,
      k.pending ? h('div', { class: 'mute small' }, 'ждёт Mac владельца') : null),
    h('td', { class: 'nowrap' }, fmtDate(k.created_at)),
    h('td', {}, onRevoke ? h('button', { class: 'danger', onclick: e => act(() => onRevoke(k), e.target) }, 'Отозвать') : null))),
  'Ключей нет');
}

// MARK: Templates

async function pageTemplates(main) {
  const data = await rightsData();
  clear(main);
  const owner = isOwner();
  header(main, 'Шаблоны ролей', 'Готовые наборы прав. Сотруднику выбирают шаблон и при надобности правят пару переключателей.',
    owner ? h('button', { class: 'primary', onclick: () => editTemplate(main, data, null) }, 'Новый шаблон…') : null);
  add(main, [table(['Название', 'Что можно', 'С согласия', 'Сотрудников', ''], data.templates.map(t => {
    const by = m => data.perms.filter(p => t.permissions[p.code] === m).map(p => p.title).join(', ') || '—';
    return h('tr', { class: owner ? 'click' : null, onclick: owner ? () => editTemplate(main, data, t) : null },
      h('td', {}, h('b', {}, t.name), t.built_in ? h('span', { class: 'mute small' }, ' встроенный') : null,
        t.description ? h('div', { class: 'mute small' }, t.description) : null),
      h('td', { class: 'small' }, by('allow')), h('td', { class: 'small' }, by('approval')),
      h('td', { class: 'num' }, t.used_by), h('td', {}, owner ? h('button', { class: 'link' }, 'Изменить') : null));
  }), 'Шаблонов нет')]);
}

function editTemplate(main, data, t) {
  const perms = { ...(t ? t.permissions : {}) };
  const name = h('input', { value: t ? t.name : '', required: true });
  const desc = h('input', { value: t ? t.description || '' : '' });
  const groups = [...new Set(data.perms.map(p => p.group))];
  clear(main);
  header(main, t ? `Шаблон «${t.name}»` : 'Новый шаблон', t && t.used_by ? `Изменения сразу коснутся сотрудников с этим шаблоном: ${t.used_by}.` : null,
    h('button', { onclick: () => route() }, '← Все шаблоны'));
  const save = h('button', { class: 'primary', onclick: e => act(async () => {
    const body = { name: name.value, description: desc.value, permissions: perms };
    if (t) await PUT('/api/templates/' + t.id, body); else await POST('/api/templates', body);
    toast('Шаблон сохранён'); route();
  }, e.target) }, 'Сохранить');
  add(main, [h('div', { class: 'stack' },
    h('div', { class: 'group' }, row('Название', null, name), row('Описание', 'Кому подходит', desc)),
    h('div', { class: 'group' }, groups.map(grp => [h('div', { class: 'title' }, grp),
      data.perms.filter(p => p.group === grp).map(p => row(p.title, null, seg(MODES, perms[p.code] || 'deny', v => { perms[p.code] = v; }, true)))])),
    h('div', { class: 'actions' }, save,
      t && !t.built_in ? h('button', { class: 'danger', onclick: e => act(async () => {
        if (!await confirmBox('Удалить шаблон?', 'У сотрудников с этим шаблоном права останутся как есть, просто без названия роли.', 'Удалить', true)) return;
        await DEL('/api/templates/' + t.id); toast('Шаблон удалён'); route();
      }, e.target) }, 'Удалить') : null))]);
}

// MARK: Approvals

async function pageApprovals(main) {
  const all = new URLSearchParams(location.hash.split('?')[1] || '').get('all') === '1';
  const list = await GET('/api/approvals' + (all ? '' : '?status=pending'));
  const owner = isOwner();
  clear(main);
  header(main, owner ? 'Согласования' : 'Мои запросы',
    owner ? 'Действия сотрудников, которые вы разрешили только с вашего согласия. Запрос живёт 30 минут.' : 'Действия, которые ждут согласия владельца.',
    seg([['p', 'Ждут'], ['a', 'Все']], all ? 'a' : 'p', v => { location.hash = '#/approvals' + (v === 'a' ? '?all=1' : ''); }));
  const ST = { pending: ['Ждёт', 'y'], approved: ['Согласовано', 'g'], rejected: ['Отклонено', 'r'], expired: ['Истекло', ''], executed: ['Выполнено', 'g'] };
  add(main, [table(['Когда', 'Кто', 'Что', 'Зачем', 'Состояние', ''], list.map(r => h('tr', {},
    h('td', { class: 'nowrap' }, fmtTime(r.created_at)), h('td', {}, r.requested_by.name),
    h('td', {}, r.permission_title, r.object_name ? h('div', { class: 'mute small' }, r.object_name) : null),
    h('td', {}, r.reason || '—'),
    h('td', {}, h('span', { class: 'pill ' + (ST[r.status] || ['', ''])[1] }, (ST[r.status] || [r.status])[0]),
      r.decided_by ? h('div', { class: 'mute small' }, `${r.decided_by}, ${fmtTime(r.decided_at)}`) : null,
      r.status === 'pending' ? h('div', { class: 'mute small' }, 'до ' + fmtTime(r.expires_at, false)) : null),
    h('td', { class: 'nowrap' }, owner && r.status === 'pending' ? [
      h('button', { class: 'primary', onclick: e => act(async () => { await POST(`/api/approvals/${r.id}/approve`); toast('Согласовано'); await loadMe(); route(); }, e.target) }, 'Согласовать'), ' ',
      h('button', { onclick: e => act(async () => { await POST(`/api/approvals/${r.id}/reject`); toast('Отклонено'); await loadMe(); route(); }, e.target) }, 'Отклонить')] : null))),
  all ? 'Запросов не было' : 'Ничего не ждёт')]);
}

// MARK: Audit

async function pageAudit(main) {
  const q = new URLSearchParams(location.hash.split('?')[1] || '');
  const filters = { q: q.get('q') || '', result: q.get('result') || '', action: q.get('action') || '', actor: q.get('actor') || '' };
  const fetchPage = before => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(filters)) if (v) p.set(k, v);
    if (before) p.set('before', before);
    p.set('limit', '100');
    return GET('/api/audit?' + p);
  };
  const first = await fetchPage(null);
  clear(main);
  header(main, 'Журнал действий', canStaff() ? 'Кто, что и когда сделал в кабинете и с объектами.' : 'Ваши действия.');
  const search = h('input', { type: 'search', placeholder: 'Поиск: имя, объект, действие', value: filters.q });
  const result = h('select', {}, h('option', { value: '' }, 'Любой итог'),
    Object.entries(RESULT).map(([k, [t]]) => h('option', { value: k, selected: k === filters.result }, t)));
  const action = h('select', {}, h('option', { value: '' }, 'Любое действие'),
    Object.entries(ACTIONS).sort((a, b) => a[1].localeCompare(b[1], 'ru')).map(([k, t]) => h('option', { value: k, selected: k === filters.action }, t)));
  const apply = e => {
    e.preventDefault();
    const p = new URLSearchParams();
    if (search.value) p.set('q', search.value);
    if (result.value) p.set('result', result.value);
    if (action.value) p.set('action', action.value);
    if (filters.actor) p.set('actor', filters.actor);
    location.hash = '#/audit' + (p.toString() ? '?' + p : '');
  };
  add(main, [h('form', { class: 'actions', onsubmit: apply, style: 'margin-bottom:10px' }, search, action, result,
    h('button', { type: 'submit' }, 'Показать'),
    filters.actor ? h('a', { href: '#/audit' }, 'Все люди') : null)]);
  const body = h('tbody');
  const more = h('button', {}, 'Показать ещё');
  const put = list => {
    for (const l of list) {
      const [rt, rc] = RESULT[l.result] || [l.result, ''];
      const detail = l.detail && typeof l.detail === 'object'
        ? Object.entries(l.detail).filter(([k, v]) => v && k !== 'object_name').map(([k, v]) => `${k}: ${v}`).join('; ') : '';
      body.append(h('tr', {},
        h('td', { class: 'nowrap' }, fmtTime(l.ts)),
        h('td', {}, l.actor_name || (l.actor_kind === 'system' ? 'Хаб' : '—')),
        h('td', {}, actionTitle(l.action, l.action_title), detail ? h('div', { class: 'mute small' }, detail) : null),
        h('td', {}, l.object_name || ''),
        h('td', {}, h('span', { class: 'pill ' + rc }, rt), l.error ? h('div', { class: 'err small' }, l.error) : null),
        h('td', { class: 'small mute' }, [l.ip, l.device].filter(Boolean).join(', '))));
    }
    more.hidden = list.length < 100;
    if (list.length) more.dataset.before = list[list.length - 1].ts;
  };
  more.addEventListener('click', e => act(async () => put(await fetchPage(more.dataset.before)), e.target));
  if (!first.length) add(main, [h('div', { class: 'scroll' }, empty('Записей нет'))]);
  else {
    add(main, [h('div', { class: 'scroll' }, h('table', {}, h('thead', {}, h('tr', {},
      ['Когда', 'Кто', 'Действие', 'Объект', 'Итог', 'Откуда'].map(x => h('th', {}, x)))), body)),
      h('div', { class: 'actions', style: 'margin-top:10px' }, more)]);
    put(first);
  }
}

// MARK: Settings: profile

async function pageProfile(main) {
  const [sessions, keys] = await Promise.all([GET('/api/me/sessions'), GET('/api/me/ssh-keys')]);
  const a = S.me.account;
  clear(main);
  header(main, 'Профиль и вход', `${a.displayName} · ${a.login}${a.accessExpiresAt ? ' · доступ до ' + fmtDate(a.accessExpiresAt) : ''}`);

  const cur = h('input', { type: 'password', autocomplete: 'current-password', required: true });
  const n1 = h('input', { type: 'password', autocomplete: 'new-password', required: true, minlength: 12 });
  const n2 = h('input', { type: 'password', autocomplete: 'new-password', required: true });
  const pbtn = h('button', { type: 'submit' }, 'Сменить пароль');
  add(main, [h('h2', {}, 'Пароль'), h('form', { class: 'group', onsubmit: e => {
    e.preventDefault();
    if (n1.value !== n2.value) { toast('Новые пароли не совпадают'); return; }
    act(async () => {
      await POST('/api/me/password', { current: cur.value, new: n1.value });
      cur.value = n1.value = n2.value = '';
      toast('Пароль изменён. Другие сеансы завершены.');
      pageProfile(main);
    }, pbtn);
  } }, row('Текущий пароль', null, cur), row('Новый пароль', 'Не короче 12 знаков', n1), row('Ещё раз', null, n2),
    h('div', { class: 'row' }, h('span', { class: 'mute small grow' }, 'Попросим код с телефона. Остальные устройства выйдут.'), pbtn))]);

  add(main, [h('h2', {}, 'Запасные коды'), h('div', { class: 'group' }, row('Новый набор запасных кодов',
    'Старые коды перестанут работать. Нужны, если потеряется телефон.',
    h('button', { onclick: e => act(async () => {
      const r = await POST('/api/me/recovery-codes');
      const text = 'Запасные коды для входа в кабинет «Мониторинг»\n' + r.recovery_codes.join('\n') + '\n';
      await dialog(close => [h('h3', {}, 'Новые запасные коды'), h('p', {}, 'Сохраните их сейчас: показываем один раз.'),
        h('div', { class: 'codes' }, r.recovery_codes.map(c => h('div', {}, c))),
        h('div', { class: 'actions' }, h('button', { onclick: () => download('zapasnye-kody.txt', text) }, 'Скачать'),
          h('span', { class: 'grow' }), h('button', { class: 'primary', onclick: () => close(true) }, 'Сохранил'))]);
    }, e.target) }, 'Получить новые…')))]);

  add(main, [h('h2', {}, 'Где вы вошли'), sessionsTable(sessions, async s => {
    await DEL('/api/me/sessions/' + s.id); toast('Сеанс завершён'); pageProfile(main);
  })]);

  const key = h('textarea', { placeholder: 'ssh-ed25519 AAAA… имя@компьютер', spellcheck: 'false', class: 'mono' });
  const label = h('input', { placeholder: 'Например: ноутбук' });
  const kbtn = h('button', { type: 'submit' }, 'Добавить ключ');
  add(main, [h('h2', {}, 'SSH-ключи'),
    h('p', { class: 'mute' }, 'Открытый ключ (файл .pub). Он попадёт только на серверы, где вам можно входить по SSH. Ставит его Mac владельца.'),
    keysTable(keys, async k => {
      if (!await confirmBox('Отозвать ключ?', 'Он будет снят с серверов.', 'Отозвать', true)) return;
      await DEL('/api/me/ssh-keys/' + k.id); toast('Ключ отозван'); pageProfile(main);
    }),
    h('form', { class: 'form', style: 'margin-top:10px; max-width:640px', onsubmit: e => {
      e.preventDefault();
      act(async () => { await POST('/api/me/ssh-keys', { key: key.value.trim(), label: label.value.trim() }); toast('Ключ добавлен'); pageProfile(main); }, kbtn);
    } }, field('Открытый ключ', key), field('Название', label), h('div', { class: 'actions' }, kbtn))]);
}

// MARK: Settings: appearance

const APPEARANCE = [
  ['theme', 'Тема', null, [['system', 'Как в системе'], ['light', 'Светлая'], ['dark', 'Тёмная']]],
  ['accent', 'Цвет акцента', null, [['system', 'Синий'], ['green', 'Зелёный'], ['orange', 'Оранжевый'], ['purple', 'Фиолетовый'], ['graphite', 'Графит']]],
  ['density', 'Плотность таблиц', null, [['compact', 'Плотно'], ['normal', 'Просторно']]],
  ['font_size', 'Размер текста', null, [['small', 'Мельче'], ['normal', 'Обычный'], ['large', 'Крупнее']]],
  ['start_page', 'Первая страница', 'Что открывать после входа', [['overview', 'Обзор'], ['staff', 'Сотрудники'], ['audit', 'Журнал']]],
  ['time_format', 'Время', null, [['24h', '14:30'], ['12h', '2:30 PM']]],
  ['date_format', 'Дата', null, [['dd.mm.yyyy', '31.12.2026'], ['yyyy-mm-dd', '2026-12-31']]],
  ['units_traffic', 'Трафик', 'В приложении на Mac и в отчётах', [['bits', 'Мбит/с'], ['bytes', 'МБ/с']]],
  ['chart_default_period', 'Период графиков', 'По умолчанию', [['1h', '1 ч'], ['6h', '6 ч'], ['24h', '24 ч'], ['7d', '7 дн'], ['30d', '30 дн']]],
  ['sound', 'Звук тревог', 'В приложении на Mac', [['on', 'Вкл'], ['off', 'Выкл']]],
  ['reduce_motion', 'Без анимаций', null, [[false, 'Нет'], [true, 'Да']]],
];

async function pageAppearance(main) {
  const p = await GET('/api/me/prefs');
  S.me.prefs = p;
  applyPrefs();
  clear(main);
  const locked = new Set(p.locked || []);
  header(main, 'Оформление', isOwner() ? 'Ваши личные настройки. Общие для сотрудников задаются в разделе «Компания».' : 'Меняется сразу и только у вас.');
  const setPref = async (key, value) => {
    await act(async () => { S.me.prefs = await PUT('/api/me/prefs', { [key]: value }); applyPrefs(); });
  };
  add(main, [h('div', { class: 'group' }, APPEARANCE.map(([key, label, hint, opts]) => {
    const cur = p.values[key] !== undefined ? p.values[key] : opts[0][0];
    const isLocked = locked.has(key) && !isOwner();
    const control = opts.length > 4 && key !== 'accent' && key !== 'chart_default_period'
      ? h('select', { disabled: isLocked, onchange: e => setPref(key, e.target.value) }, opts.map(([v, t]) => h('option', { value: v, selected: v === cur }, t)))
      : seg(opts.map(([v, t]) => [String(v), t]), String(cur), v => setPref(key, v === 'true' ? true : v === 'false' ? false : v));
    if (isLocked && control.classList.contains('seg')) for (const b of control.children) b.disabled = true;
    const own = Object.prototype.hasOwnProperty.call(p.mine || {}, key);
    return row(label, isLocked ? '🔒 Задано владельцем для всех' : hint, control,
      own && !isLocked ? h('button', { class: 'link small', onclick: async () => { await setPref(key, null); pageAppearance(main); } }, 'Как у всех') : null);
  }))]);
}

// MARK: Settings: notifications

async function pageNotify(main) {
  const n = await GET('/api/me/notify');
  clear(main);
  header(main, 'Уведомления', 'Когда и куда присылать тревоги лично вам.');
  const sev = seg([['1', 'Все'], ['2', 'Только критичные']], String(n.min_severity), v => { n.min_severity = +v; });
  const from = h('input', { type: 'time', value: n.quiet_from || '' });
  const to = h('input', { type: 'time', value: n.quiet_to || '' });
  const days = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'].map((d, i) =>
    h('label', {}, h('input', { type: 'checkbox', value: i + 1, checked: (n.quiet_days || []).includes(i + 1) }), ' ', d));
  const crit = h('input', { type: 'checkbox', checked: n.critical_in_quiet });
  const duty = h('input', { type: 'checkbox', checked: n.on_duty_only });
  const digest = h('input', { type: 'checkbox', checked: n.digest_enabled });
  const digestTime = h('input', { type: 'time', value: n.digest_time || '09:00' });
  const channels = [['telegram', 'Telegram'], ['macos', 'Mac (приложение)']].map(([c, t]) =>
    h('label', {}, h('input', { type: 'checkbox', value: c, checked: (n.channels || []).includes(c) }), ' ', t));
  const save = h('button', { class: 'primary', onclick: e => act(async () => {
    await PUT('/api/me/notify', {
      min_severity: n.min_severity, quiet_from: from.value || null, quiet_to: to.value || null,
      quiet_days: days.map(l => l.firstChild).filter(c => c.checked).map(c => +c.value),
      critical_in_quiet: crit.checked, on_duty_only: duty.checked, digest_enabled: digest.checked, digest_time: digestTime.value,
      channels: channels.map(l => l.firstChild).filter(c => c.checked).map(c => c.value),
    });
    toast('Сохранено');
  }, e.target) }, 'Сохранить');
  add(main, [h('div', { class: 'group' },
    row('Какие тревоги', null, sev),
    row('Куда', null, h('div', { class: 'actions' }, channels)),
    row('Тихие часы', 'В это время тревоги не приходят', from, '—', to),
    row('Дни тихих часов', null, h('div', { class: 'actions' }, days)),
    row('Критичные в тихие часы', 'Всё равно присылать', crit),
    row('Только когда я дежурю', null, duty),
    row('Утренняя сводка', 'Короткий итог за ночь', digest, digestTime),
    h('div', { class: 'row' }, h('span', { class: 'grow' }), save))]);
  add(main, [h('h2', {}, 'Telegram'), await telegramBlock(false)]);
}

/** Telegram is another part of the hub; when it isn't there yet, say so. */
async function telegramBlock(ownerSetup) {
  const box = h('div', { class: 'group' });
  let st;
  try { st = await GET('/api/telegram/status'); }
  catch (e) {
    if (e.status === 404) return h('div', { class: 'note' }, 'Telegram ещё не подключён на хабе: эта часть появится с обновлением хаба.');
    return h('div', { class: 'note bad' }, e.message);
  }
  const bot = st.bot || {};
  const me = st.me || {};
  if (ownerSetup) {
    const token = h('input', { type: 'password', autocomplete: 'off', placeholder: bot.configured ? 'Токен задан. Новый заменит его.' : '123456:ABC…' });
    add(box, [row('Бот', bot.configured ? `Подключён: @${bot.username || '?'}` : 'Создайте бота у @BotFather и вставьте его токен',
      token, h('button', { onclick: e => act(async () => {
        await PUT('/api/telegram/bot', { token: token.value.trim() }); token.value = ''; toast('Токен сохранён');
      }, e.target) }, 'Сохранить'))]);
    return box;
  }
  if (!bot.configured) {
    add(box, [row('Бот ещё не настроен', isOwner() ? 'Токен бота задаётся в разделе «Компания»' : 'Его настраивает владелец', null)]);
    return box;
  }
  if (me.linked) {
    add(box, [row(`Подключён: @${me.username || ''}`, me.linked_at ? 'с ' + fmtDate(me.linked_at) : null,
      h('button', { onclick: e => act(async () => { await DEL('/api/telegram/link'); toast('Telegram отключён'); route(); }, e.target) }, 'Отключить'))]);
  } else {
    add(box, [row('Подключить Telegram', `Откроется бот @${bot.username || ''}, нажмите в нём «Start».`,
      h('button', { class: 'primary', onclick: e => act(async () => {
        const r = await POST('/api/telegram/link');
        window.open(r.url, '_blank', 'noopener');
        await dialog(close => [h('h3', {}, 'Откройте ссылку в Telegram'), copyBox(r.url),
          h('p', { class: 'mute small' }, 'Ссылка работает до ' + fmtTime(r.expires_at, false) + '. Потом обновите страницу.'),
          h('div', { class: 'actions' }, h('span', { class: 'grow' }), h('button', { class: 'primary', onclick: () => close(true) }, 'Готово'))]);
        route();
      }, e.target) }, 'Подключить Telegram'))]);
  }
  return box;
}

// MARK: Company (owner)

async function pageCompany(main) {
  const [org, p] = await Promise.all([GET('/api/org'), GET('/api/me/prefs')]);
  clear(main);
  header(main, 'Компания', 'Видят все сотрудники и клиенты в отчётах.');
  const f = {
    company_name: h('input', { value: org.company_name || '' }),
    brand_color: h('input', { type: 'color', value: org.brand_color || '#0a64d6' }),
    report_footer: h('textarea', { value: org.report_footer || '' }),
    contact_email: h('input', { type: 'email', value: org.contact_email || '' }),
    contact_phone: h('input', { type: 'tel', value: org.contact_phone || '' }),
    default_timezone: h('input', { value: org.default_timezone || 'Europe/Moscow', placeholder: 'Europe/Moscow' }),
    session_timeout_minutes: h('input', { type: 'number', min: 15, max: 10080, value: org.session_timeout_minutes || 720 }),
  };
  const save = h('button', { class: 'primary', onclick: e => act(async () => {
    const body = {};
    for (const [k, el] of Object.entries(f)) body[k] = k === 'session_timeout_minutes' ? +el.value : el.value;
    await PUT('/api/org', body);
    await loadMe(); toast('Сохранено'); route();
  }, e.target) }, 'Сохранить');
  add(main, [h('div', { class: 'group' },
    row('Название', 'В шапке кабинета и в отчётах', f.company_name),
    row('Фирменный цвет', 'Для отчётов клиентам', f.brand_color),
    row('Подпись в отчётах', null, f.report_footer),
    row('Почта для связи', null, f.contact_email), row('Телефон для связи', null, f.contact_phone),
    row('Часовой пояс', 'Например Europe/Moscow', f.default_timezone),
    row('Выход без действий через, мин', 'От 15 минут до 7 дней', f.session_timeout_minutes),
    h('div', { class: 'row' }, h('span', { class: 'grow' }), save))]);

  const locked = new Set(p.locked || []);
  add(main, [h('h2', {}, 'Оформление по умолчанию'),
    h('p', { class: 'mute' }, 'Так кабинет выглядит у новых сотрудников. С замком сотрудник не сможет это поменять.'),
    h('div', { class: 'group' }, APPEARANCE.map(([key, label, , opts]) => {
      let value = p.defaults[key] !== undefined ? p.defaults[key] : opts[0][0];
      const lock = h('input', { type: 'checkbox', checked: locked.has(key) });
      const put = () => act(async () => { await PUT('/api/org/defaults', { [key]: { value: JSON.stringify(value), locked: lock.checked } }); toast('Сохранено'); });
      lock.addEventListener('change', put);
      const control = h('select', { onchange: e => { value = opts.find(o => String(o[0]) === e.target.value)[0]; put(); } },
        opts.map(([v, t]) => h('option', { value: String(v), selected: v === value }, t)));
      return row(label, null, control, h('label', { class: 'lock' }, lock, ' 🔒 закрепить'));
    }))]);

  add(main, [h('h2', {}, 'Telegram-бот'), await telegramBlock(true)]);
}

// MARK: Start

route();
