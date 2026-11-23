# forksmartdns WebUI — static configuration validator (BusyBox awk).
#
# Usage:
#   awk -v DIR=/opt/share/forksmartdns/etc -f validate.awk CONFIG
#
# Output records (tab separated):
#   E<TAB>line<TAB>message
#   W<TAB>line<TAB>message
#
# This is a syntax/structure check. The authoritative check is a short
# foreground start of the real resolver on a scratch config (see config.sh).

function fail(ln, msg) {
	printf "E\t%d\t%s\n", ln, msg
	errors++
}

function note(ln, msg) {
	printf "W\t%d\t%s\n", ln, msg
	warnings++
}

function is_int(s) {
	return s ~ /^-?[0-9]+$/
}

function is_uint(s) {
	return s ~ /^[0-9]+$/
}

function is_size(s) {
	if (s ~ /^[0-9]+[kKmMgG]?$/) return 1
	if (s ~ /^[0-9]+[kKmMgG][bB]?$/) return 1
	return 0
}

function is_yesno(s) {
	return s == "yes" || s == "no"
}

function ipv4(s, a, i) {
	if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
	split(s, a, ".")
	for (i = 1; i <= 4; i++) {
		if (a[i] + 0 > 255) return 0
	}
	return 1
}

function ipv6(s) {
	return s ~ /^[0-9A-Fa-f:]+$/ && s ~ /:/
}

function ipaddr(s) {
	return ipv4(s) || ipv6(s)
}

function ipcidr(s, p, mask) {
	if (index(s, "/") == 0) return ipaddr(s)
	split(s, p, "/")
	if (length(p) != 2) return 0
	if (!ipaddr(p[1])) return 0
	if (!is_uint(p[2])) return 0
	mask = p[2] + 0
	if (index(p[1], ":") > 0) return mask <= 128
	return mask <= 32
}

function domain_ok(s) {
	if (s == "" || length(s) > 253) return 0
	if (s ~ /^\*/) s = substr(s, 2)
	if (s == "") return 0
	if (s ~ /\.$/) s = substr(s, 1, length(s) - 1)
	if (s ~ /^\*\./) s = substr(s, 3)
	return s ~ /^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*$/
}

function domain_selector(s) {
	# /domain/, /domain-set:name/, domain-set:name
	if (s == "") return 0
	if (substr(s, 1, 1) == "/") {
		if (substr(s, length(s), 1) != "/") return 0
		s = substr(s, 2, length(s) - 2)
	}
	if (substr(s, 1, 11) == "domain-set:") return domain_ok(substr(s, 12))
	return domain_ok(s)
}

function mac_ok(s) {
	return s ~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/ || \
	       s ~ /^[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]$/
}

function endpoint(s) {
	# [IPv6]:port[@dev] | :port[@dev] | IPv4[:port][@dev] | host[:port][@dev]
	if (s ~ /^\[[0-9A-Fa-f:]+\](:[0-9]+)?(@[^ ]+)?$/) return 1
	if (s ~ /^:[0-9]+(@[^ ]+)?$/) return 1
	if (s ~ /^[0-9.]+(:[0-9]+)?(@[^ ]+)?$/) return 1
	if (s ~ /^[A-Za-z0-9_.-]+(:[0-9]+)?(@[^ ]+)?$/) return 1
	return 0
}

function server_url(s) {
	if (s ~ /^https?:\/\/[^ \/]+/) return 1
	if (s ~ /^h3:\/\/[^ \/]+/) return 1
	if (s ~ /^http3:\/\/[^ \/]+/) return 1
	if (s ~ /^quic:\/\/[^ \/]+/) return 1
	if (s ~ /^tls:\/\/[^ \/]+/) return 1
	if (s ~ /^tcp:\/\/[^ \/]+/) return 1
	if (s ~ /^udp:\/\/[^ \/]+/) return 1
	return 0
}

function check_options(ln, from, known, needs, label,    i, opt, name) {
	for (i = from; i <= NF; i++) {
		opt = $i
		if (substr(opt, 1, 1) != "-") {
			note(ln, label ": неожиданный аргумент без опции: " opt)
			continue
		}
		name = substr(opt, 2)
		if (substr(name, 1, 1) == "-") name = substr(name, 2)
		if (!(name in known)) {
			note(ln, label ": неизвестная опция " opt " (ядро проигнорирует её)")
			continue
		}
		if (name in needs) {
			if (i + 1 > NF || substr($(i + 1), 1, 1) == "-") {
				fail(ln, label ": опция " opt " требует значения")
			} else {
				i++
			}
		}
	}
}

BEGIN {
	dir = ENVIRON["FSD_SCHEMA_DIR"]
	if (dir == "") dir = "."
	while ((getline line < (dir "/directives.txt")) > 0) {
		gsub(/\r/, "", line)
		sub(/#.*/, "", line)
		gsub(/^[ \t]+|[ \t]+$/, "", line)
		if (line != "") known_directive[line] = 1
	}
	close(dir "/directives.txt")

	while ((getline line < (dir "/schema.tsv")) > 0) {
		gsub(/\r/, "", line)
		if (line == "" || substr(line, 1, 1) == "#") continue
		n = split(line, f, "\t")
		if (n < 5) continue
		stype[f[1]] = f[2]
		smin[f[1]] = f[3]
		smax[f[1]] = f[4]
		senum[f[1]] = f[5]
	}

	# server / bind / client-rules / domain-rules options from the core source.
	split("exclude-default-group group proxy no-check-certificate bootstrap-dns interface check-edns whitelist-ip blacklist-ip set-mark subnet hitchhiking host-ip spki-pin host-name http-host tls-host-verify tcp-keepalive subnet-all-query-types fallback alpn drop-packet-latency g p k e b D", a, " ")
	for (i in a) server_opt[a[i]] = 1
	split("group proxy no-check-certificate bootstrap-dns interface check-edns whitelist-ip blacklist-ip set-mark subnet hitchhiking host-ip spki-pin host-name http-host tls-host-verify tcp-keepalive subnet-all-query-types fallback alpn drop-packet-latency g p k e b D", a, " ")
	for (i in a) server_needs[a[i]] = 1
	delete server_needs["exclude-default-group"]; delete server_needs["no-check-certificate"]
	delete server_needs["bootstrap-dns"]; delete server_needs["check-edns"]
	delete server_needs["whitelist-ip"]; delete server_needs["blacklist-ip"]
	delete server_needs["hitchhiking"]; delete server_needs["subnet-all-query-types"]
	delete server_needs["fallback"]; delete server_needs["e"]; delete server_needs["k"]; delete server_needs["b"]

	split("group no-rule-addr no-rule-nameserver no-rule-ipset no-rule-sni-proxy no-rule-soa no-speed-check no-cache no-dualstack-selection no-ip-alias force-aaaa-soa acl no-rules no-serve-expired force-https-soa ipset nftset alpn ddr", a, " ")
	for (i in a) bind_opt[a[i]] = 1
	split("group ipset nftset alpn no-rule-addr no-rule-nameserver no-rule-ipset no-rule-sni-proxy no-rule-soa no-speed-check no-cache no-dualstack-selection no-ip-alias force-aaaa-soa acl no-rules no-serve-expired force-https-soa ddr", a, " ")
	for (i in a) bind_needs[a[i]] = 1
	delete bind_needs["no-rule-addr"]; delete bind_needs["no-rule-nameserver"]
	delete bind_needs["no-rule-ipset"]; delete bind_needs["no-rule-sni-proxy"]
	delete bind_needs["no-rule-soa"]; delete bind_needs["no-speed-check"]
	delete bind_needs["no-cache"]; delete bind_needs["no-dualstack-selection"]
	delete bind_needs["no-ip-alias"]; delete bind_needs["force-aaaa-soa"]
	delete bind_needs["acl"]; delete bind_needs["no-rules"]; delete bind_needs["no-serve-expired"]
	delete bind_needs["force-https-soa"]; delete bind_needs["ddr"]

	split("group no-rule-addr no-rule-nameserver no-rule-ipset no-rule-sni-proxy no-rule-soa no-speed-check no-cache no-dualstack-selection no-ip-alias force-aaaa-soa acl no-rules no-serve-expired force-https-soa", a, " ")
	for (i in a) client_opt[a[i]] = 1
	client_needs["group"] = 1

	split("speed-check-mode response-mode address https-record txt-record ipset nftset nameserver group dualstack-ip-selection cname rr-ttl rr-ttl-min rr-ttl-max no-serve-expired delete no-cache no-ip-alias enable-cache no-ignore-ip c a p t n d A r g h T", a, " ")
	for (i in a) domain_opt[a[i]] = 1
	split("speed-check-mode response-mode address https-record txt-record ipset nftset nameserver group dualstack-ip-selection cname rr-ttl rr-ttl-min rr-ttl-max c a p t n d A r g h T", a, " ")
	for (i in a) domain_needs[a[i]] = 1

	split("inherit", a, " ")
	for (i in a) group_opt[a[i]] = 1
	group_needs["inherit"] = 1
}

{
	line = $0
	gsub(/\r/, "", line)
	if (line ~ /^[ \t]*$/) next
	if (line ~ /^[ \t]*#/) next

	ln = NR
	nf = split(line, tok, /[ \t]+/)
	# split() on leading whitespace yields an empty first token
	if (tok[1] == "" && nf > 1) {
		for (i = 1; i < nf; i++) tok[i] = tok[i + 1]
		nf--
	}
	d = tok[1]
	NF = nf
	for (i = 1; i <= nf; i++) $i = tok[i]

	if (!(d in known_directive)) {
		fail(ln, "неизвестная директива '" d "' — ядро её не поддерживает (опечатка?)")
		next
	}

	if (d in stype) {
		t = stype[d]
		v = (nf >= 2) ? $2 : ""
		if (v == "") {
			fail(ln, d ": требуется значение")
			next
		}
		if (d in seen_scalar) note(ln, d ": повторяется, последнее значение перекроет предыдущее")
		seen_scalar[d] = 1
		check_scalar(ln, d, t, v)
		next
	}

	if (d == "bind" || d == "bind-tcp" || d == "bind-tls" || d == "bind-https" || d == "bind-http") {
		if (nf < 2) {
			fail(ln, d ": требуется адрес")
			next
		}
		if (!endpoint($2)) fail(ln, d ": некорректный адрес '" $2 "'")
		if ((d " " $2) in seen_bind) note(ln, d ": адрес " $2 " уже указан")
		seen_bind[d " " $2] = 1
		has_bind_seen = 1
		if (d == "bind-tls" || d == "bind-https") has_tls_bind = 1
		check_options(ln, 3, bind_opt, bind_needs, d)
		next
	}

	if (d ~ /^server(-tcp|-tls|-https|-h3|-http3|-quic)?$/) {
		if (nf < 2) {
			fail(ln, d ": требуется адрес")
			next
		}
		v = $2
		if (d == "server" && server_url(v)) {
			# URL form is fine
		} else if (!endpoint(v)) {
			fail(ln, d ": некорректный адрес '" v "'")
		}
		if (d == "server-h3" || d == "server-http3" || d == "server-quic") has_quic_server = 1
		check_options(ln, 3, server_opt, server_needs, d)
		has_server = 1
		next
	}

	if (d == "group-begin") {
		group_depth++
		if (nf < 2 || $2 == "") fail(ln, "group-begin: требуется имя группы")
		check_options(ln, 3, group_opt, group_needs, d)
		next
	}
	if (d == "group-end") {
		group_depth--
		if (group_depth < 0) {
			fail(ln, "group-end без соответствующего group-begin")
			group_depth = 0
		}
		next
	}
	if (d == "group-match") {
		if (group_depth == 0) note(ln, "group-match вне group-begin/group-end")
		if (nf < 2) fail(ln, "group-match: требуется условие")
		next
	}

	if (d == "domain-rules") {
		if (nf < 2) {
			fail(ln, "domain-rules: требуется домен")
		} else if (!domain_selector($2)) {
			fail(ln, "domain-rules: некорректный домен '" $2 "'")
		}
		check_options(ln, 3, domain_opt, domain_needs, d)
		next
	}

	if (d == "address" || d == "nameserver" || d == "ipset" || d == "nftset" || d == "cname" || d == "srv-record" || d == "https-record" || d == "txt-record") {
		if (nf < 2) {
			fail(ln, d ": требуется аргумент")
		} else {
			v = $2
			if (substr(v, 1, 1) == "/" && substr(v, length(v), 1) != "/") {
				fail(ln, d ": селектор домена должен быть вида /domain/")
			} else if (substr(v, 1, 1) != "/" && substr(v, 1, 11) != "domain-set:" && v != "#" && v !~ /^#[46]?$/ && v != "-" && v !~ /^-[46]$/) {
				if (d == "address" || d == "nameserver" || d == "cname") {
					fail(ln, d ": ожидается /domain/ или domain-set:name")
				}
			}
		}
		if (d == "nftset") has_nftset = 1
		if (d == "ipset") has_ipset = 1
		next
	}

	if (d == "domain-set" || d == "ip-set") {
		have_name = 0
		have_file = 0
		for (i = 2; i <= nf; i++) {
			if ($i == "-name" || $i == "-n") have_name = i
			if ($i == "-file" || $i == "-f") have_file = i
		}
		if (!have_name) fail(ln, d ": отсутствует -name")
		if (!have_file) fail(ln, d ": отсутствует -file")
		if (have_file && (have_file + 1 > nf)) fail(ln, d ": -file без пути")
		next
	}

	if (d == "client-rules") {
		if (nf < 2) {
			fail(ln, "client-rules: требуется IP/CIDR/MAC")
		} else {
			v = $2
			if (substr(v, 1, 7) == "ip-set:") {
				if (!domain_ok(substr(v, 8))) fail(ln, "client-rules: некорректный ip-set")
			} else if (!ipcidr(v) && !mac_ok(v)) {
				fail(ln, "client-rules: ожидается IP, CIDR или MAC, получено '" v "'")
			}
		}
		check_options(ln, 3, client_opt, client_needs, d)
		next
	}

	if (d == "proxy-server") {
		if (nf < 2 || ($2 !~ /^socks5:\/\// && $2 !~ /^http:\/\//)) {
			fail(ln, "proxy-server: ожидается socks5:// или http:// URL")
		}
		next
	}

	if (d == "speed-check-mode") {
		split($2, modes, ",")
		for (i = 1; i <= length(modes); i++) {
			m = modes[i]
			if (m == "none" || m == "ping" || m ~ /^tcp:[0-9]+$/ || m ~ /^tcp-syn:[0-9]+$/) continue
			fail(ln, "speed-check-mode: неизвестный режим '" m "'")
		}
		next
	}

	if (d == "force-qtype-SOA") {
		v = $2
		sub(/^-,/, "", v)
		n = split(v, parts, ",")
		for (i = 1; i <= n; i++) {
			p = parts[i]
			if (p ~ /^[0-9]+$/ || p ~ /^[0-9]+-[0-9]+$/ || p == "-") continue
			fail(ln, "force-qtype-SOA: некорректный список '" $2 "'")
			break
		}
		next
	}

	if (d == "bind-cert-generate") {
		if ($2 != "auto" && !is_yesno($2)) fail(ln, "bind-cert-generate: ожидается auto|yes|no")
		next
	}

	if (d == "bind-cert-san" || d == "bind-cert-validity-days" || d == "bind-cert-file" || d == "bind-cert-key-file" || d == "bind-cert-key-pass" || d == "bind-cert-root-key-file") {
		next
	}

	if (d == "hosts-file" || d == "block-file" || d == "ca-file" || d == "ca-path" || d == "data-dir" || d == "cache-file" || d == "log-file" || d == "audit-file" || d == "resolv-file" || d == "debug-save-fail-packet-dir" || d == "dnsmasq-lease-file" || d == "odhcpd-lease-file" || d == "conf-file") {
		if (nf < 2) fail(ln, d ": требуется путь")
		next
	}

	if (d == "local-domain" || d == "ddns-domain") {
		if (nf < 2 || !domain_ok($2)) fail(ln, d ": некорректный домен")
		next
	}

	if (d == "edns-client-subnet") {
		if (nf < 2 || (!ipcidr($2) && !ipaddr($2))) fail(ln, "edns-client-subnet: ожидается IP/CIDR")
		next
	}

	if (d == "dns64") {
		if (nf < 2 || $2 !~ /^[0-9A-Fa-f:]+\/[0-9]+$/) fail(ln, "dns64: ожидается IPv6-префикс, например 64:ff9b::/96")
		next
	}

	if (d == "ip-alias" || d == "ip-rules" || d == "blacklist-ip" || d == "whitelist-ip" || d == "ignore-ip" || d == "bogus-nxdomain" || d == "ipset-no-speed" || d == "nftset-no-speed") {
		if (nf < 2) fail(ln, d ": требуется аргумент")
		next
	}

	if (d == "user" || d == "mdns-lookup" || d == "local-ptr-enable" || d == "expand-ptr-from-address") {
		next
	}

	if (d == "no-daemon" || d == "no-pidfile") {
		note(ln, d ": WebUI управляет службой через PID-файл и демон; эта опция может нарушить управление")
		next
	}

	if (d == "bind-cert-san") next
}

function check_scalar(ln, key, type, v) {
	if (type == "yesno") {
		if (!is_yesno(v)) fail(ln, key ": ожидается yes или no, получено '" v "'")
		return
	}
	if (type == "int") {
		if (!is_int(v)) {
			fail(ln, key ": ожидается целое число")
			return
		}
		if (is_int(smin[key]) && v + 0 < smin[key] + 0) fail(ln, key ": значение меньше минимума " smin[key])
		if (is_int(smax[key]) && smax[key] + 0 > 0 && v + 0 > smax[key] + 0) fail(ln, key ": значение больше максимума " smax[key])
		return
	}
	if (type == "size") {
		if (!is_size(v)) fail(ln, key ": ожидается размер, например 4096 или 128k")
		return
	}
	if (type == "enum" || type == "loglevel" || type == "response") {
		n = split(senum[key], vals, "|")
		for (i = 1; i <= n; i++) if (vals[i] == v) return
		fail(ln, key ": допустимые значения: " senum[key])
		return
	}
	if (type == "speed") {
		n = split(v, modes, ",")
		for (i = 1; i <= n; i++) {
			m = modes[i]
			if (m == "none" || m == "ping" || m ~ /^tcp:[0-9]+$/ || m ~ /^tcp-syn:[0-9]+$/) continue
			fail(ln, key ": неизвестный режим проверки '" m "'")
			return
		}
		return
	}
	if (type == "path") {
		if (substr(v, 1, 1) != "/" && v !~ /^[A-Za-z]:[\/\\]/) note(ln, key ": путь не абсолютный: " v)
		return
	}
	if (type == "ipcidr") {
		if (!ipcidr(v)) fail(ln, key ": ожидается IP или CIDR")
		return
	}
	if (type == "ip") {
		if (!ipaddr(v)) fail(ln, key ": ожидается IP-адрес")
		return
	}
	if (type == "domain") {
		if (!domain_ok(v)) fail(ln, key ": некорректный домен")
		return
	}
	if (type == "qtypes") {
		n = split(v, vals, ",")
		for (i = 1; i <= n; i++) if (!is_uint(vals[i])) fail(ln, key ": ожидается список числовых типов")
		return
	}
}

END {
	if (group_depth != 0) fail(NR, "незакрытый group-begin (" group_depth ")")
	if (!has_server) note(0, "в конфигурации нет ни одного upstream-сервера: резолвер может не запуститься")
	if (!has_bind_seen) note(0, "в конфигурации не задан bind — ядро откроет порт 53 по умолчанию")
	if (has_quic_server) note(0, "server-quic/server-h3 зависят от поддержки QUIC в сборке ядра; проверка выполнения — при применении")
}
