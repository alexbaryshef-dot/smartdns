/*
 * forksmartdns WebUI — pure helpers (no DOM).
 * Also loadable from Node for unit tests: module.exports = FSD.
 */
(function (root, factory) {
	if (typeof module === 'object' && module.exports) {
		module.exports = factory();
	} else {
		root.FSD = factory();
	}
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	function escapeHtml(value) {
		return String(value == null ? '' : value)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function tokenize(line) {
		var out = [];
		var m = String(line).match(/[^\s]+/g);
		return m || [];
	}

	function parseSchema(text) {
		var rows = [];
		String(text || '').split(/\r?\n/).forEach(function (line) {
			if (!line || line.charAt(0) === '#') return;
			var f = line.split('\t');
			if (f.length < 6) return;
			rows.push({
				key: f[0],
				type: f[1],
				min: f[2],
				max: f[3],
				enumValues: f[4] && f[4] !== '-' ? f[4].split('|') : [],
				category: f[5],
				label: f[6] || f[0],
				defaultValue: f[7] || '',
				hint: f[8] || ''
			});
		});
		return rows;
	}

	function parseLines(block) {
		var items = [];
		String(block || '').split(/\r?\n/).forEach(function (line) {
			var t = line.replace(/^\s+|\s+$/g, '');
			if (!t || t.charAt(0) === '#') return;
			var parts = tokenize(t);
			items.push({ directive: parts[0], args: parts.slice(1), raw: t });
		});
		return items;
	}

	function renderItems(items) {
		return items.map(function (it) {
			return it.args && it.args.length ? it.directive + ' ' + it.args.join(' ') : it.directive;
		}).join('\n') + (items.length ? '\n' : '');
	}

	function parseGlobals(block) {
		var map = {};
		var order = [];
		String(block || '').split(/\r?\n/).forEach(function (line) {
			var t = line.replace(/^\s+|\s+$/g, '');
			if (!t || t.charAt(0) === '#') return;
			var m = t.match(/^([^\s]+)\s*(.*)$/);
			if (!m) return;
			if (!Object.prototype.hasOwnProperty.call(map, m[1])) order.push(m[1]);
			map[m[1]] = m[2];
		});
		return { map: map, order: order };
	}

	function renderGlobals(originalBlock, schema, values) {
		var known = {};
		schema.forEach(function (row) { known[row.key] = true; });
		var original = parseGlobals(originalBlock);
		var lines = [];
		schema.forEach(function (row) {
			if (Object.prototype.hasOwnProperty.call(values, row.key)) {
				var v = values[row.key];
				if (v === '' || v == null) return;
				lines.push(row.key + ' ' + v);
			}
		});
		original.order.forEach(function (key) {
			if (known[key]) return;
			lines.push(key + (original.map[key] !== '' ? ' ' + original.map[key] : ''));
		});
		return lines.join('\n') + (lines.length ? '\n' : '');
	}

	function parseGroups(block) {
		var groups = [];
		var orphan = [];
		var current = null;
		parseLines(block).forEach(function (item) {
			if (item.directive === 'group-begin') {
				current = { name: item.args[0] || '', options: item.args.slice(1), lines: [] };
				groups.push(current);
				return;
			}
			if (item.directive === 'group-end') {
				current = null;
				return;
			}
			if (current) current.lines.push(item.raw);
			else orphan.push(item.raw);
		});
		return { groups: groups, orphan: orphan };
	}

	function renderGroups(groups) {
		var lines = [];
		groups.forEach(function (g) {
			var name = String(g.name || '').replace(/[^A-Za-z0-9_-]/g, '');
			if (!name) return;
			lines.push('group-begin ' + name + (g.options && g.options.length ? ' ' + g.options.join(' ') : ''));
			(g.lines || []).forEach(function (l) {
				var t = l.replace(/^\s+|\s+$/g, '');
				if (t) lines.push(t);
			});
			lines.push('group-end');
		});
		return lines.join('\n') + (lines.length ? '\n' : '');
	}

	function looksLikeIPv4(s) {
		var p = String(s).split('.');
		if (p.length !== 4) return false;
		return p.every(function (x) { return /^[0-9]+$/.test(x) && +x >= 0 && +x <= 255; });
	}

	function isIPv6(s) {
		return /^[0-9A-Fa-f:]+$/.test(s) && s.indexOf(':') >= 0;
	}

	function isIP(s) { return looksLikeIPv4(s) || isIPv6(s); }

	function isCIDR(s) {
		var p = String(s).split('/');
		if (p.length === 1) return isIP(p[0]);
		if (p.length !== 2) return false;
		if (!isIP(p[0]) || !/^[0-9]+$/.test(p[1])) return false;
		var max = isIPv6(p[0]) ? 128 : 32;
		return +p[1] <= max;
	}

	function isDomain(s) {
		if (!s || s.length > 253) return false;
		var t = s.replace(/^\*\./, '').replace(/\.$/, '');
		return /^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*$/.test(t);
	}

	function isMac(s) {
		return /^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/.test(s);
	}

	function validateValue(row, value) {
		var v = String(value == null ? '' : value).replace(/^\s+|\s+$/g, '');
		if (v === '') return 'значение не задано';
		var t = row.type;
		if (t === 'yesno') return (v === 'yes' || v === 'no') ? '' : 'ожидается yes или no';
		if (t === 'int') {
			if (!/^-?[0-9]+$/.test(v)) return 'ожидается целое число';
			var min = row.min !== '-' ? parseInt(row.min, 10) : null;
			var max = row.max !== '-' ? parseInt(row.max, 10) : null;
			if (min !== null && +v < min) return 'минимум ' + min;
			if (max !== null && max > 0 && +v > max) return 'максимум ' + max;
			return '';
		}
		if (t === 'size') return /^[0-9]+[kKmMgG]?$/.test(v) ? '' : 'например 4096 или 128k';
		if (t === 'enum' || t === 'loglevel' || t === 'response') {
			return row.enumValues.indexOf(v) >= 0 ? '' : 'допустимо: ' + row.enumValues.join(', ');
		}
		if (t === 'speed') {
			var ok = v.split(',').every(function (m) {
				return m === 'none' || m === 'ping' || /^tcp(-syn)?:[0-9]+$/.test(m);
			});
			return ok ? '' : 'например ping,tcp:443';
		}
		if (t === 'ipcidr') return isCIDR(v) ? '' : 'ожидается IP или CIDR';
		if (t === 'ip') return isIP(v) ? '' : 'ожидается IP';
		if (t === 'path') return v.charAt(0) === '/' ? '' : 'путь должен быть абсолютным';
		if (t === 'domain') return isDomain(v) ? '' : 'некорректный домен';
		return '';
	}

	function formatUptime(sec) {
		sec = Math.max(0, parseInt(sec || 0, 10) || 0);
		var d = Math.floor(sec / 86400);
		var h = Math.floor((sec % 86400) / 3600);
		var m = Math.floor((sec % 3600) / 60);
		var s = sec % 60;
		if (d > 0) return d + ' д ' + h + ' ч ' + m + ' мин';
		if (h > 0) return h + ' ч ' + m + ' мин';
		if (m > 0) return m + ' мин ' + s + ' с';
		return s + ' с';
	}

	function formatBytes(n) {
		n = Number(n) || 0;
		if (n < 1024) return n + ' Б';
		if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' КиБ';
		if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' МиБ';
		return (n / (1024 * 1024 * 1024)).toFixed(2) + ' ГиБ';
	}

	function formatTime(ms) {
		var n = Number(ms) || 0;
		if (!n) return '—';
		var d = new Date(n);
		if (isNaN(d.getTime())) return '—';
		return d.toLocaleString('ru-RU', { hour12: false });
	}

	function formatTimeShort(ms) {
		var n = Number(ms) || 0;
		if (!n) return '—';
		var d = new Date(n);
		if (isNaN(d.getTime())) return '—';
		return d.toLocaleTimeString('ru-RU', { hour12: false });
	}

	function parseQType(t) {
		var names = {
			1: 'A', 2: 'NS', 5: 'CNAME', 6: 'SOA', 12: 'PTR', 15: 'MX', 16: 'TXT',
			28: 'AAAA', 33: 'SRV', 35: 'NAPTR', 43: 'DS', 46: 'RRSIG', 48: 'DNSKEY',
			64: 'SVCB', 65: 'HTTPS', 255: 'ANY'
		};
		return names[t] || ('TYPE' + t);
	}

	function parseRCode(c) {
		return ({ 0: 'NOERROR', 1: 'FORMERR', 2: 'SERVFAIL', 3: 'NXDOMAIN', 4: 'NOTIMP', 5: 'REFUSED' })[c] || ('RCODE' + c);
	}

	function encodeParams(obj) {
		var parts = [];
		Object.keys(obj || {}).forEach(function (k) {
			if (obj[k] === undefined || obj[k] === null || obj[k] === '') return;
			parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]));
		});
		return parts.join('&');
	}

	function quoteArg(v) {
		var s = String(v == null ? '' : v);
		return /\s/.test(s) ? '"' + s.replace(/"/g, '') + '"' : s;
	}

	function groupMatches(block) {
		var parsed = parseGroups(block);
		parsed.groups.forEach(function (g) {
			g.matches = [];
			g.extra = [];
			g.lines.forEach(function (raw) {
				var parts = tokenize(raw);
				if (parts[0] === 'group-match') {
					g.matches.push({ raw: raw, domain: valueOf(parts, '-domain'), client: valueOf(parts, '-client-ip'), group: valueOf(parts, '-g') || valueOf(parts, '-group') });
				} else {
					g.extra.push(raw);
				}
			});
		});
		return parsed;
	}

	function valueOf(parts, name) {
		for (var i = 0; i < parts.length; i++) {
			if (parts[i] === name && i + 1 < parts.length) return parts[i + 1];
		}
		return '';
	}

	function renderGroupsForm(groups) {
		return renderGroups(groups.map(function (g) {
			var lines = [];
			(g.matches || []).forEach(function (m) {
				var line = 'group-match';
				if (m.domain) line += ' -domain ' + m.domain;
				if (m.client) line += ' -client-ip ' + m.client;
				if (m.group) line += ' -g ' + m.group;
				lines.push(line);
			});
			(g.extra || []).forEach(function (l) { if (l) lines.push(l); });
			return { name: g.name, options: g.options || [], lines: lines };
		}));
	}

	return {
		escapeHtml: escapeHtml,
		tokenize: tokenize,
		parseSchema: parseSchema,
		parseLines: parseLines,
		renderItems: renderItems,
		parseGlobals: parseGlobals,
		renderGlobals: renderGlobals,
		parseGroups: parseGroups,
		renderGroups: renderGroups,
		groupMatches: groupMatches,
		renderGroupsForm: renderGroupsForm,
		validateValue: validateValue,
		isIP: isIP,
		isCIDR: isCIDR,
		isDomain: isDomain,
		isMac: isMac,
		formatUptime: formatUptime,
		formatBytes: formatBytes,
		formatTime: formatTime,
		formatTimeShort: formatTimeShort,
		parseQType: parseQType,
		parseRCode: parseRCode,
		encodeParams: encodeParams,
		quoteArg: quoteArg,
		valueOf: valueOf
	};
});
