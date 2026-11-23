#!/bin/sh
# forksmartdns WebUI — common helpers.
# POSIX/BusyBox ash. Sourced by CGI, CLI and init scripts.

: "${FORKSMDNS_PREFIX:=/opt}"
FSD_PREFIX=${FORKSMDNS_PREFIX%/}
FSD_ETC="$FSD_PREFIX/etc/forksmartdns"
FSD_LIB="$FSD_PREFIX/share/forksmartdns"
FSD_WWW="$FSD_LIB/www"
FSD_LIBDIR="$FSD_LIB/lib"
FSD_CGI="$FSD_LIB/cgi"
FSD_BINDIR="$FSD_LIB/bin"
FSD_VAR="$FSD_PREFIX/var/lib/forksmartdns"
FSD_LOG="$FSD_PREFIX/var/log/forksmartdns"
FSD_RUN="$FSD_PREFIX/var/run/forksmartdns"
FSD_CONF="$FSD_ETC/forksmartdns.conf"
FSD_AUTH="$FSD_ETC/auth.conf"
FSD_INSTANCE="$FSD_ETC/instance.env"
FSD_LISTS="$FSD_ETC/lists"
FSD_BACKUPS="$FSD_VAR/backups"
FSD_INITD="$FSD_PREFIX/etc/init.d"
FSD_INIT="$FSD_INITD/forksmartdns"
FSD_CTL="$FSD_BINDIR/forksmartdnsctl"

# Defaults; instance.env (written by install.sh) overrides them.
FSD_VERSION="0.0.0"
FSD_UI_PORT=3636
FSD_UI_BIND=0.0.0.0
FSD_DNS_PORT=5353
FSD_DNS_BIND=0.0.0.0
FSD_UI_INTERNAL_PORT=36390
FSD_WEB_SERVER=lighttpd
FSD_CORE_KIND=hrdns
FSD_CORE_BIN="$FSD_ETC/bin/hrdns"
FSD_INSTALLED_AT=""

if [ -r "$FSD_INSTANCE" ]; then
	# shellcheck disable=SC1090
	. "$FSD_INSTANCE"
fi

[ -n "${FSD_VERSION:-}" ] || FSD_VERSION=0.0.0

FSD_PID="$FSD_RUN/forksmartdns.pid"
FSD_WEB_PID="$FSD_RUN/web.pid"
FSD_CORE_LOG="$FSD_LOG/forksmartdns.log"
FSD_AUDIT_LOG="$FSD_LOG/audit.log"
FSD_WEB_LOG="$FSD_LOG/web.log"

fsd_log() {
	# fsd_log LEVEL MESSAGE
	if [ -d "$FSD_LOG" ] && [ -w "$FSD_LOG" ]; then
		printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-info}" "$2" >>"$FSD_WEB_LOG" 2>/dev/null || true
	fi
}

fsd_die() {
	printf 'forksmartdns: %s\n' "$1" >&2
	exit "${2:-1}"
}

now_epoch() { date +%s 2>/dev/null || echo 0; }

is_uint() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

rand_hex() {
	# rand_hex BYTES
	_n="${1:-16}"
	if [ -r /dev/urandom ]; then
		od -An -N "$_n" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
		return 0
	fi
	printf '%s%s%s\n' "$(date +%s)" "$$" "${RANDOM:-0}" | sha256sum | cut -c1-$((_n * 2))
}

trim() {
	printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

pid_alive() {
	[ -n "${1:-}" ] && [ "$1" -gt 1 ] 2>/dev/null && kill -0 "$1" 2>/dev/null
}

pid_from_file() {
	[ -r "$1" ] || return 1
	_pid=$(cat "$1" 2>/dev/null | tr -dc '0-9')
	[ -n "$_pid" ] || return 1
	printf '%s' "$_pid"
}

# ---------------------------------------------------------------------------
# CGI request helpers
# ---------------------------------------------------------------------------

http_method() { printf '%s' "${REQUEST_METHOD:-GET}"; }
remote_addr() { printf '%s' "${REMOTE_ADDR:-0.0.0.0}"; }

# urldecode reads stdin and writes the decoded string.
urldecode() {
	awk '
	BEGIN { hex = "0123456789ABCDEF" }
	{
		s = $0
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "+") {
				out = out " "
			} else if (c == "%" && i + 2 <= length(s)) {
				h1 = index(hex, toupper(substr(s, i + 1, 1))) - 1
				h2 = index(hex, toupper(substr(s, i + 2, 1))) - 1
				if (h1 >= 0 && h2 >= 0) {
					out = out sprintf("%c", h1 * 16 + h2)
					i += 2
				} else {
					out = out c
				}
			} else {
				out = out c
			}
		}
		printf "%s", out
	}'
}

# _find_param NAME TEXT -> value (decoded), empty if missing
_find_param() {
	printf '%s\n' "$2" | tr '&' '\n' | {
		while IFS= read -r _pair; do
			case "$_pair" in
				"$1="*)
					printf '%s' "${_pair#"$1="}" | urldecode
					exit 0
					;;
				"$1")
					exit 0
					;;
			esac
		done
	}
}

param() { _find_param "$1" "${QUERY_STRING:-}"; }

form_param() {
	# form_param NAME FILE
	[ -r "$2" ] || return 0
	_find_param "$1" "$(cat "$2")"
}

cookie_get() {
	# cookie_get NAME
	printf '%s\n' "${HTTP_COOKIE:-}" | tr ';' '\n' | {
		while IFS= read -r _c; do
			_c=$(trim "$_c")
			case "$_c" in
				"$1="*)
					printf '%s' "${_c#"$1="}"
					exit 0
					;;
			esac
		done
	}
}

header_get() {
	# header_get X-FSD-CSRF -> $HTTP_X_FSD_CSRF
	_h="HTTP_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
	eval "printf '%s' \"\${$_h:-}\""
}

request_body() {
	# Read at most CONTENT_LENGTH bytes from stdin to the given file.
	_len=${CONTENT_LENGTH:-0}
	case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
	if [ "$_len" -gt 4194304 ]; then
		fsd_die "request body too large" 13
	fi
	: >"$1"
	if [ "$_len" -gt 0 ]; then
		head -c "$_len" >"$1" 2>/dev/null || true
	fi
}

req_path() { printf '%s' "${REQUEST_URI%%\?*}"; }

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

# json_str STRING -> quoted JSON string
json_str() {
	printf '"'
	printf '%s' "${1:-}" | awk '
		BEGIN { ORS = "" }
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			gsub(/[\001-\010\013\014\016-\037]/, "")
			if (NR > 1) printf "\\n"
			printf "%s", $0
		}'
	printf '"'
}

# json_str_file FILE -> quoted JSON string with escaped newlines
json_str_file() {
	printf '"'
	awk '
		BEGIN { ORS = "" }
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			gsub(/[\001-\010\013\014\016-\037]/, "")
			if (NR > 1) printf "\\n"
			printf "%s", $0
		}' "$1"
	# awk is line oriented and drops the final newline; restore it.
	if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
		printf '\\n'
	fi
	printf '"'
}

json_bool() {
	case "${1:-}" in yes|1|true|on) printf 'true' ;; *) printf 'false' ;; esac
}

json_int_or_null() {
	if is_uint "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi
}

# respond_begin [STATUS] — emit CGI headers for a JSON body printed afterwards.
respond_begin() {
	printf 'Status: %s\r\n' "${1:-200 OK}"
	printf 'Content-Type: application/json; charset=utf-8\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf 'Pragma: no-cache\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf 'X-Frame-Options: DENY\r\n'
	printf 'Referrer-Policy: no-referrer\r\n'
	printf '\r\n'
}

# respond_json STATUS BODY [extra-header...]
respond_json() {
	_status=$1
	_body=$2
	shift 2
	printf 'Status: %s\r\n' "$_status"
	printf 'Content-Type: application/json; charset=utf-8\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf 'Pragma: no-cache\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf 'X-Frame-Options: DENY\r\n'
	printf 'Referrer-Policy: no-referrer\r\n'
	for _h in "$@"; do
		printf '%s\r\n' "$_h"
	done
	printf '\r\n'
	printf '%s' "$_body"
}

respond_error() {
	# respond_error STATUS CODE MESSAGE
	respond_json "$1" "{\"ok\":false,\"error\":{\"code\":$(json_str "$2"),\"message\":$(json_str "$3")}}"
}

json_ok() {
	# json_ok DATA_JSON
	printf '{"ok":true,"data":%s}' "${1:-null}"
}

# ---------------------------------------------------------------------------
# Ports and HTTP health
# ---------------------------------------------------------------------------

port_listening() {
	# port_listening PORT [tcp|udp]; returns 0 if a socket is bound.
	_port=$1
	_proto=${2:-tcp}
	_hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1
	for _f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$_f" ] || continue
		[ "$_proto" = tcp ] || continue
		awk -v p=":$_hex" '$2 ~ p && $4 == "0A" { found = 1 } END { exit found ? 0 : 1 }' "$_f" && return 0
	done
	if [ "$_proto" = udp ]; then
		for _f in /proc/net/udp /proc/net/udp6; do
			[ -r "$_f" ] || continue
			awk -v p=":$_hex" '$2 ~ p { found = 1 } END { exit found ? 0 : 1 }' "$_f" && return 0
		done
	fi
	if command -v netstat >/dev/null 2>&1; then
		if [ "$_proto" = tcp ]; then
			netstat -ltn 2>/dev/null | awk -v p=":$_port\$" '$1 ~ /tcp/ && $4 ~ p { found = 1 } END { exit found ? 0 : 1 }' && return 0
		else
			netstat -lun 2>/dev/null | awk -v p=":$_port\$" '$1 ~ /udp/ && $4 ~ p { found = 1 } END { exit found ? 0 : 1 }' && return 0
		fi
	fi
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | awk -v p=":$_port\$" 'NR > 1 && $4 ~ p { found = 1 } END { exit found ? 0 : 1 }' && return 0
	fi
	return 1
}

tcp_connect_ok() {
	# tcp_connect_ok HOST PORT [seconds]
	_h=${1:-127.0.0.1}
	_p=$2
	_t=${3:-2}
	if command -v nc >/dev/null 2>&1; then
		nc -z -w "$_t" "$_h" "$_p" >/dev/null 2>&1 && return 0
	fi
	# Fallback: send an empty HTTP request and look at the status line.
	printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$_h" | nc -w "$_t" "$_h" "$_p" 2>/dev/null | head -n 1 | grep -q '^HTTP/' && return 0
	return 1
}

wait_tcp() {
	# wait_tcp HOST PORT TIMEOUT
	_h=$1
	_p=$2
	_t=${3:-20}
	_i=0
	while [ "$_i" -lt "$_t" ]; do
		tcp_connect_ok "$_h" "$_p" 1 && return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

wait_pid() {
	# wait_pid PID TIMEOUT
	_p=$1
	_t=${2:-20}
	_i=0
	while [ "$_i" -lt "$_t" ]; do
		pid_alive "$_p" && return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

# Free internal loopback port for the core UI bridge.
pick_internal_port() {
	_p=${FSD_UI_INTERNAL_PORT:-36390}
	_i=0
	while [ "$_i" -lt 20 ]; do
		if ! port_listening "$_p" tcp; then
			printf '%s' "$_p"
			return 0
		fi
		_p=$((_p + 1))
		_i=$((_i + 1))
	done
	printf '%s' 36390
}
