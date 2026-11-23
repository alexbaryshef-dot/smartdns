#!/bin/sh
# forksmartdns WebUI — client for the hrdns core stats bridge (loopback only).
#
# The core process started by us enables its embedded stats/UI backend
# (ui-enable/ui-listen) on 127.0.0.1:<FSD_UI_INTERNAL_PORT>. That bridge is the
# same data source the stock web panel uses; we reuse it instead of parsing
# logs or duplicating the statistics engine.

CORE_HTTP_STATUS=""
CORE_API_ERROR=""

core_http_available() {
	command -v nc >/dev/null 2>&1
}

# core_fetch METHOD PATH BODY_FILE OUT_FILE -> 0 for 2xx, sets CORE_HTTP_STATUS
core_fetch() {
	_method=$1
	_path=$2
	_bodyfile=${3:-}
	_out=$4
	_host=127.0.0.1
	_port=$FSD_UI_INTERNAL_PORT
	_tmp="$FSD_RUN/corehttp.$$.$RANDOM"
	CORE_HTTP_STATUS=""
	CORE_API_ERROR=""

	: >"$_out" 2>/dev/null || { CORE_API_ERROR="cannot write response file"; return 1; }
	[ -n "$_port" ] || { CORE_API_ERROR="stats bridge port is not configured"; return 1; }

	if ! core_http_available; then
		if [ "$_method" = "GET" ] && command -v wget >/dev/null 2>&1; then
			if wget -q -T 5 -O "$_out" "http://$_host:$_port$_path" 2>/dev/null && [ -s "$_out" ]; then
				CORE_HTTP_STATUS=200
				return 0
			fi
		fi
		CORE_API_ERROR="nc/wget is not available"
		return 1
	fi

	_len=0
	if [ -n "$_bodyfile" ] && [ -f "$_bodyfile" ]; then
		_len=$(wc -c <"$_bodyfile" | tr -d ' ')
	fi

	{
		printf '%s %s HTTP/1.0\r\n' "$_method" "$_path"
		printf 'Host: %s:%s\r\n' "$_host" "$_port"
		printf 'Connection: close\r\n'
		printf 'Accept: application/json\r\n'
		if [ "$_len" -gt 0 ]; then
			printf 'Content-Length: %s\r\n' "$_len"
			printf 'Content-Type: application/json\r\n'
		fi
		printf '\r\n'
		if [ "$_len" -gt 0 ]; then
			cat "$_bodyfile"
		fi
	} | nc -w 5 "$_host" "$_port" >"$_tmp" 2>/dev/null

	if [ ! -s "$_tmp" ]; then
		CORE_API_ERROR="stats bridge is not responding"
		rm -f "$_tmp"
		return 1
	fi

	CORE_HTTP_STATUS=$(head -n 1 "$_tmp" | awk '{print $2}')
	awk 'BEGIN { body = 0 }
		{ sub(/\r$/, "") }
		body == 0 && $0 == "" { body = 1; next }
		body { print }' "$_tmp" >"$_out"
	rm -f "$_tmp"

	case "$CORE_HTTP_STATUS" in
		2*) return 0 ;;
		*) CORE_API_ERROR="stats bridge returned HTTP $CORE_HTTP_STATUS"; return 1 ;;
	esac
}

core_api_ok() {
	[ -n "$FSD_UI_INTERNAL_PORT" ] || return 1
	_out="$FSD_RUN/coreapi.ok.$$"
	core_fetch GET /api/server/version "" "$_out" >/dev/null 2>&1
	_rc=$?
	rm -f "$_out"
	return $_rc
}

core_api_flush_cache() {
	_out="$FSD_RUN/coreapi.flush.$$"
	core_fetch PUT /api/cache/flush "" "$_out"
	_rc=$?
	rm -f "$_out"
	return $_rc
}

core_bridge_state() {
	if core_api_ok 2>/dev/null; then printf 'up'; else printf 'down'; fi
}
