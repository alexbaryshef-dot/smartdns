#!/bin/sh
# forksmartdns WebUI — service control helpers.

service_pid() { pid_from_file "$FSD_PID"; }

service_is_running() {
	_pid=$(service_pid) || return 1
	pid_alive "$_pid" || return 1
	if [ -r "/proc/$_pid/cmdline" ]; then
		_cmd=$(tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null)
		case "$_cmd" in
			*hrdns*|*smartdns*|*forksmartdns*) return 0 ;;
			*) return 1 ;;
		esac
	fi
	return 0
}

web_pid() { pid_from_file "$FSD_WEB_PID"; }

web_is_running() {
	_pid=$(web_pid) || return 1
	pid_alive "$_pid" || return 1
	return 0
}

service_uptime() {
	[ -r "$FSD_RUN/started-at" ] || { echo 0; return 0; }
	_start=$(cat "$FSD_RUN/started-at" 2>/dev/null)
	is_uint "$_start" || _start=0
	[ "$_start" -gt 0 ] || { echo 0; return 0; }
	_now=$(now_epoch)
	[ "$_now" -ge "$_start" ] && echo $((_now - _start)) || echo 0
}

service_core_version() {
	[ -x "$FSD_CORE_BIN" ] || return 1
	"$FSD_CORE_BIN" -v 2>/dev/null | head -n 1
}

service_enabled() {
	[ -L "$FSD_PREFIX/etc/rc.d/S99forksmartdns" ] && return 0
	if [ -r "$FSD_PREFIX/etc/rc.local" ] && grep -q 'forksmartdns.*start' "$FSD_PREFIX/etc/rc.local" 2>/dev/null; then
		return 0
	fi
	return 1
}

# _run_init ACTION [quiet]
_service_init() {
	_action=$1
	_quiet=${2:-0}
	[ -x "$FSD_INIT" ] || { echo "init script not found: $FSD_INIT"; return 1; }
	if [ "$_quiet" = "1" ]; then
		"$FSD_INIT" "$_action" >/dev/null 2>&1
		return $?
	fi
	"$FSD_INIT" "$_action" 2>&1
}

service_start() { _service_init start "$1"; }
service_stop() { _service_init stop "$1"; }
service_restart() { _service_init restart "$1"; }
service_enable() { _service_init enable "$1"; }
service_disable() { _service_init disable "$1"; }

service_wait_ready() {
	_timeout=${1:-25}
	_i=0
	_ui_expected=0
	if grep -qE '^[ \t]*ui-enable[ \t]+yes' "$FSD_CONF" 2>/dev/null; then
		_ui_expected=1
	fi
	while [ "$_i" -lt "$_timeout" ]; do
		if service_is_running; then
			if [ "$_ui_expected" -eq 0 ] || core_api_ok; then
				return 0
			fi
		fi
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

service_summary_json() {
	_pid=$(service_pid 2>/dev/null || true)
	_wpid=$(web_pid 2>/dev/null || true)
	_running=false
	service_is_running && _running=true
	_web=false
	web_is_running && _web=true
	_enabled=false
	service_enabled && _enabled=true
	_ver=$(service_core_version 2>/dev/null || echo "")
	printf '{"running":%s,"pid":%s,"uptime":%s,"web_running":%s,"web_pid":%s,"enabled":%s,"core_version":%s}' \
		"$_running" "$(json_int_or_null "$_pid")" "$(service_uptime)" "$_web" "$(json_int_or_null "$_wpid")" "$_enabled" "$(json_str "$_ver")"
}
