/* forksmartdns WebUI — SPA (no build step, no external resources). */
(function () {
	'use strict';

	var F = window.FSD;
	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
	var E = F.escapeHtml;

	var state = {
		session: null,
		csrf: '',
		status: null,
		schema: [],
		schemaByKey: {},
		config: null,
		route: 'overview',
		qlog: { page_num: 1, page_size: 50, domain: '', client: '', domain_type: '', is_blocked: '', is_cached: '' },
		timer: null
	};

	var ROUTES = [
		{ id: 'overview', title: 'Обзор', sub: 'Состояние, QPS, топ доменов и клиентов', icon: '◉', group: 'Мониторинг' },
		{ id: 'querylog', title: 'Query Log', sub: 'Журнал DNS-запросов из stats-моста', icon: '≡', group: 'Мониторинг' },
		{ id: 'cache', title: 'Кэш', sub: 'Размер, содержимое и сброс кэша', icon: '▣', group: 'Мониторинг' },
		{ id: 'upstreams', title: 'Upstream DNS', sub: 'UDP, TCP, DoT, DoH, HTTP/3, DoQ', icon: '⇅', group: 'DNS' },
		{ id: 'listeners', title: 'Слушатели', sub: 'Адреса и протоколы, на которых отвечает ядро', icon: '◌', group: 'DNS' },
		{ id: 'groups', title: 'Группы', sub: 'group-begin / group-match и наследование', icon: '◈', group: 'DNS' },
		{ id: 'domains', title: 'Правила доменов', sub: 'address, nameserver, domain-rules, записи', icon: 'ⓓ', group: 'DNS' },
		{ id: 'lists', title: 'Списки', sub: 'domain-set, ip-set, block-file, hosts-file', icon: '☰', group: 'DNS' },
		{ id: 'clients', title: 'Клиенты', sub: 'client-rules по IP, CIDR и MAC', icon: '☷', group: 'DNS' },
		{ id: 'ipset', title: 'IPSet / NFTSet', sub: 'Заполнение наборов адресами из ответов', icon: '⬡', group: 'DNS' },
		{ id: 'settings', title: 'Настройки', sub: 'Глобальные параметры ядра', icon: '⚙', group: 'Система' },
		{ id: 'service', title: 'Служба', sub: 'Управление, логи и диагностика', icon: '⏻', group: 'Система' },
		{ id: 'backups', title: 'Резервные копии', sub: 'Создание, скачивание и восстановление', icon: '⛁', group: 'Система' },
		{ id: 'config', title: 'Конфигурация', sub: 'Полный редактор, валидация и применение', icon: '⌘', group: 'Система' },
		{ id: 'about', title: 'О системе', sub: 'Возможности, версии и ограничения', icon: 'ⓘ', group: 'Система' }
	];

	function esc(v) { return E(v); }
	function isObj(v) { return v && typeof v === 'object'; }

	// ---------------------------------------------------------------------
	// API
	// ---------------------------------------------------------------------

	function ApiError(code, message, detail) {
		this.name = 'ApiError';
		this.code = code;
		this.message = message;
		this.detail = detail;
	}
	ApiError.prototype = Object.create(Error.prototype);

	function buildUrl(action, params) {
		var q = 'action=' + encodeURIComponent(action);
		if (params) {
			Object.keys(params).forEach(function (k) {
				var v = params[k];
				if (v === undefined || v === null || v === '') return;
				q += '&' + encodeURIComponent(k) + '=' + encodeURIComponent(v);
			});
		}
		return 'cgi-bin/api.cgi?' + q;
	}

	function api(action, opts) {
		opts = opts || {};
		var method = opts.method || 'GET';
		var url = buildUrl(action, opts.params);
		var headers = {};
		if (state.csrf && method !== 'GET') headers['X-FSD-CSRF'] = state.csrf;
		var init = { method: method, credentials: 'same-origin', headers: headers, cache: 'no-store' };
		if (opts.form) {
			headers['Content-Type'] = 'application/x-www-form-urlencoded';
			init.body = new URLSearchParams(opts.form).toString();
		} else if (opts.raw !== undefined) {
			headers['Content-Type'] = 'text/plain; charset=utf-8';
			init.body = opts.raw;
		} else if (opts.blob) {
			headers['Content-Type'] = 'application/gzip';
			init.body = opts.blob;
		}
		return fetch(url, init).then(function (res) {
			return res.text().then(function (text) {
				var data = null;
				try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
				if (res.status === 401) {
					state.csrf = '';
					showLogin('Сессия истекла. Войдите снова.');
					throw new ApiError('unauthorized', 'Требуется авторизация');
				}
				if (!data) {
					throw new ApiError('bad_response', 'Сервер вернул не-JSON ответ (HTTP ' + res.status + ')');
				}
				if (!data.ok) {
					var err = data.error || {};
					throw new ApiError(err.code || 'error', err.message || 'Ошибка API', err.detail || '');
				}
				return data.data;
			});
		});
	}

	function apiSafe(action, opts) {
		return api(action, opts).catch(function (e) {
			if (e instanceof ApiError && e.code === 'bridge') return null;
			if (e instanceof ApiError && e.code === 'unauthorized') throw e;
			return null;
		});
	}

	// ---------------------------------------------------------------------
	// UI primitives
	// ---------------------------------------------------------------------

	function toast(message, type, ms) {
		var root = $('#toasts');
		var el = document.createElement('div');
		el.className = 'toast ' + (type || 'info');
		el.textContent = message;
		root.appendChild(el);
		setTimeout(function () { el.remove(); }, ms || 4200);
	}

	function closeModal() {
		$('#modal-root').innerHTML = '';
	}

	function openModal(html) {
		var root = $('#modal-root');
		root.innerHTML = '<div class="modal-backdrop"><div class="modal">' + html + '</div></div>';
		var backdrop = $('.modal-backdrop', root);
		backdrop.addEventListener('click', function (ev) {
			if (ev.target === backdrop) closeModal();
		});
		$$('[data-close]', root).forEach(function (b) {
			b.addEventListener('click', closeModal);
		});
		return root;
	}

	function confirmDialog(title, text, okLabel) {
		return new Promise(function (resolve) {
			openModal(
				'<div class="modal-head"><h2>' + esc(title) + '</h2><div class="spacer"></div><button class="btn btn-ghost btn-icon" data-close type="button">✕</button></div>' +
				'<div class="modal-body"><p>' + text + '</p></div>' +
				'<div class="modal-foot"><button class="btn" data-close type="button">Отмена</button>' +
				'<button class="btn btn-danger" id="confirm-ok" type="button">' + esc(okLabel || 'Подтвердить') + '</button></div>'
			);
			$('#confirm-ok').addEventListener('click', function () { closeModal(); resolve(true); });
			$$('[data-close]').forEach(function (b) { b.addEventListener('click', function () { resolve(false); }); });
		});
	}

	function fieldHtml(f) {
		var v = f.value == null ? '' : f.value;
		var id = 'f_' + f.name;
		var hint = f.hint ? '<div class="hint">' + esc(f.hint) + '</div>' : '';
		var cls = 'field' + (f.wide ? ' wide' : '');
		var input;
		if (f.type === 'select') {
			input = '<select class="select" id="' + id + '" name="' + esc(f.name) + '">' +
				(f.options || []).map(function (o) {
					return '<option value="' + esc(o.value) + '"' + (String(o.value) === String(v) ? ' selected' : '') + '>' + esc(o.label) + '</option>';
				}).join('') + '</select>';
		} else if (f.type === 'textarea') {
			input = '<textarea class="textarea' + (f.tall ? ' tall' : '') + '" id="' + id + '" name="' + esc(f.name) + '" placeholder="' + esc(f.placeholder || '') + '">' + esc(v) + '</textarea>';
		} else if (f.type === 'checkbox') {
			input = '<label class="check"><input type="checkbox" id="' + id + '" name="' + esc(f.name) + '"' + (v ? ' checked' : '') + '> ' + esc(f.checkboxLabel || f.label) + '</label>';
		} else {
			input = '<input class="input" id="' + id + '" name="' + esc(f.name) + '" type="' + esc(f.type || 'text') + '" value="' + esc(v) + '" placeholder="' + esc(f.placeholder || '') + '"' +
				(f.autocomplete ? ' autocomplete="' + esc(f.autocomplete) + '"' : '') + '>';
		}
		if (f.type === 'checkbox') {
			return '<div class="' + cls + '">' + input + hint + '<div class="err hidden"></div></div>';
		}
		return '<div class="' + cls + '"><label for="' + id + '">' + esc(f.label) + '</label>' + input + hint + '<div class="err hidden"></div></div>';
	}

	function formModal(opts) {
		var fields = opts.fields || [];
		var body = fields.map(fieldHtml).join('');
		var root = openModal(
			'<form id="modal-form">' +
			'<div class="modal-head"><h2>' + esc(opts.title) + '</h2><div class="spacer"></div>' +
			'<button class="btn btn-ghost btn-icon" data-close type="button">✕</button></div>' +
			'<div class="modal-body"><div class="form-grid">' + body + '</div>' +
			'<div class="banner err hidden" id="modal-error" style="margin-top:14px"></div>' +
			(opts.note ? '<div class="banner info" style="margin-top:14px">' + opts.note + '</div>' : '') + '</div>' +
			'<div class="modal-foot"><button class="btn" data-close type="button">Отмена</button>' +
			'<button class="btn btn-primary" id="modal-submit" type="submit">' + esc(opts.submitLabel || 'Сохранить') + '</button></div>' +
			'</form>'
		);
		var form = $('#modal-form', root);
		form.addEventListener('submit', function (ev) {
			ev.preventDefault();
			var values = {};
			var errEl = $('#modal-error', root);
			errEl.classList.add('hidden');
			var bad = false;
			fields.forEach(function (f) {
				var el = form.elements[f.name];
				var val = f.type === 'checkbox' ? !!el.checked : String(el.value || '').trim();
				values[f.name] = val;
				var msg = '';
				if (f.validate) msg = f.validate(val, values) || '';
				if (!msg && f.required && val === '') msg = 'обязательное поле';
				if (msg) {
					bad = true;
					var wrap = el.closest('.field');
					if (wrap) {
						var e = $('.err', wrap);
						if (e) { e.textContent = msg; e.classList.remove('hidden'); }
					}
				}
			});
			if (bad) return;
			var btn = $('#modal-submit', root);
			btn.disabled = true;
			Promise.resolve(opts.onSubmit(values)).then(function () {
				closeModal();
			}).catch(function (e) {
				btn.disabled = false;
				errEl.textContent = e && e.message ? e.message : String(e);
				errEl.classList.remove('hidden');
			});
		});
	}

	function tableHtml(columns, rows, emptyText) {
		if (!rows.length) return '<div class="empty">' + esc(emptyText || 'Нет записей') + '</div>';
		return '<div class="table-wrap"><table class="table"><thead><tr>' +
			columns.map(function (c) { return '<th>' + esc(c.title) + '</th>'; }).join('') +
			'</tr></thead><tbody>' +
			rows.map(function (r) {
				return '<tr>' + columns.map(function (c) {
					var val = c.render ? c.render(r) : esc(r[c.key]);
					return '<td class="' + (c.cls || '') + '">' + val + '</td>';
				}).join('') + '</tr>';
			}).join('') + '</tbody></table></div>';
	}

	function badge(text, cls) {
		return '<span class="badge ' + (cls || '') + '">' + esc(text) + '</span>';
	}

	function setPage(title, sub, actionsHtml) {
		$('#page-title').textContent = title;
		$('#page-sub').textContent = sub || '';
		$('#top-actions').innerHTML = actionsHtml || '';
	}

	function loading() {
		$('#view').innerHTML = '<div class="card"><div class="skeleton" style="width:30%;margin-bottom:10px"></div><div class="skeleton" style="width:70%;margin-bottom:10px"></div><div class="skeleton" style="width:50%"></div></div>';
	}

	function errorView(e) {
		$('#view').innerHTML = '<div class="banner err">' + esc(e && e.message ? e.message : String(e)) +
			(e && e.detail ? '<pre class="pre" style="margin-top:10px">' + esc(e.detail) + '</pre>' : '') + '</div>';
	}

	function svgBars(items, labelKey, valueKey) {
		if (!items || !items.length) return '<div class="empty">Нет данных</div>';
		var w = 640, h = 170, padL = 30, padB = 22, padT = 10;
		var max = 1;
		items.forEach(function (it) { max = Math.max(max, Number(it[valueKey]) || 0); });
		var n = items.length;
		var bw = Math.max(2, (w - padL - 6) / n * 0.7);
		var gap = (w - padL - 6) / n;
		var bars = items.map(function (it, i) {
			var v = Number(it[valueKey]) || 0;
			var bh = (h - padT - padB) * v / max;
			var x = padL + i * gap + (gap - bw) / 2;
			var y = h - padB - bh;
			return '<rect class="bar" x="' + x.toFixed(1) + '" y="' + y.toFixed(1) + '" width="' + bw.toFixed(1) +
				'" height="' + Math.max(0, bh).toFixed(1) + '" rx="2"><title>' + esc(it[labelKey]) + ': ' + v + '</title></rect>';
		}).join('');
		var step = Math.max(1, Math.ceil(n / 8));
		var labels = items.map(function (it, i) {
			if (i % step !== 0) return '';
			var x = padL + i * gap + gap / 2;
			return '<text class="chart-label" x="' + x.toFixed(1) + '" y="' + (h - 5) + '" text-anchor="middle">' + esc(String(it[labelKey]).slice(-5)) + '</text>';
		}).join('');
		return '<svg class="chart" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" role="img">' +
			'<line class="chart-axis" x1="' + padL + '" y1="' + (h - padB) + '" x2="' + w + '" y2="' + (h - padB) + '"/>' +
			'<line class="chart-axis" x1="' + padL + '" y1="' + padT + '" x2="' + padL + '" y2="' + (h - padB) + '"/>' +
			bars + labels + '</svg>';
	}

	function qs(obj) {
		return Object.keys(obj).filter(function (k) { return obj[k] !== '' && obj[k] !== undefined && obj[k] !== null; })
			.map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]); }).join('&');
	}

	// ---------------------------------------------------------------------
	// bootstrap / login
	// ---------------------------------------------------------------------

	function showLogin(message) {
		state.session = null;
		var box = $('#login');
		box.classList.remove('hidden');
		api('session').then(function (s) {
			state.session = s;
			var inner;
			if (s.setup_required) {
				inner = '<div class="login-logo">fs</div><h1>Первичная настройка</h1>' +
					'<p>Введите установочный токен (напечатан установщиком, файл <span class="mono">' + esc('setup-token') + '</span>) и задайте пароль администратора.</p>' +
					'<form id="setup-form" class="stack">' +
					'<div class="field"><label>Установочный токен</label><input class="input" name="token" autocomplete="off" autofocus></div>' +
					'<div class="field"><label>Пароль (не короче 8 символов)</label><input class="input" name="password" type="password" autocomplete="new-password"></div>' +
					'<div class="field"><label>Повторите пароль</label><input class="input" name="password2" type="password" autocomplete="new-password"></div>' +
					'<div class="banner err hidden" id="login-error"></div>' +
					'<button class="btn btn-primary" type="submit">Задать пароль и войти</button></form>';
			} else if (!s.initialized) {
				inner = '<div class="login-logo">fs</div><h1>Пароль не задан</h1>' +
					'<p>Выполните на роутере <code>forksmartdnsctl passwd</code>, затем обновите страницу.</p>';
			} else {
				inner = '<div class="login-logo">fs</div><h1>forksmartdns</h1>' +
					'<p>Вход в панель управления изолированным SmartDNS.</p>' +
					'<form id="login-form" class="stack">' +
					'<div class="field"><label>Пароль администратора</label><input class="input" name="password" type="password" autocomplete="current-password" autofocus></div>' +
					'<div class="banner err hidden" id="login-error">' + esc(message || '') + '</div>' +
					'<button class="btn btn-primary" type="submit">Войти</button></form>';
			}
			$('#login-card').innerHTML = inner;
			var setupForm = $('#setup-form');
			if (setupForm) {
				setupForm.addEventListener('submit', function (ev) {
					ev.preventDefault();
					var f = ev.target.elements;
					var err = $('#login-error');
					if (f.password.value.length < 8) { err.textContent = 'Пароль короче 8 символов'; err.classList.remove('hidden'); return; }
					if (f.password.value !== f.password2.value) { err.textContent = 'Пароли не совпадают'; err.classList.remove('hidden'); return; }
					state.csrf = '';
					api('setup', { method: 'POST', form: { token: f.token.value, password: f.password.value } })
						.then(function (d) { afterAuth(d); }).catch(function (e) { err.textContent = e.message; err.classList.remove('hidden'); });
				});
			}
			var loginForm = $('#login-form');
			if (loginForm) {
				loginForm.addEventListener('submit', function (ev) {
					ev.preventDefault();
					var err = $('#login-error');
					var pwd = ev.target.elements.password.value;
					api('login', { method: 'POST', form: { password: pwd } })
						.then(function (d) { afterAuth(d); })
						.catch(function (e) { err.textContent = e.message; err.classList.remove('hidden'); });
				});
			}
		}).catch(function (e) {
			$('#login-card').innerHTML = '<div class="login-logo">fs</div><h1>Ошибка</h1><p>' + esc(e.message) + '</p>';
		});
	}

	function afterAuth(d) {
		state.csrf = d.csrf || '';
		$('#login').classList.add('hidden');
		boot().catch(function (e) { toast(e.message, 'err'); });
	}

	// ---------------------------------------------------------------------
	// navigation / status
	// ---------------------------------------------------------------------

	function buildNav() {
		var lastGroup = '';
		var html = '';
		ROUTES.forEach(function (r) {
			if (r.group !== lastGroup) {
				html += '<div class="nav-group">' + esc(r.group) + '</div>';
				lastGroup = r.group;
			}
			html += '<a href="#/' + r.id + '" data-route="' + r.id + '"><span class="nav-ico">' + r.icon + '</span>' + esc(r.title) + '</a>';
		});
		$('#nav').innerHTML = html;
	}

	function updateNav() {
		$$('#nav a').forEach(function (a) {
			a.classList.toggle('active', a.getAttribute('data-route') === state.route);
		});
	}

	function loadStatus(force) {
		if (state.status && !force) return Promise.resolve(state.status);
		return api('status').then(function (s) {
			state.status = s;
			renderSidebarStatus();
			return s;
		});
	}

	function renderSidebarStatus() {
		var s = state.status;
		if (!s) return;
		var run = s.service && s.service.running;
		$('#sidebar-status').innerHTML =
			'<div>' + (run ? badge('DNS работает', 'ok') : badge('DNS остановлен', 'err')) + ' ' +
			(s.bridge === 'up' ? badge('stats', 'info') : badge('без stats', 'warn')) + '</div>' +
			'<div class="mono small" style="margin-top:6px">' + esc(s.instance.ui.port) + ' · ' + esc(s.instance.dns.port) + '</div>' +
			'<div class="small" style="margin-top:4px">ядро ' + esc(s.service.core_version || '—') + '</div>';
	}

	function route() {
		var hash = location.hash.replace(/^#\/?/, '');
		var id = hash.split('?')[0] || 'overview';
		var found = ROUTES.filter(function (r) { return r.id === id; })[0];
		if (!found) { id = 'overview'; found = ROUTES[0]; }
		state.route = id;
		updateNav();
		if (state.timer) { clearInterval(state.timer); state.timer = null; }
		var fn = views[id];
		if (!fn) { $('#view').innerHTML = '<div class="banner err">Раздел не найден</div>'; return; }
		fn().catch(function (e) { errorView(e); });
	}

	function boot() {
		return loadStatus(true).then(function () {
			buildNav();
			$('#btn-logout').onclick = function () {
				api('logout', { method: 'POST' }).then(function () {
					state.csrf = '';
					state.status = null;
					showLogin('');
				}).catch(function (e) { toast(e.message, 'err'); });
			};
			$('#btn-password').onclick = function () {
				formModal({
					title: 'Сменить пароль администратора',
					fields: [
						{ name: 'current', label: 'Текущий пароль', type: 'password', required: true, autocomplete: 'current-password' },
						{ name: 'new', label: 'Новый пароль', type: 'password', required: true, autocomplete: 'new-password' },
						{ name: 'confirm', label: 'Повторите новый пароль', type: 'password', required: true, autocomplete: 'new-password' }
					],
					onSubmit: function (v) {
						if (v.new.length < 8) throw new Error('Пароль короче 8 символов');
						if (v.new !== v.confirm) throw new Error('Пароли не совпадают');
						return api('password', { method: 'POST', form: { current: v.current, new: v.new } }).then(function (d) {
							if (d && d.csrf) state.csrf = d.csrf;
							toast('Пароль изменён, остальные сессии завершены', 'ok');
						});
					}
				});
			};
			if (!location.hash) location.hash = '#/overview';
			route();
		});
	}

	// ---------------------------------------------------------------------
	// shared actions
	// ---------------------------------------------------------------------

	function refreshView() {
		state.status = null;
		route();
	}

	function serviceAction(action) {
		return api('service', { method: 'POST', form: { action: action } }).then(function (d) {
			toast(d.output || ('служба: ' + action), 'ok');
			state.status = null;
			return loadStatus(true);
		}).then(function () {
			refreshView();
		});
	}

	function configLoad(force) {
		if (state.config && !force) return Promise.resolve(state.config);
		return api('config.get').then(function (c) {
			state.config = c;
			return c;
		});
	}

	function configInvalidate() { state.config = null; }

	function saveBlock(name, text, restart) {
		return api('config.block', {
			method: 'POST',
			params: { name: name, restart: restart === false ? 0 : 1 },
			raw: text
		}).then(function (d) {
			configInvalidate();
			state.status = null;
			toast('Сохранено и применено' + (d.backup ? ' (бэкап: ' + d.backup + ')' : ''), 'ok');
			return d;
		});
	}

	function globalsValues() {
		var parsed = F.parseGlobals(state.config ? state.config.blocks.globals : '');
		return parsed.map;
	}

	function schemaRow(key) {
		return state.schemaByKey[key] || null;
	}

	function inputForSchema(row, value) {
		var v = value === undefined || value === null ? '' : value;
		var id = 'g_' + row.key;
		if (row.type === 'yesno') {
			return '<select class="select" id="' + id + '" data-key="' + esc(row.key) + '">' +
				'<option value=""' + (v === '' ? ' selected' : '') + '>по умолчанию (' + esc(row.defaultValue) + ')</option>' +
				'<option value="yes"' + (v === 'yes' ? ' selected' : '') + '>yes</option>' +
				'<option value="no"' + (v === 'no' ? ' selected' : '') + '>no</option></select>';
		}
		if (row.type === 'enum' || row.type === 'loglevel' || row.type === 'response') {
			return '<select class="select" id="' + id + '" data-key="' + esc(row.key) + '">' +
				'<option value=""' + (v === '' ? ' selected' : '') + '>по умолчанию (' + esc(row.defaultValue) + ')</option>' +
				row.enumValues.map(function (o) {
					return '<option value="' + esc(o) + '"' + (v === o ? ' selected' : '') + '>' + esc(o) + '</option>';
				}).join('') + '</select>';
		}
		return '<input class="input" id="' + id + '" data-key="' + esc(row.key) + '" value="' + esc(v) +
			'" placeholder="' + esc(row.defaultValue || '') + '">';
	}

	function settingsFieldsHtml(rows) {
		return rows.map(function (row) {
			return '<div class="field"><label for="g_' + esc(row.key) + '">' + esc(row.label) +
				' <span class="mono muted small">' + esc(row.key) + '</span></label>' +
				inputForSchema(row, globalsValues()[row.key]) +
				(row.hint ? '<div class="hint">' + esc(row.hint) + '</div>' : '') +
				(row.defaultValue ? '<div class="hint">по умолчанию: <span class="mono">' + esc(row.defaultValue) + '</span></div>' : '') +
				'</div>';
		}).join('');
	}

	function collectSettings(rows) {
		var values = {};
		var errors = [];
		rows.forEach(function (row) {
			var el = document.querySelector('[data-key="' + row.key + '"]');
			if (!el) return;
			var v = String(el.value || '').trim();
			if (v === '') return;
			var msg = F.validateValue(row, v);
			if (msg) { errors.push(row.label + ': ' + msg); return; }
			if (v !== row.defaultValue) values[row.key] = v;
			else if (globalsValues()[row.key] !== undefined) values[row.key] = v;
		});
		return { values: values, errors: errors };
	}

	function saveSettings(rows) {
		var res = collectSettings(rows);
		if (res.errors.length) {
			toast(res.errors[0], 'err', 6000);
			return Promise.reject(new Error(res.errors.join('; ')));
		}
		return configLoad().then(function (cfg) {
			var all = {};
			var current = globalsValues();
			Object.keys(current).forEach(function (k) { all[k] = current[k]; });
			rows.forEach(function (row) {
				if (Object.prototype.hasOwnProperty.call(res.values, row.key)) all[row.key] = res.values[row.key];
				else delete all[row.key];
			});
			var text = F.renderGlobals(cfg.blocks.globals, state.schema, all);
			return saveBlock('globals', text, true);
		});
	}

	// ---------------------------------------------------------------------
	// views: overview
	// ---------------------------------------------------------------------

	var views = {};

	views.overview = function () {
		setPage('Обзор', 'Состояние экземпляра и статистика', '');
		loading();
		return loadStatus(true).then(function (s) {
			return Promise.all([
				apiSafe('stats.metrics'),
				apiSafe('stats.overview'),
				apiSafe('stats.hourly', { params: { past_hours: 24 } }),
				apiSafe('stats.top.domain', { params: { count: 10 } }),
				apiSafe('stats.top.client', { params: { count: 10 } }),
				apiSafe('stats.upstream')
			]).then(function (r) {
				var m = r[0] || {};
				var ov = r[1] || {};
				var hourly = (r[2] && r[2].hourly_query_count) || [];
				var topD = (r[3] && r[3].domain_top_list) || [];
				var topC = (r[4] && r[4].client_top_list) || [];
				var up = (r[5] && r[5].upstream_server_list) || [];
				var running = s.service.running;
				var html = '';
				if (s.warnings && s.warnings.length) {
					html += '<div class="stack" style="margin-bottom:14px">' + s.warnings.map(function (w) {
						return '<div class="banner warn">' + esc(w) + '</div>';
					}).join('') + '</div>';
				}
				html += '<div class="grid cols-4">' +
					'<div class="card stat"><div class="label">Служба</div><div class="value" style="font-size:1.15rem">' +
					(running ? badge('работает', 'ok') : badge('остановлена', 'err')) + '</div>' +
					'<div class="hint">PID ' + esc(s.service.pid || '—') + ' · ' + esc(F.formatUptime(s.service.uptime)) + '</div></div>' +
					'<div class="card stat"><div class="label">Запросов всего</div><div class="value">' + esc(m.total_query_count == null ? '—' : m.total_query_count) + '</div>' +
					'<div class="hint">QPS ' + esc(m.qps == null ? '—' : m.qps) + ' · заблокировано ' + esc(m.block_query_count == null ? '—' : m.block_query_count) + '</div></div>' +
					'<div class="card stat"><div class="label">Cache hit</div><div class="value">' + esc(m.cache_hit_rate == null ? '—' : (Number(m.cache_hit_rate).toFixed(1) + '%')) + '</div>' +
					'<div class="hint">' + esc(m.cache_number == null ? '—' : m.cache_number) + ' записей · ' + esc(F.formatBytes(m.cache_memory_size)) + '</div></div>' +
					'<div class="card stat"><div class="label">Средний ответ</div><div class="value">' + esc(m.avg_query_time == null ? '—' : (Number(m.avg_query_time).toFixed(1) + ' мс')) + '</div>' +
					'<div class="hint">память ' + esc(F.formatBytes(m.memory_usage)) + ' · потери ' + esc(m.request_drop_count == null ? '—' : m.request_drop_count) + '</div></div>' +
					'</div>';

				if (s.bridge !== 'up') {
					html += '<div class="banner warn" style="margin-top:14px">Stats-мост ядра недоступен — карточки статистики пусты. ' +
						'Причина обычно в том, что <span class="mono">ui-enable yes</span> выключен или ядро не hrdns. ' +
						'Проверьте «Служба» → «Диагностика».</div>';
				}

				html += '<div class="grid cols-2" style="margin-top:14px">' +
					'<div class="card"><div class="card-head"><h2>Запросы за 24 часа</h2><div class="spacer"></div>' +
					'<span class="muted small">всего ' + esc(m.total_query_count == null ? '—' : m.total_query_count) + '</span></div>' +
					svgBars(hourly, 'hour', 'query_count') + '</div>' +
					'<div class="card"><div class="card-head"><h2>Экземпляр</h2></div>' +
					'<dl class="kv">' +
					'<dt>Версия WebUI</dt><dd>' + esc(s.instance.version) + '</dd>' +
					'<dt>Ядро</dt><dd>' + esc(s.instance.core_kind) + ' · ' + esc(s.service.core_version || '—') + '</dd>' +
					'<dt>DNS</dt><dd class="mono">' + esc(s.instance.dns.bind) + ':' + esc(s.instance.dns.port) + '</dd>' +
					'<dt>Панель</dt><dd class="mono">' + esc(s.instance.ui.bind) + ':' + esc(s.instance.ui.port) + '</dd>' +
					'<dt>Имя сервера</dt><dd>' + esc(ov.server_name || '—') + '</dd>' +
					'<dt>Старт ядра</dt><dd>' + esc(F.formatTime(ov.startup_timestamp)) + '</dd>' +
					'<dt>База журнала</dt><dd>' + esc(F.formatBytes(ov.database_size)) + ' · свободно ' + esc(F.formatBytes(ov.free_disk_space)) + '</dd>' +
					'</dl>' +
					'<div class="row" style="margin-top:14px">' +
					'<button class="btn" data-svc="restart">Перезапустить</button>' +
					(running ? '<button class="btn btn-danger" data-svc="stop">Остановить</button>' : '<button class="btn btn-primary" data-svc="start">Запустить</button>') +
					'<a class="btn btn-ghost" href="#/service">Логи и диагностика</a></div></div>' +
					'</div>';

				html += '<div class="grid cols-2" style="margin-top:14px">' +
					'<div class="card"><div class="card-head"><h2>Топ доменов</h2></div>' +
					tableHtml([
						{ title: 'Домен', render: function (r) { return '<span class="mono">' + esc(r.domain) + '</span>'; } },
						{ title: 'Запросов', cls: 'right', render: function (r) { return esc(r.query_count); } }
					], topD, 'Статистика недоступна') + '</div>' +
					'<div class="card"><div class="card-head"><h2>Топ клиентов</h2></div>' +
					tableHtml([
						{ title: 'Клиент', render: function (r) { return '<span class="mono">' + esc(r.client_ip) + '</span>' + (r.client_mac ? '<div class="muted small mono">' + esc(r.client_mac) + '</div>' : ''); } },
						{ title: 'Запросов', cls: 'right', render: function (r) { return esc(r.query_count); } }
					], topC, 'Статистика недоступна') + '</div>' +
					'</div>';

				html += '<div class="card" style="margin-top:14px"><div class="card-head"><h2>Upstream: состояние</h2>' +
					'<div class="spacer"></div><a class="btn btn-ghost btn-sm" href="#/upstreams">Настроить</a></div>' +
					tableHtml([
						{ title: 'Сервер', render: function (r) { return '<span class="mono">' + esc(r.host || r.ip) + '</span><div class="muted small">' + esc(r.server_type) + ' · :' + esc(r.port) + '</div>'; } },
						{ title: 'Статус', render: function (r) { return badge(r.status, r.status === 'Normal' ? 'ok' : (r.status === 'Abnormal' ? 'err' : 'warn')); } },
						{ title: 'Успех', cls: 'right', render: function (r) { return esc(r.query_success_rate) + '%'; } },
						{ title: 'Ср. время', cls: 'right', render: function (r) { return esc(r.avg_time) + ' мс'; } },
						{ title: 'Запросов', cls: 'right', render: function (r) { return esc(r.total_query_count); } }
					], up, 'Нет данных stats-моста') + '</div>';

				$('#view').innerHTML = html;
				$$('[data-svc]').forEach(function (b) {
					b.addEventListener('click', function () {
						var act = b.getAttribute('data-svc');
						if (act === 'stop' || act === 'restart') {
							confirmDialog('Подтверждение', 'Выполнить <b>' + esc(act) + '</b> для экземпляра forksmartdns?', 'Выполнить')
								.then(function (ok) { if (ok) serviceAction(act).catch(function (e) { toast(e.message, 'err'); }); });
						} else {
							serviceAction(act).catch(function (e) { toast(e.message, 'err'); });
						}
					});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: upstreams
	// ---------------------------------------------------------------------

	var UPSTREAM_TYPES = [
		{ value: 'udp', label: 'UDP (server)', directive: 'server', def: 53 },
		{ value: 'tcp', label: 'TCP (server-tcp)', directive: 'server-tcp', def: 53 },
		{ value: 'tls', label: 'DoT (server-tls)', directive: 'server-tls', def: 853 },
		{ value: 'https', label: 'DoH (server-https)', directive: 'server-https', def: 443 },
		{ value: 'h3', label: 'HTTP/3 (server-h3)', directive: 'server-h3', def: 443 },
		{ value: 'quic', label: 'DoQ (server-quic)', directive: 'server-quic', def: 853 }
	];

	function upstreamTypeOf(directive) {
		var t = UPSTREAM_TYPES.filter(function (x) { return x.directive === directive; })[0];
		return t || { value: 'udp', label: directive, directive: directive };
	}

	function upstreamGroups(item) {
		var groups = [];
		for (var i = 0; i < item.args.length; i++) {
			if ((item.args[i] === '-group' || item.args[i] === '-g') && i + 1 < item.args.length) groups.push(item.args[i + 1]);
		}
		return groups;
	}

	function upstreamExtra(item) {
		var out = [];
		for (var i = 0; i < item.args.length; i++) {
			if (item.args[i] === '-group' || item.args[i] === '-g') { i++; continue; }
			if (item.args[i] === '-exclude-default-group' || item.args[i] === '-e') continue;
			if (i === 0) continue;
			out.push(item.args[i]);
		}
		return out.join(' ');
	}

	function upstreamForm(values, onSubmit) {
		formModal({
			title: values.index >= 0 ? 'Изменить upstream' : 'Добавить upstream',
			fields: [
				{ name: 'type', label: 'Протокол', type: 'select', options: UPSTREAM_TYPES.map(function (t) { return { value: t.value, label: t.label }; }), value: values.type, required: true },
				{ name: 'address', label: 'Адрес', value: values.address, required: true, placeholder: '8.8.8.8 или https://dns.google/dns-query', hint: 'Для DoH/DoT/DoQ можно указать IP, hostname или URL.' },
				{ name: 'groups', label: 'Группы (через запятую)', value: values.groups, placeholder: 'office, kids', hint: 'Каждая группа попадёт как -group.' },
				{ name: 'exclude', label: 'Исключить из default', type: 'checkbox', value: values.exclude, checkboxLabel: '-exclude-default-group' },
				{ name: 'extra', label: 'Доп. опции', value: values.extra, placeholder: '-host-name dns.example -spki-pin sha256//...', wide: true, hint: 'Любые поддерживаемые ядром опции сервера, через пробел.' }
			],
			onSubmit: onSubmit
		});
	}

	views.upstreams = function () {
		setPage('Upstream DNS', 'UDP, TCP, DoT, DoH, HTTP/3 и DoQ', '<button class="btn" id="btn-refresh">Обновить</button>');
		loading();
		return Promise.all([configLoad(true), apiSafe('stats.upstream')]).then(function (r) {
			var cfg = r[0];
			var up = (r[1] && r[1].upstream_server_list) || [];
			var items = F.parseLines(cfg.blocks.upstreams);
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'Изменения записываются в блок <span class="mono">fsd:upstreams</span> и применяются перезапуском ядра. ' +
				'Протоколы HTTP/3 и DoQ зависят от сборки ядра — проверка отмечена на странице «О системе».</div>';
			html += '<div class="card"><div class="card-head"><h2>Сконфигурированные серверы</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Протокол', render: function (it) { var t = upstreamTypeOf(it.directive); return badge(t.label, t.value === 'udp' ? '' : 'info'); } },
					{ title: 'Адрес', render: function (it) { return '<span class="mono">' + esc(it.args[0] || '') + '</span>'; } },
					{ title: 'Группы', render: function (it) { var g = upstreamGroups(it); return g.length ? g.map(function (x) { return badge(x, 'info'); }).join(' ') : '<span class="muted">default</span>'; } },
					{ title: 'Опции', render: function (it) { var x = upstreamExtra(it); return x ? '<span class="mono small">' + esc(x) + '</span>' : '<span class="muted">—</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm" data-edit="' + esc(it.raw) + '">Изменить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], items, 'Серверы не заданы — ядро не сможет резолвить имена') + '</div>';

			html += '<div class="card" style="margin-top:14px"><div class="card-head"><h2>Состояние из stats-моста</h2></div>' +
				tableHtml([
					{ title: 'Сервер', render: function (x) { return '<span class="mono">' + esc(x.host || x.ip) + '</span>'; } },
					{ title: 'Тип', render: function (x) { return esc(x.server_type); } },
					{ title: 'Статус', render: function (x) { return badge(x.status, x.status === 'Normal' ? 'ok' : (x.status === 'Abnormal' ? 'err' : 'warn')); } },
					{ title: 'Успех', cls: 'right', render: function (x) { return esc(x.query_success_rate) + '%'; } },
					{ title: 'Ср. время', cls: 'right', render: function (x) { return esc(x.avg_time) + ' мс'; } },
					{ title: 'Безопасность', render: function (x) { return esc(x.security); } }
				], up, 'Stats-мост недоступен') + '</div>';

			$('#view').innerHTML = html;
			$('#btn-refresh').addEventListener('click', refreshView);

			function collect() {
				var list = F.parseLines($('#view').querySelector('textarea') ? '' : '');
				return list;
			}
			var current = items.slice();

			function persist(next) {
				return saveBlock('upstreams', F.renderItems(next), true).then(refreshView);
			}

			$('#btn-add').addEventListener('click', function () {
				upstreamForm({ index: -1, type: 'udp', address: '', groups: '', exclude: false, extra: '' }, function (v) {
					var t = UPSTREAM_TYPES.filter(function (x) { return x.value === v.type; })[0] || UPSTREAM_TYPES[0];
					var args = [v.address];
					(v.groups || '').split(',').map(function (s) { return s.trim(); }).filter(Boolean).forEach(function (g) { args.push('-group', g); });
					if (v.exclude) args.push('-exclude-default-group');
					if (v.extra) args.push.apply(args, v.extra.split(/\s+/).filter(Boolean));
					current.push({ directive: t.directive, args: args, raw: '' });
					return persist(current);
				});
			});

			$$('[data-edit]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-edit');
					var idx = current.map(function (i) { return i.raw; }).indexOf(raw);
					if (idx < 0) return;
					var it = current[idx];
					var t = upstreamTypeOf(it.directive);
					upstreamForm({
						index: idx, type: t.value, address: it.args[0] || '', groups: upstreamGroups(it).join(', '),
						exclude: it.args.indexOf('-exclude-default-group') >= 0 || it.args.indexOf('-e') >= 0, extra: upstreamExtra(it)
					}, function (v) {
						var tt = UPSTREAM_TYPES.filter(function (x) { return x.value === v.type; })[0] || UPSTREAM_TYPES[0];
						var args = [v.address];
						(v.groups || '').split(',').map(function (s) { return s.trim(); }).filter(Boolean).forEach(function (g) { args.push('-group', g); });
						if (v.exclude) args.push('-exclude-default-group');
						if (v.extra) args.push.apply(args, v.extra.split(/\s+/).filter(Boolean));
						current[idx] = { directive: tt.directive, args: args, raw: '' };
						return persist(current);
					});
				});
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-del');
					confirmDialog('Удалить upstream?', 'Сервер <span class="mono">' + esc(raw) + '</span> будет удалён из конфигурации.', 'Удалить')
						.then(function (ok) {
							if (!ok) return;
							current = current.filter(function (i) { return i.raw !== raw; });
							persist(current).catch(function (e) { toast(e.message, 'err'); });
						});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: listeners
	// ---------------------------------------------------------------------

	views.listeners = function () {
		setPage('Слушатели', 'Адреса, протоколы и порты DNS-сервера', '');
		loading();
		return configLoad(true).then(function (cfg) {
			var items = F.parseLines(cfg.blocks.listeners);
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'Эти адреса — DNS-услышители нашего изолированного ядра, не панель. Панель слушает свой порт ' +
				'(<span class="mono">' + esc(state.status.instance.ui.port) + '</span>) и не меняется здесь. ' +
				'Для TLS/DoH-услышителей ядро создаёт самоподписанный сертификат; свои файлы задаются в сыром конфиге.</div>';
			html += '<div class="card"><div class="card-head"><h2>Bind-правила</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Тип', render: function (it) { return badge(it.directive, 'info'); } },
					{ title: 'Адрес', render: function (it) { return '<span class="mono">' + esc(it.args[0] || '') + '</span>'; } },
					{ title: 'Опции', render: function (it) { return it.args.length > 1 ? '<span class="mono small">' + esc(it.args.slice(1).join(' ')) + '</span>' : '<span class="muted">—</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm" data-edit="' + esc(it.raw) + '">Изменить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], items, 'Нет bind-правил: ядро откроет порт 53 по умолчанию') + '</div>';

			$('#view').innerHTML = html;
			var current = items.slice();

			function persist(next) {
				return saveBlock('listeners', F.renderItems(next), true).then(refreshView);
			}
			function addForm(values, idx) {
				formModal({
					title: idx >= 0 ? 'Изменить слушатель' : 'Добавить слушатель',
					fields: [
						{ name: 'type', label: 'Тип', type: 'select', value: values.type, options: [
							{ value: 'bind', label: 'UDP (bind)' }, { value: 'bind-tcp', label: 'TCP (bind-tcp)' },
							{ value: 'bind-tls', label: 'DoT (bind-tls)' }, { value: 'bind-https', label: 'DoH (bind-https)' },
							{ value: 'bind-http', label: 'DoH без TLS (bind-http)' }
						] },
						{ name: 'address', label: 'Адрес', value: values.address, required: true, placeholder: '0.0.0.0:5353 или [::]:5353' },
						{ name: 'extra', label: 'Опции', value: values.extra, wide: true, placeholder: '-group office -no-cache' }
					],
					onSubmit: function (v) {
						var args = [v.address];
						if (v.extra) args.push.apply(args, v.extra.split(/\s+/).filter(Boolean));
						var item = { directive: v.type, args: args, raw: '' };
						if (idx >= 0) current[idx] = item; else current.push(item);
						return persist(current);
					}
				});
			}
			$('#btn-add').addEventListener('click', function () {
				addForm({ type: 'bind', address: '0.0.0.0:' + state.status.instance.dns.port, extra: '' }, -1);
			});
			$$('[data-edit]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-edit');
					var idx = current.map(function (i) { return i.raw; }).indexOf(raw);
					if (idx < 0) return;
					var it = current[idx];
					addForm({ type: it.directive, address: it.args[0] || '', extra: it.args.slice(1).join(' ') }, idx);
				});
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-del');
					confirmDialog('Удалить слушатель?', 'Правило <span class="mono">' + esc(raw) + '</span> будет удалено.', 'Удалить')
						.then(function (ok) {
							if (!ok) return;
							current = current.filter(function (i) { return i.raw !== raw; });
							persist(current).catch(function (e) { toast(e.message, 'err'); });
						});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: groups
	// ---------------------------------------------------------------------

	views.groups = function () {
		setPage('Группы', 'group-begin / group-match / group-end', '');
		loading();
		return configLoad(true).then(function (cfg) {
			var parsed = F.groupMatches(cfg.blocks.groups);
			var groups = parsed.groups;
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'Группы задают правила и наследование для доменов/клиентов. Привязка upstream к группе делается ' +
				'на странице «Upstream DNS» опцией <span class="mono">-group</span>. Внутри группы можно задавать ' +
				'любые директивы — они попадут в блок.</div>';
			html += '<div class="card"><div class="card-head"><h2>Группы</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Имя', render: function (g) { return '<span class="mono">' + esc(g.name) + '</span>'; } },
					{ title: 'Наследование', render: function (g) { return esc(F.valueOf(['group-begin'].concat(g.options), '-inherit') || 'default'); } },
					{ title: 'Матчи', render: function (g) { return g.matches.length ? g.matches.map(function (m) { return badge((m.domain || '') + (m.client ? ' @' + m.client : ''), 'info'); }).join(' ') : '<span class="muted">—</span>'; } },
					{ title: 'Директивы', render: function (g) { return g.extra.length ? '<span class="mono small">' + esc(g.extra.join('; ')) + '</span>' : '<span class="muted">—</span>'; } },
					{
						title: '', cls: 'actions', render: function (g) {
							return '<button class="btn btn-sm" data-edit="' + esc(g.name) + '">Изменить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(g.name) + '">Удалить</button>';
						}
					}
				], groups, 'Группы не заданы') + '</div>';
			$('#view').innerHTML = html;

			function persist(next) {
				return saveBlock('groups', F.renderGroupsForm(next), true).then(refreshView);
			}
			function form(values, idx) {
				formModal({
					title: idx >= 0 ? 'Изменить группу' : 'Добавить группу',
					fields: [
						{ name: 'name', label: 'Имя группы', value: values.name, required: true, placeholder: 'office' },
						{ name: 'inherit', label: 'Наследование', value: values.inherit, placeholder: 'parent | none | default' },
						{ name: 'domain', label: 'Домен (group-match -domain)', value: values.domain, placeholder: 'example.com' },
						{ name: 'client', label: 'Клиент (group-match -client-ip)', value: values.client, placeholder: '192.168.1.0/24 или MAC' },
						{ name: 'extra', label: 'Доп. директивы внутри группы', type: 'textarea', value: values.extra, wide: true, placeholder: 'speed-check-mode ping\nrr-ttl-min 60' }
					],
					onSubmit: function (v) {
						var g = { name: v.name, options: [], matches: [], extra: [] };
						if (v.inherit) g.options = ['-inherit', v.inherit];
						if (v.domain || v.client) g.matches.push({ domain: v.domain, client: v.client });
						if (v.extra) g.extra = v.extra.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
						if (idx >= 0) groups[idx] = g; else groups.push(g);
						return persist(groups);
					}
				});
			}
			$('#btn-add').addEventListener('click', function () {
				form({ name: '', inherit: 'default', domain: '', client: '', extra: '' }, -1);
			});
			$$('[data-edit]').forEach(function (b) {
				b.addEventListener('click', function () {
					var name = b.getAttribute('data-edit');
					var idx = groups.map(function (g) { return g.name; }).indexOf(name);
					if (idx < 0) return;
					var g = groups[idx];
					var m = g.matches[0] || {};
					form({
						name: g.name, inherit: F.valueOf(['x'].concat(g.options), '-inherit'),
						domain: m.domain || '', client: m.client || '', extra: g.extra.join('\n')
					}, idx);
				});
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var name = b.getAttribute('data-del');
					confirmDialog('Удалить группу?', 'Группа <span class="mono">' + esc(name) + '</span> будет удалена. Серверы, привязанные к ней, останутся, но группа перестанет существовать.', 'Удалить')
						.then(function (ok) {
							if (!ok) return;
							groups = groups.filter(function (g) { return g.name !== name; });
							persist(groups).catch(function (e) { toast(e.message, 'err'); });
						});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: domains
	// ---------------------------------------------------------------------

	var DOMAIN_TYPES = [
		{ value: 'address', label: 'address — вернуть IP / # / -', needValue: '1.2.3.4 или # или -' },
		{ value: 'nameserver', label: 'nameserver — отправить в группу', needValue: 'office или -' },
		{ value: 'domain-rules', label: 'domain-rules — набор опций', needValue: '-group office -speed-check-mode ping' },
		{ value: 'cname', label: 'cname — подменить CNAME', needValue: 'target.example.com' },
		{ value: 'srv-record', label: 'srv-record', needValue: 'target,port,priority,weight' },
		{ value: 'https-record', label: 'https-record (SVCB/HTTPS)', needValue: 'ipv4hint=1.2.3.4' },
		{ value: 'txt-record', label: 'txt-record', needValue: 'text' },
		{ value: 'local-domain', label: 'local-domain — локальный домен', needValue: '' },
		{ value: 'ddns-domain', label: 'ddns-domain', needValue: '' }
	];

	views.domains = function () {
		setPage('Правила доменов', 'address, nameserver, domain-rules и записи', '');
		loading();
		return configLoad(true).then(function (cfg) {
			var items = F.parseLines(cfg.blocks.domains);
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'Селектор домена — <span class="mono">/example.com/</span> или <span class="mono">/domain-set:name/</span>. ' +
				'Правила применяются к ответам ядра и перекрывают default-группу.</div>';
			html += '<div class="card"><div class="card-head"><h2>Правила</h2><div class="spacer"></div>' +
				'<input class="input" id="filter" placeholder="Фильтр по домену/типу" style="max-width:260px"> ' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				'<div id="domains-table"></div></div>';
			$('#view').innerHTML = html;

			function renderTable() {
				var q = ($('#filter').value || '').toLowerCase();
				var filtered = items.filter(function (it) { return !q || it.raw.toLowerCase().indexOf(q) >= 0; });
				$('#domains-table').innerHTML = tableHtml([
					{ title: 'Тип', render: function (it) { return badge(it.directive, 'info'); } },
					{ title: 'Селектор', render: function (it) { return '<span class="mono">' + esc(it.args[0] || '') + '</span>'; } },
					{ title: 'Значение / опции', render: function (it) { return '<span class="mono small">' + esc(it.args.slice(1).join(' ')) + '</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm" data-edit="' + esc(it.raw) + '">Изменить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], filtered, 'Правил нет');
				$$('[data-edit]').forEach(function (b) {
					b.addEventListener('click', function () {
						var raw = b.getAttribute('data-edit');
						var idx = items.map(function (i) { return i.raw; }).indexOf(raw);
						if (idx < 0) return;
						var it = items[idx];
						form({
							type: it.directive, selector: it.args[0] || '', value: it.args.slice(1).join(' ')
						}, idx);
					});
				});
				$$('[data-del]').forEach(function (b) {
					b.addEventListener('click', function () {
						var raw = b.getAttribute('data-del');
						confirmDialog('Удалить правило?', '<span class="mono">' + esc(raw) + '</span>', 'Удалить').then(function (ok) {
							if (!ok) return;
							items = items.filter(function (i) { return i.raw !== raw; });
							saveBlock('domains', F.renderItems(items), true).then(refreshView).catch(function (e) { toast(e.message, 'err'); });
						});
					});
				});
			}

			function form(values, idx) {
				var typeInfo = DOMAIN_TYPES.filter(function (t) { return t.value === values.type; })[0] || DOMAIN_TYPES[0];
				formModal({
					title: idx >= 0 ? 'Изменить правило' : 'Добавить правило',
					fields: [
						{ name: 'type', label: 'Тип', type: 'select', value: values.type, options: DOMAIN_TYPES.map(function (t) { return { value: t.value, label: t.label }; }) },
						{ name: 'selector', label: 'Селектор', value: values.selector, required: true, placeholder: '/example.com/ или /domain-set:name/' },
						{ name: 'value', label: 'Значение / опции', value: values.value, wide: true, placeholder: typeInfo.needValue }
					],
					onSubmit: function (v) {
						var args = [v.selector];
						if (v.value) args.push.apply(args, v.value.split(/\s+/).filter(Boolean));
						var item = { directive: v.type, args: args, raw: '' };
						if (idx >= 0) items[idx] = item; else items.push(item);
						return saveBlock('domains', F.renderItems(items), true).then(refreshView);
					}
				});
			}
			$('#btn-add').addEventListener('click', function () { form({ type: 'address', selector: '', value: '' }, -1); });
			$('#filter').addEventListener('input', renderTable);
			renderTable();
		});
	};

	// ---------------------------------------------------------------------
	// views: lists
	// ---------------------------------------------------------------------

	var LIST_TYPES = [
		{ value: 'domain-set', label: 'domain-set (файл доменов)', hasName: true, hasFile: true },
		{ value: 'ip-set', label: 'ip-set (файл CIDR)', hasName: true, hasFile: true },
		{ value: 'block-file', label: 'block-file (blocklist)', hasFile: true },
		{ value: 'hosts-file', label: 'hosts-file', hasFile: true },
		{ value: 'bogus-nxdomain', label: 'bogus-nxdomain', hasValue: true },
		{ value: 'ignore-ip', label: 'ignore-ip', hasValue: true },
		{ value: 'whitelist-ip', label: 'whitelist-ip', hasValue: true },
		{ value: 'blacklist-ip', label: 'blacklist-ip', hasValue: true },
		{ value: 'local-domain', label: 'local-domain', hasValue: true },
		{ value: 'ip-alias', label: 'ip-alias', hasValue: true },
		{ value: 'ip-rules', label: 'ip-rules', hasValue: true }
	];

	views.lists = function () {
		setPage('Списки', 'domain-set, ip-set, block-file, hosts-file и файлы', '');
		loading();
		return Promise.all([configLoad(true), api('files.list')]).then(function (r) {
			var cfg = r[0];
			var files = r[1].files || [];
			var items = F.parseLines(cfg.blocks.lists).filter(function (it) {
				return LIST_TYPES.some(function (t) { return t.value === it.directive; });
			});
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'Файлы списков лежат в <span class="mono">' + esc(r[1].dir || '') + '</span> и доступны для редактирования ниже. ' +
				'Путь в конфигурации — абсолютный.</div>';
			html += '<div class="grid cols-2">' +
				'<div class="card"><div class="card-head"><h2>Определения списков</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Тип', render: function (it) { return badge(it.directive, 'info'); } },
					{ title: 'Параметры', render: function (it) { return '<span class="mono small">' + esc(it.args.join(' ')) + '</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], items, 'Списки не заданы') + '</div>' +
				'<div class="card"><div class="card-head"><h2>Файлы</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-new-file">Создать</button></div>' +
				tableHtml([
					{ title: 'Файл', render: function (f) { return '<span class="mono">' + esc(f.name) + '</span>'; } },
					{ title: 'Размер', cls: 'right', render: function (f) { return esc(F.formatBytes(f.size)); } },
					{
						title: '', cls: 'actions', render: function (f) {
							return '<button class="btn btn-sm" data-open="' + esc(f.name) + '">Открыть</button> ' +
								'<button class="btn btn-sm btn-danger" data-rm="' + esc(f.name) + '">Удалить</button>';
						}
					}
				], files, 'Файлов нет') + '</div></div>';
			$('#view').innerHTML = html;

			function persist(next) {
				return saveBlock('lists', F.renderItems(next), true).then(refreshView);
			}
			function addForm(values) {
				formModal({
					title: 'Добавить список',
					fields: [
						{ name: 'type', label: 'Тип', type: 'select', value: values.type, options: LIST_TYPES.map(function (t) { return { value: t.value, label: t.label }; }) },
						{ name: 'name', label: 'Имя (для set)', value: values.name, placeholder: 'my-list' },
						{ name: 'file', label: 'Файл', value: values.file, placeholder: r[1].dir + '/my-list.txt' },
						{ name: 'value', label: 'Значение (для простых списков)', value: values.value, wide: true, placeholder: '0.0.0.0/8 или example.com' }
					],
					onSubmit: function (v) {
						var t = LIST_TYPES.filter(function (x) { return x.value === v.type; })[0];
						var args = [];
						if (t.hasName) { if (!v.name) throw new Error('Укажите имя set'); args.push('-name', v.name); }
						if (t.hasFile) { if (!v.file) throw new Error('Укажите файл'); args.push('-type', 'list', '-file', v.file); }
						if (t.hasValue) { if (!v.value) throw new Error('Укажите значение'); args.push(v.value); }
						items.push({ directive: v.type, args: args, raw: '' });
						return persist(items);
					}
				});
			}
			$('#btn-add').addEventListener('click', function () {
				addForm({ type: 'domain-set', name: '', file: (r[1].dir || '') + '/domains.txt', value: '' });
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-del');
					confirmDialog('Удалить определение?', '<span class="mono">' + esc(raw) + '</span>', 'Удалить').then(function (ok) {
						if (!ok) return;
						items = items.filter(function (i) { return i.raw !== raw; });
						persist(items).catch(function (e) { toast(e.message, 'err'); });
					});
				});
			});

			function openFile(name) {
				api('files.read', { params: { name: name } }).then(function (d) {
					formModal({
						title: 'Файл ' + name,
						fields: [{ name: 'content', label: 'Содержимое', type: 'textarea', value: d.content, wide: true, tall: true }],
						submitLabel: 'Сохранить файл',
						onSubmit: function (v) {
							return api('files.write', { method: 'POST', params: { name: name }, raw: v.content }).then(function () {
								toast('Файл сохранён', 'ok');
								configInvalidate();
							});
						}
					});
				}).catch(function (e) { toast(e.message, 'err'); });
			}
			$$('[data-open]').forEach(function (b) { b.addEventListener('click', function () { openFile(b.getAttribute('data-open')); }); });
			$$('[data-rm]').forEach(function (b) {
				b.addEventListener('click', function () {
					var name = b.getAttribute('data-rm');
					confirmDialog('Удалить файл?', 'Файл <span class="mono">' + esc(name) + '</span> будет удалён. Если он используется в конфигурации, ядро может не запуститься.', 'Удалить')
						.then(function (ok) {
							if (!ok) return;
							api('files.delete', { method: 'POST', params: { name: name } }).then(function () {
								toast('Файл удалён', 'ok');
								refreshView();
							}).catch(function (e) { toast(e.message, 'err'); });
						});
				});
			});
			$('#btn-new-file').addEventListener('click', function () {
				formModal({
					title: 'Создать файл списка',
					fields: [
						{ name: 'name', label: 'Имя файла', required: true, placeholder: 'domains.txt', validate: function (v) { return /^[A-Za-z0-9._-]{1,128}$/.test(v) && v.charAt(0) !== '.' ? '' : 'только A-Za-z0-9._-'; } },
						{ name: 'content', label: 'Содержимое', type: 'textarea', wide: true, tall: true, value: '' }
					],
					onSubmit: function (v) {
						return api('files.write', { method: 'POST', params: { name: v.name }, raw: v.content }).then(function () {
							toast('Файл создан', 'ok');
							refreshView();
						});
					}
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: clients
	// ---------------------------------------------------------------------

	views.clients = function () {
		setPage('Клиенты', 'client-rules: IP, CIDR, MAC и ip-set', '');
		loading();
		return configLoad(true).then(function (cfg) {
			var items = F.parseLines(cfg.blocks.clients);
			var html = '<div class="banner info" style="margin-bottom:14px">' +
				'client-rules применяются к запросам выбранных клиентов: можно отправить клиента в группу или ' +
				'отключить для него правила/кэш. MAC определяется ядром по таблице соседей и работает только в пределах L2-сегмента.</div>';
			html += '<div class="card"><div class="card-head"><h2>Правила клиентов</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Клиент', render: function (it) { return '<span class="mono">' + esc(it.args[0] || '') + '</span>'; } },
					{ title: 'Группа', render: function (it) { return esc(F.valueOf(['x'].concat(it.args), '-group') || F.valueOf(['x'].concat(it.args), '-g') || '—'); } },
					{ title: 'Опции', render: function (it) { var a = it.args.slice(1).filter(function (x) { return x !== '-group' && x !== '-g'; }); return a.length ? '<span class="mono small">' + esc(a.join(' ')) + '</span>' : '<span class="muted">—</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm" data-edit="' + esc(it.raw) + '">Изменить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], items, 'Правил нет') + '</div>';
			$('#view').innerHTML = html;
			var flags = [
				{ v: '-no-cache', l: 'no-cache' }, { v: '-no-speed-check', l: 'no-speed-check' },
				{ v: '-no-rule-addr', l: 'no-rule-addr' }, { v: '-no-rule-nameserver', l: 'no-rule-nameserver' },
				{ v: '-no-rule-ipset', l: 'no-rule-ipset' }, { v: '-no-dualstack-selection', l: 'no-dualstack-selection' },
				{ v: '-no-serve-expired', l: 'no-serve-expired' }, { v: '-no-rules', l: 'no-rules' }
			];
			function form(values, idx) {
				formModal({
					title: idx >= 0 ? 'Изменить правило клиента' : 'Добавить правило клиента',
					fields: [
						{ name: 'match', label: 'Клиент', value: values.match, required: true, placeholder: '192.168.1.10 / 192.168.1.0/24 / aa:bb:cc:dd:ee:ff / ip-set:name', validate: function (v) { return F.isIP(v) || F.isCIDR(v) || F.isMac(v) || /^ip-set:/.test(v) ? '' : 'IP, CIDR, MAC или ip-set:name'; } },
						{ name: 'group', label: 'Группа', value: values.group, placeholder: 'office' },
						{ name: 'flags', label: 'Флаги', type: 'textarea', value: values.flags, wide: true, placeholder: '-no-cache -no-speed-check', hint: 'Через пробел: ' + flags.map(function (f) { return f.l; }).join(', ') }
					],
					onSubmit: function (v) {
						var args = [v.match];
						if (v.group) args.push('-group', v.group);
						if (v.flags) args.push.apply(args, v.flags.split(/\s+/).filter(Boolean));
						var item = { directive: 'client-rules', args: args, raw: '' };
						if (idx >= 0) items[idx] = item; else items.push(item);
						return saveBlock('clients', F.renderItems(items), true).then(refreshView);
					}
				});
			}
			$('#btn-add').addEventListener('click', function () { form({ match: '', group: '', flags: '' }, -1); });
			$$('[data-edit]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-edit');
					var idx = items.map(function (i) { return i.raw; }).indexOf(raw);
					if (idx < 0) return;
					var it = items[idx];
					var group = F.valueOf(['x'].concat(it.args), '-group') || F.valueOf(['x'].concat(it.args), '-g') || '';
					var rest = [];
					for (var i = 1; i < it.args.length; i++) {
						if (it.args[i] === '-group' || it.args[i] === '-g') { i++; continue; }
						rest.push(it.args[i]);
					}
					form({ match: it.args[0] || '', group: group, flags: rest.join(' ') }, idx);
				});
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-del');
					confirmDialog('Удалить правило?', '<span class="mono">' + esc(raw) + '</span>', 'Удалить').then(function (ok) {
						if (!ok) return;
						items = items.filter(function (i) { return i.raw !== raw; });
						saveBlock('clients', F.renderItems(items), true).then(refreshView).catch(function (e) { toast(e.message, 'err'); });
					});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: ipset
	// ---------------------------------------------------------------------

	views.ipset = function () {
		setPage('IPSet / NFTSet', 'Заполнение наборов адресами из DNS-ответов', '');
		loading();
		return Promise.all([configLoad(true), loadStatus()]).then(function (r) {
			var cfg = r[0];
			var s = r[1];
			var nft = s.platform.nft;
			var items = F.parseLines(cfg.blocks.ipset);
			var html = '';
			if (!nft) {
				html += '<div class="banner warn" style="margin-bottom:14px">nftables на этом роутере не обнаружен. ' +
					'<b>NFTSet недоступен</b> — используйте IPSet (пакет ipset). Этот раздел помечен как неподдерживаемый, ' +
					'но правила можно сохранить для другой платформы.</div>';
			}
			if (!s.platform.ipset) {
				html += '<div class="banner warn" style="margin-bottom:14px">Утилита ipset не найдена: ядро сможет писать в ipset только если пакет установлен.</div>';
			}
			html += '<div class="banner info" style="margin-bottom:14px">' +
				'ipset/nftset указывают, в какой набор складывать IP из ответов. Глобальные timeout-настройки — на странице «Настройки». ' +
				'Доменные правила можно задать и через <span class="mono">domain-rules ... -ipset</span>.</div>';
			html += '<div class="card"><div class="card-head"><h2>Правила set</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-add">Добавить</button></div>' +
				tableHtml([
					{ title: 'Тип', render: function (it) { return badge(it.directive, it.directive.indexOf('nft') === 0 ? 'warn' : 'info'); } },
					{ title: 'Селектор', render: function (it) { return '<span class="mono">' + esc(it.args[0] || '') + '</span>'; } },
					{ title: 'Набор', render: function (it) { return '<span class="mono small">' + esc(it.args.slice(1).join(' ')) + '</span>'; } },
					{
						title: '', cls: 'actions', render: function (it) {
							return '<button class="btn btn-sm btn-danger" data-del="' + esc(it.raw) + '">Удалить</button>';
						}
					}
				], items, 'Правил нет') + '</div>';
			$('#view').innerHTML = html;
			function form() {
				formModal({
					title: 'Добавить правило set',
					fields: [
						{ name: 'type', label: 'Тип', type: 'select', value: 'ipset', options: [
							{ value: 'ipset', label: 'ipset' }, { value: 'ipset-no-speed', label: 'ipset-no-speed' },
							{ value: 'nftset', label: (nft ? '' : '[nftables нет] ') + 'nftset' },
							{ value: 'nftset-no-speed', label: (nft ? '' : '[nftables нет] ') + 'nftset-no-speed' }
						] },
						{ name: 'selector', label: 'Селектор', value: '', placeholder: '/example.com/ или domain-set:name', hint: 'Для глобального правила оставьте пустым, если набор задаётся отдельно.' },
						{ name: 'set', label: 'Набор', value: '', required: true, placeholder: 'ipset_name или #4:ip#table#set', wide: true }
					],
					onSubmit: function (v) {
						var args = [];
						if (v.selector) args.push(v.selector);
						args.push(v.set);
						items.push({ directive: v.type, args: args, raw: '' });
						return saveBlock('ipset', F.renderItems(items), true).then(refreshView);
					}
				});
			}
			$('#btn-add').addEventListener('click', form);
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var raw = b.getAttribute('data-del');
					confirmDialog('Удалить правило?', '<span class="mono">' + esc(raw) + '</span>', 'Удалить').then(function (ok) {
						if (!ok) return;
						items = items.filter(function (i) { return i.raw !== raw; });
						saveBlock('ipset', F.renderItems(items), true).then(refreshView).catch(function (e) { toast(e.message, 'err'); });
					});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: cache
	// ---------------------------------------------------------------------

	views.cache = function () {
		setPage('Кэш', 'Параметры, содержимое и сброс', '');
		loading();
		var keys = ['cache-size', 'cache-mem-size', 'cache-persist', 'cache-checkpoint-time', 'cache-file',
			'prefetch-domain', 'serve-expired', 'serve-expired-ttl', 'serve-expired-reply-ttl', 'serve-expired-prefetch-time',
			'dualstack-ip-selection', 'dualstack-ip-selection-threshold'];
		var rows = keys.map(schemaRow).filter(Boolean);
		return Promise.all([configLoad(true), apiSafe('cache.count'), apiSafe('cache.list')]).then(function (r) {
			var cfg = r[0];
			var count = r[1];
			var list = (r[2] && r[2].domains) || [];
			var html = '<div class="grid cols-2">' +
				'<div class="card"><div class="card-head"><h2>Параметры кэша</h2></div>' +
				'<div class="form-grid">' + settingsFieldsHtml(rows) + '</div>' +
				'<div class="row" style="margin-top:14px"><button class="btn btn-primary" id="btn-save">Сохранить</button></div></div>' +
				'<div class="card"><div class="card-head"><h2>Содержимое</h2><div class="spacer"></div>' +
				'<button class="btn btn-danger btn-sm" id="btn-flush">Сбросить кэш</button></div>';
			if (count) {
				html += '<div class="banner info" style="margin-bottom:10px">Счётчик ядра: <span class="mono">' + esc(JSON.stringify(count)) + '</span></div>';
			}
			html += tableHtml([
				{ title: 'Домен', render: function (c) { return '<span class="mono">' + esc(c.domain) + '</span>'; } },
				{ title: 'Тип', render: function (c) { return esc(F.parseQType(c.qtype)); } },
				{ title: 'TTL', cls: 'right', render: function (c) { return esc(c.ttl_remaining); } },
				{ title: 'Закэширован', render: function (c) { return esc(F.formatTime(c.cached_time)); } }
			], list.slice(0, 500), 'Кэш пуст или stats-мост недоступен') + '</div></div>';
			$('#view').innerHTML = html;
			$('#btn-save').addEventListener('click', function () {
				saveSettings(rows).then(function () { toast('Параметры кэша сохранены', 'ok'); refreshView(); }).catch(function (e) { toast(e.message, 'err'); });
			});
			$('#btn-flush').addEventListener('click', function () {
				confirmDialog('Сбросить кэш?', 'Все записи кэша будут удалены через stats-мост ядра. Сервис не перезапускается.', 'Сбросить').then(function (ok) {
					if (!ok) return;
					api('cache.flush', { method: 'POST' }).then(function () {
						toast('Кэш сброшен', 'ok');
						refreshView();
					}).catch(function (e) { toast(e.message, 'err'); });
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: query log
	// ---------------------------------------------------------------------

	views.querylog = function () {
		setPage('Query Log', 'Журнал запросов из stats-моста ядра', '');
		loading();
		var q = state.qlog;
		var html = '<div class="card" style="margin-bottom:14px"><div class="form-grid">' +
			'<div class="field"><label>Домен содержит</label><input class="input" id="q-domain" value="' + esc(q.domain) + '"></div>' +
			'<div class="field"><label>Клиент (IP/MAC)</label><input class="input" id="q-client" value="' + esc(q.client) + '"></div>' +
			'<div class="field"><label>Тип</label><select class="select" id="q-type"><option value="">любой</option>' +
			['1', '28', '65', '5', '16', '12'].map(function (t) { return '<option value="' + t + '"' + (q.domain_type === t ? ' selected' : '') + '>' + F.parseQType(+t) + '</option>'; }).join('') + '</select></div>' +
			'<div class="field"><label>Заблокирован</label><select class="select" id="q-blocked"><option value="">любой</option><option value="true"' + (q.is_blocked === 'true' ? ' selected' : '') + '>да</option><option value="false"' + (q.is_blocked === 'false' ? ' selected' : '') + '>нет</option></select></div>' +
			'<div class="field"><label>Из кэша</label><select class="select" id="q-cached"><option value="">любой</option><option value="true"' + (q.is_cached === 'true' ? ' selected' : '') + '>да</option><option value="false"' + (q.is_cached === 'false' ? ' selected' : '') + '>нет</option></select></div>' +
			'<div class="field"><label>Строк</label><select class="select" id="q-size">' + [25, 50, 100, 200].map(function (n) { return '<option value="' + n + '"' + (+q.page_size === n ? ' selected' : '') + '>' + n + '</option>'; }).join('') + '</select></div>' +
			'<div class="field wide"><div class="row"><button class="btn btn-primary" id="q-apply">Применить</button>' +
			'<button class="btn" id="q-reset">Сбросить фильтры</button>' +
			'<label class="check"><input type="checkbox" id="q-auto"> автообновление 5 с</label></div></div>' +
			'</div></div><div id="q-result"></div>';
		$('#view').innerHTML = html;

		function load() {
			var params = {
				page_num: q.page_num, page_size: q.page_size, domain: q.domain, client: q.client,
				domain_type: q.domain_type, is_blocked: q.is_blocked, is_cached: q.is_cached
			};
			return api('querylog', { params: params }).then(function (d) {
				var list = d.domain_list || [];
				var total = d.total_count || 0;
				var pages = d.total_page || 1;
				var table = tableHtml([
					{ title: 'Время', render: function (r) { return '<span class="nowrap">' + esc(F.formatTimeShort(r.timestamp)) + '</span>'; } },
					{ title: 'Клиент', render: function (r) { return '<span class="mono">' + esc(r.client) + '</span>' + (r.client_mac ? '<div class="muted small mono">' + esc(r.client_mac) + '</div>' : ''); } },
					{ title: 'Домен', render: function (r) { return '<span class="mono">' + esc(r.domain) + '</span>'; } },
					{ title: 'Тип', render: function (r) { return esc(F.parseQType(r.domain_type)); } },
					{ title: 'Группа', render: function (r) { return esc(r.domain_group || '—'); } },
					{ title: 'Результат', render: function (r) { return r.is_blocked ? badge('blocked', 'blocked') : badge(F.parseRCode(r.reply_code), r.reply_code ? 'warn' : 'ok'); } },
					{ title: 'Кэш', render: function (r) { return r.is_cached ? badge('cache', 'cached') : '<span class="muted">—</span>'; } },
					{ title: 'Время', cls: 'right', render: function (r) { return esc(r.query_time) + ' мс'; } }
				], list, 'Записей нет. Проверьте ui-enable и audit-enable.');
				$('#q-result').innerHTML = '<div class="card"><div class="card-head"><h2>Запросы</h2><div class="spacer"></div>' +
					'<span class="muted small">' + esc(total) + ' записей · стр. ' + esc(q.page_num) + ' из ' + esc(pages) + '</span></div>' +
					table + '<div class="row" style="margin-top:12px">' +
					'<button class="btn btn-sm" id="q-prev"' + (q.page_num <= 1 ? ' disabled' : '') + '>← Назад</button>' +
					'<button class="btn btn-sm" id="q-next"' + (q.page_num >= pages ? ' disabled' : '') + '>Вперёд →</button>' +
					'</div></div>';
				$('#q-prev').onclick = function () { if (q.page_num > 1) { q.page_num--; load(); } };
				$('#q-next').onclick = function () { if (q.page_num < pages) { q.page_num++; load(); } };
			}).catch(function (e) {
				$('#q-result').innerHTML = '<div class="banner err">' + esc(e.message) + '</div>';
			});
		}
		function applyFilters() {
			q.domain = $('#q-domain').value; q.client = $('#q-client').value; q.domain_type = $('#q-type').value;
			q.is_blocked = $('#q-blocked').value; q.is_cached = $('#q-cached').value; q.page_size = +$('#q-size').value;
			q.page_num = 1;
			load();
		}
		$('#q-apply').onclick = applyFilters;
		$('#q-domain').addEventListener('keydown', function (e) { if (e.key === 'Enter') applyFilters(); });
		$('#q-reset').onclick = function () {
			q.domain = ''; q.client = ''; q.domain_type = ''; q.is_blocked = ''; q.is_cached = ''; q.page_num = 1;
			$('#q-domain').value = ''; $('#q-client').value = ''; $('#q-type').value = ''; $('#q-blocked').value = ''; $('#q-cached').value = '';
			load();
		};
		$('#q-auto').addEventListener('change', function (e) {
			if (state.timer) { clearInterval(state.timer); state.timer = null; }
			if (e.target.checked) state.timer = setInterval(load, 5000);
		});
		load();
	};

	// ---------------------------------------------------------------------
	// views: settings
	// ---------------------------------------------------------------------

	var CATEGORIES = [
		{ id: 'general', label: 'Общие' }, { id: 'cache', label: 'Кэш' }, { id: 'log', label: 'Логи' },
		{ id: 'audit', label: 'Журнал' }, { id: 'ttl', label: 'TTL и ответы' }, { id: 'selection', label: 'Выбор адреса' },
		{ id: 'security', label: 'Безопасность' }, { id: 'ui', label: 'Stats-мост' }, { id: 'debug', label: 'Диагностика' }
	];

	views.settings = function () {
		setPage('Настройки', 'Глобальные параметры ядра (блок fsd:globals)', '');
		loading();
		return configLoad(true).then(function () {
			var html = '<div class="card">' +
				'<div class="tabs" id="settings-tabs">' + CATEGORIES.map(function (c, i) {
					var count = state.schema.filter(function (r) { return r.category === c.id; }).length;
					if (!count) return '';
					return '<button type="button" data-cat="' + c.id + '"' + (i === 0 ? ' class="active"' : '') + '>' + esc(c.label) + ' <span class="muted small">' + count + '</span></button>';
				}).join('') + '</div>' + CATEGORIES.map(function (c) {
					var rows = state.schema.filter(function (r) { return r.category === c.id; });
					if (!rows.length) return '';
					return '<section data-panel="' + c.id + '" style="display:none">' +
						(c.id === 'ui' ? '<div class="banner warn" style="margin-bottom:12px">Менять <span class="mono">ui-listen</span> вручную опасно: панель теряет доступ к статистике. Оставьте loopback-адрес и порт, выданный установщиком.</div>' : '') +
						'<div class="form-grid">' + settingsFieldsHtml(rows) + '</div></section>';
				}).join('') +
				'<div class="row" style="margin-top:16px"><button class="btn btn-primary" id="btn-save">Сохранить настройки</button>' +
				'<span class="muted small">Значения по умолчанию не записываются в файл.</span></div></div>' +
				'<div class="card" style="margin-top:14px"><div class="card-head"><h2>Ещё параметры</h2></div>' +
				'<p class="muted">Директивы, которых нет в форме (bind-cert-*, force-qtype-SOA, client-subnet, plugin и т. п.), доступны в полном редакторе конфигурации.</p>' +
				'<a class="btn" href="#/config">Открыть конфигурацию</a></div>';
			$('#view').innerHTML = html;
			var tabs = $$('#settings-tabs button');
			var first = tabs[0];
			function show(cat) {
				tabs.forEach(function (t) { t.classList.toggle('active', t.getAttribute('data-cat') === cat); });
				$$('[data-panel]').forEach(function (p) { p.style.display = p.getAttribute('data-panel') === cat ? '' : 'none'; });
			}
			tabs.forEach(function (t) { t.addEventListener('click', function () { show(t.getAttribute('data-cat')); }); });
			if (first) show(first.getAttribute('data-cat'));
			$('#btn-save').addEventListener('click', function () {
				saveSettings(state.schema).then(function () {
					toast('Настройки сохранены', 'ok');
					refreshView();
				}).catch(function (e) { toast(e.message, 'err', 6000); });
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: service
	// ---------------------------------------------------------------------

	views.service = function () {
		setPage('Служба', 'Управление, логи и диагностика', '');
		loading();
		return Promise.all([loadStatus(true), apiSafe('diag'), api('logs.tail', { params: { name: 'core', lines: 120 } })]).then(function (r) {
			var s = r[0];
			var diag = (r[1] && r[1].checks) || [];
			var log = r[2] || { text: '' };
			var html = '<div class="grid cols-2">' +
				'<div class="card"><div class="card-head"><h2>Состояние</h2></div>' +
				'<dl class="kv">' +
				'<dt>Ядро</dt><dd>' + (s.service.running ? badge('работает', 'ok') : badge('остановлено', 'err')) + ' · PID ' + esc(s.service.pid || '—') + '</dd>' +
				'<dt>Uptime</dt><dd>' + esc(F.formatUptime(s.service.uptime)) + '</dd>' +
				'<dt>Веб-сервер</dt><dd>' + (s.service.web_running ? badge('работает', 'ok') : badge('остановлен', 'err')) + ' · ' + esc(s.instance.web_server) + '</dd>' +
				'<dt>Автозапуск</dt><dd>' + (s.service.enabled ? badge('включён', 'ok') : badge('выключен', 'warn')) + '</dd>' +
				'<dt>Ядро</dt><dd>' + esc(s.service.core_version || '—') + '</dd>' +
				'<dt>DNS</dt><dd class="mono">' + esc(s.instance.dns.bind) + ':' + esc(s.instance.dns.port) + '</dd>' +
				'<dt>Панель</dt><dd class="mono">' + esc(s.instance.ui.bind) + ':' + esc(s.instance.ui.port) + '</dd>' +
				'<dt>Stats-мост</dt><dd>' + (s.bridge === 'up' ? badge('доступен', 'ok') : badge('недоступен', 'warn')) + '</dd>' +
				'</dl>' +
				'<div class="row" style="margin-top:16px">' +
				'<button class="btn btn-primary" data-svc="start">Запустить</button>' +
				'<button class="btn" data-svc="restart">Перезапустить</button>' +
				'<button class="btn btn-danger" data-svc="stop">Остановить</button>' +
				'</div><div class="row" style="margin-top:8px">' +
				'<button class="btn btn-sm" data-svc="enable">Включить автозапуск</button>' +
				'<button class="btn btn-sm" data-svc="disable">Выключить автозапуск</button>' +
				'</div></div>' +
				'<div class="card"><div class="card-head"><h2>Диагностика</h2><div class="spacer"></div><button class="btn btn-sm" id="diag-refresh">Проверить</button></div>' +
				tableHtml([
					{ title: 'Проверка', render: function (c) { return '<span class="mono">' + esc(c.id) + '</span>'; } },
					{ title: 'Состояние', render: function (c) { return badge(c.state, c.state === 'ok' ? 'ok' : (c.state === 'error' ? 'err' : 'warn')); } },
					{ title: 'Детали', render: function (c) { return '<span class="small">' + esc(c.detail) + '</span>'; } }
				], diag, 'Диагностика недоступна') + '</div></div>';

			html += '<div class="card" style="margin-top:14px"><div class="card-head"><h2>Логи</h2><div class="spacer"></div>' +
				'<select class="select" id="log-name" style="width:auto"><option value="core">ядро</option><option value="audit">query audit</option><option value="web">web / init</option></select> ' +
				'<button class="btn btn-sm" id="log-refresh">Обновить</button></div>' +
				'<pre class="pre" id="log-pre">' + esc(log.text || '') + '</pre></div>';
			$('#view').innerHTML = html;
			$$('[data-svc]').forEach(function (b) {
				b.addEventListener('click', function () {
					var act = b.getAttribute('data-svc');
					var danger = act === 'stop' || act === 'restart';
					var run = function () { serviceAction(act).catch(function (e) { toast(e.message, 'err'); }); };
					if (danger) confirmDialog('Подтверждение', 'Выполнить <b>' + esc(act) + '</b>?', 'Выполнить').then(function (ok) { if (ok) run(); });
					else run();
				});
			});
			$('#log-refresh').addEventListener('click', function () {
				api('logs.tail', { params: { name: $('#log-name').value, lines: 200 } }).then(function (d) {
					$('#log-pre').textContent = d.text || '';
				}).catch(function (e) { toast(e.message, 'err'); });
			});
			$('#diag-refresh').addEventListener('click', refreshView);
		});
	};

	// ---------------------------------------------------------------------
	// views: backups
	// ---------------------------------------------------------------------

	views.backups = function () {
		setPage('Резервные копии', 'Конфигурация и списки; автоматические копии перед изменениями', '');
		loading();
		return api('config.backups').then(function (d) {
			var list = d.backups || [];
			var html = '<div class="card"><div class="card-head"><h2>Архивы</h2><div class="spacer"></div>' +
				'<button class="btn btn-primary btn-sm" id="btn-create">Создать копию</button> ' +
				'<label class="btn btn-sm" style="cursor:pointer">Восстановить из файла<input type="file" id="upload" accept=".tgz,.tar.gz,application/gzip" style="display:none"></label></div>' +
				tableHtml([
					{ title: 'Архив', render: function (b) { return '<span class="mono">' + esc(b.name) + '</span>'; } },
					{ title: 'Причина', render: function (b) { return esc(b.reason || '—'); } },
					{ title: 'Размер', cls: 'right', render: function (b) { return esc(F.formatBytes(b.size)); } },
					{ title: 'Создан', render: function (b) { return esc(F.formatTime((b.mtime || 0) * 1000)); } },
					{
						title: '', cls: 'actions', render: function (b) {
							return '<a class="btn btn-sm" href="cgi-bin/api.cgi?action=config.download&name=' + encodeURIComponent(b.name) + '">Скачать</a> ' +
								'<button class="btn btn-sm" data-restore="' + esc(b.name) + '">Восстановить</button> ' +
								'<button class="btn btn-sm btn-danger" data-del="' + esc(b.name) + '">Удалить</button>';
						}
					}
				], list, 'Копий пока нет') + '</div>';
			$('#view').innerHTML = html;
			$('#btn-create').addEventListener('click', function () {
				api('config.backup', { method: 'POST' }).then(function (d) {
					toast('Создано: ' + d.name, 'ok');
					refreshView();
				}).catch(function (e) { toast(e.message, 'err'); });
			});
			$('#upload').addEventListener('change', function (ev) {
				var f = ev.target.files[0];
				if (!f) return;
				confirmDialog('Восстановить из файла?', 'Архив <span class="mono">' + esc(f.name) + '</span> будет проверен, текущая конфигурация сохранена как pre-restore, затем применена.', 'Восстановить')
					.then(function (ok) {
						if (!ok) return;
						f.arrayBuffer().then(function (buf) {
							return api('config.upload', { method: 'POST', params: { name: f.name }, blob: buf });
						}).then(function () {
							toast('Конфигурация восстановлена', 'ok');
							refreshView();
						}).catch(function (e) { toast(e.message, 'err', 7000); });
					});
			});
			$$('[data-restore]').forEach(function (b) {
				b.addEventListener('click', function () {
					var name = b.getAttribute('data-restore');
					confirmDialog('Восстановить?', 'Архив <span class="mono">' + esc(name) + '</span> будет применён. Текущая конфигурация сохранится как pre-restore.', 'Восстановить')
						.then(function (ok) {
							if (!ok) return;
							api('config.restore', { method: 'POST', form: { name: name } }).then(function () {
								toast('Восстановлено', 'ok');
								refreshView();
							}).catch(function (e) { toast(e.message, 'err', 7000); });
						});
				});
			});
			$$('[data-del]').forEach(function (b) {
				b.addEventListener('click', function () {
					var name = b.getAttribute('data-del');
					confirmDialog('Удалить архив?', esc(name), 'Удалить').then(function (ok) {
						if (!ok) return;
						api('config.delete-backup', { method: 'POST', form: { name: name } }).then(refreshView).catch(function (e) { toast(e.message, 'err'); });
					});
				});
			});
		});
	};

	// ---------------------------------------------------------------------
	// views: config
	// ---------------------------------------------------------------------

	views.config = function () {
		setPage('Конфигурация', 'Полный редактор, проверка и применение', '');
		loading();
		return configLoad(true).then(function (cfg) {
			var html = '<div class="card"><div class="card-head"><h2>Файл конфигурации</h2><div class="spacer"></div>' +
				'<span class="muted small mono">' + esc(cfg.path) + '</span></div>' +
				'<div class="banner info" style="margin-bottom:12px">Перед применением создаётся резервная копия. ' +
				'Сначала выполняется статическая проверка, затем пробный запуск ядра на копии конфигурации; при ошибке изменения не применяются. ' +
				'При неудачном перезапуске выполняется откат.</div>' +
				'<textarea class="textarea tall" id="raw">' + esc(cfg.raw) + '</textarea>' +
				'<div class="row" style="margin-top:12px">' +
				'<button class="btn btn-primary" id="btn-apply">Проверить и применить</button>' +
				'<button class="btn" id="btn-validate">Только проверить</button>' +
				'<button class="btn" id="btn-reload">Вернуть из файла</button>' +
				'<button class="btn" id="btn-backup">Создать бэкап</button>' +
				'<span class="muted small">строк: ' + esc(cfg.lines) + ' · sha256: <span class="mono">' + esc((cfg.sha256 || '').slice(0, 12)) + '</span></span></div>' +
				'<div id="validation" style="margin-top:12px"></div></div>';
			$('#view').innerHTML = html;
			function showValidation(d) {
				var html = '<div class="card"><div class="card-head"><h2>Результат проверки</h2><div class="spacer"></div>' +
					(d.valid ? badge('валидна', 'ok') : badge('есть ошибки', 'err')) + '</div>';
				if (d.runtime) {
					html += '<div class="banner ' + (d.runtime.requested ? (d.runtime.ok ? 'info' : 'err') : 'info') + '" style="margin-bottom:10px">' +
						'Пробный запуск ядра: ' + (d.runtime.requested ? (d.runtime.ok ? 'успешно' : 'ошибка') : 'не запрашивался') + '</div>';
				}
				if (d.errors && d.errors.length) {
					html += '<h3>Ошибки</h3><div class="stack">' + d.errors.map(function (e) {
						return '<div class="banner err">строка ' + esc(e.line) + ': ' + esc(e.message) + '</div>';
					}).join('') + '</div>';
				}
				if (d.warnings && d.warnings.length) {
					html += '<h3 style="margin-top:12px">Предупреждения</h3><div class="stack">' + d.warnings.slice(0, 50).map(function (e) {
						return '<div class="banner warn">строка ' + esc(e.line) + ': ' + esc(e.message) + '</div>';
					}).join('') + '</div>';
				}
				if (d.runtime && d.runtime.log) {
					html += '<h3 style="margin-top:12px">Лог пробного запуска</h3><pre class="pre">' + esc(d.runtime.log) + '</pre>';
				}
				html += '</div>';
				$('#validation').innerHTML = html;
			}
			function validate(apply) {
				var raw = $('#raw').value;
				api('config.validate', { method: 'POST', params: { runtime: 1 }, raw: raw }).then(function (d) {
					if (!apply) { showValidation(d); return; }
					if (!d.valid) { showValidation(d); toast('Конфигурация не применена: есть ошибки', 'err'); return; }
					confirmDialog('Применить конфигурацию?', 'Служба будет перезапущена. Будет создана резервная копия; при неудаче — откат.', 'Применить')
						.then(function (ok) {
							if (!ok) return;
							api('config.apply', { method: 'POST', raw: raw }).then(function (r) {
								toast('Применено' + (r.backup ? ' (бэкап: ' + r.backup + ')' : ''), 'ok');
								configInvalidate();
								state.status = null;
								refreshView();
							}).catch(function (e) { toast(e.message, 'err', 7000); showValidation({ valid: false, errors: [{ line: 0, message: e.message }], warnings: [], runtime: null }); });
						});
				}).catch(function (e) { toast(e.message, 'err'); });
			}
			$('#btn-validate').onclick = function () { validate(false); };
			$('#btn-apply').onclick = function () { validate(true); };
			$('#btn-reload').onclick = function () { configInvalidate(); refreshView(); };
			$('#btn-backup').onclick = function () {
				api('config.backup', { method: 'POST' }).then(function (d) { toast('Бэкап: ' + d.name, 'ok'); }).catch(function (e) { toast(e.message, 'err'); });
			};
		});
	};

	// ---------------------------------------------------------------------
	// views: about
	// ---------------------------------------------------------------------

	views.about = function () {
		setPage('О системе', 'Версии, возможности и ограничения', '');
		loading();
		return Promise.all([loadStatus(), api('capabilities'), api('about')]).then(function (r) {
			var s = r[0];
			var caps = r[1];
			var about = r[2];
			var stateBadge = function (st) {
				if (st === 'supported') return badge('поддерживается', 'ok');
				if (st === 'partial') return badge('частично', 'warn');
				return badge('не поддерживается', 'err');
			};
			var html = '<div class="banner warn" style="margin-bottom:14px"><b>PRE-RELEASE.</b> Проект проверен в эмуляции Entware/BusyBox и не проходил приёмочные испытания на всех моделях Keenetic. ' +
				'Перед рабочим использованием сделайте резервную копию конфигурации роутера.</div>' +
				'<div class="grid cols-2">' +
				'<div class="card"><div class="card-head"><h2>Версии</h2></div><dl class="kv">' +
				'<dt>WebUI</dt><dd>' + esc(about.ui_version) + '</dd>' +
				'<dt>API</dt><dd>' + esc(about.api_version) + '</dd>' +
				'<dt>Ядро</dt><dd>' + esc(about.core_version || '—') + ' (' + esc(about.core_kind) + ')</dd>' +
				'<dt>Архитектура</dt><dd>' + esc(s.platform.arch) + ' · ' + esc(s.platform.kernel) + '</dd>' +
				'<dt>Stats-мост</dt><dd>' + (s.bridge === 'up' ? badge('доступен', 'ok') : badge('недоступен', 'warn')) + '</dd>' +
				'<dt>nftables</dt><dd>' + (s.platform.nft ? 'есть' : 'нет') + '</dd>' +
				'<dt>ipset</dt><dd>' + (s.platform.ipset ? 'есть' : 'нет') + '</dd>' +
				'<dt>Лицензия</dt><dd>' + esc(about.license) + '</dd>' +
				'</dl><p class="muted small" style="margin-top:12px">Исходники: <a href="' + esc(about.source) + '" rel="noreferrer" target="_blank">' + esc(about.source) + '</a></p></div>' +
				'<div class="card"><div class="card-head"><h2>Пути</h2></div><dl class="kv">' +
				'<dt>Конфиг</dt><dd class="mono">' + esc(s.instance.core_binary) + '</dd>' +
				'<dt>ETC</dt><dd class="mono">' + esc(s.paths.etc) + '</dd>' +
				'<dt>VAR</dt><dd class="mono">' + esc(s.paths.var) + '</dd>' +
				'<dt>LOG</dt><dd class="mono">' + esc(s.paths.log) + '</dd>' +
				'<dt>RUN</dt><dd class="mono">' + esc(s.paths.run) + '</dd>' +
				'<dt>WWW</dt><dd class="mono">' + esc(s.paths.www) + '</dd>' +
				'</dl><p class="muted small" style="margin-top:12px">Экземпляр полностью изолирован от штатного hrdns.</p></div>' +
				'</div><div class="card" style="margin-top:14px"><div class="card-head"><h2>Матрица возможностей</h2></div>' +
				tableHtml([
					{ title: 'Возможность', render: function (f) { return '<span class="mono">' + esc(f.id) + '</span>'; } },
					{ title: 'Состояние', render: function (f) { return stateBadge(f.state); } },
					{ title: 'Комментарий', render: function (f) { return '<span class="small">' + esc(f.reason || '—') + '</span>'; } }
				], caps.features || [], 'Нет данных') + '</div>';
			$('#view').innerHTML = html;
		});
	};

	// ---------------------------------------------------------------------
	// start
	// ---------------------------------------------------------------------

	function init() {
		var schemaPromise = fetch('schema.tsv', { cache: 'no-store' }).then(function (r) { return r.text(); }).then(function (t) {
			state.schema = F.parseSchema(t);
			state.schemaByKey = {};
			state.schema.forEach(function (row) { state.schemaByKey[row.key] = row; });
		}).catch(function () { state.schema = []; });

		window.addEventListener('hashchange', function () {
			if (!state.session) return;
			route();
		});

		schemaPromise.then(function () {
			api('session').then(function (s) {
				state.session = s;
				if (!s.authenticated) {
					showLogin('');
					return;
				}
				state.csrf = s.csrf || '';
				$('#login').classList.add('hidden');
				boot().catch(function (e) { errorView(e); });
			}).catch(function () { showLogin(''); });
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
