#!/bin/sh
# forksmartdns WebUI — CGI API entry point.
# Uses a line/text oriented request format; responses are JSON.
# The API is authenticated with a session cookie and CSRF header.

_self=$(cd "$(dirname "$0")" && pwd)
_lib=""
for _rel in ../lib ../../lib ../../../lib; do
	if [ -r "$_self/$_rel/common.sh" ]; then
		_lib=$(cd "$_self/$_rel" && pwd)
		break
	fi
done
if [ -z "$_lib" ]; then
	printf 'Status: 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n'
	printf 'forksmartdns: cannot locate lib/common.sh\n'
	exit 1
fi

if [ -z "${FORKSMDNS_PREFIX:-}" ]; then
	_p=$_self
	_i=0
	while [ "$_i" -lt 8 ]; do
		if [ -d "$_p/etc/forksmartdns" ]; then
			FORKSMDNS_PREFIX=$_p
			break
		fi
		_pp=$(dirname "$_p")
		[ "$_pp" = "$_p" ] && break
		_p=$_pp
		_i=$((_i + 1))
	done
	[ -n "${FORKSMDNS_PREFIX:-}" ] || FORKSMDNS_PREFIX=/opt
	export FORKSMDNS_PREFIX
fi

. "$_lib/common.sh"
. "$_lib/auth.sh"
. "$_lib/coreapi.sh"
. "$_lib/config.sh"
. "$_lib/service.sh"
. "$_lib/backup.sh"
. "$_lib/api_actions.sh"

umask 077
FSD_BODY="$FSD_RUN/body.$$"
trap 'rm -f "$FSD_BODY"' EXIT INT TERM

mkdir -p "$FSD_RUN" 2>/dev/null || true

METHOD=$(http_method)
ACTION=$(param action)
: "${FSD_BODY:=}"
if [ "$METHOD" = "POST" ] || [ "$METHOD" = "PUT" ]; then
	request_body "$FSD_BODY"
fi

raw_param() {
	printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

respond_file() {
	# respond_file FILE CONTENT_TYPE
	_f=$1
	_ct=$2
	_size=$(wc -c <"$_f" | tr -d ' ')
	_name=$(basename "$_f")
	printf 'Status: 200 OK\r\n'
	printf 'Content-Type: %s\r\n' "$_ct"
	printf 'Content-Disposition: attachment; filename="%s"\r\n' "$_name"
	printf 'Content-Length: %s\r\n' "$_size"
	printf 'Cache-Control: no-store\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf '\r\n'
	cat "$_f"
}

json_sha() {
	[ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-64 || true
}

# ---------------------------------------------------------------------------
# Public actions (no session yet)
# ---------------------------------------------------------------------------

case "$ACTION" in
	session)
		[ "$METHOD" = "GET" ] || { respond_error 405 "method" "Требуется GET"; exit 0; }
		api_session
		exit 0
		;;
	setup)
		[ "$METHOD" = "POST" ] || { respond_error 405 "method" "Требуется POST"; exit 0; }
		api_setup
		exit 0
		;;
	login)
		[ "$METHOD" = "POST" ] || { respond_error 405 "method" "Требуется POST"; exit 0; }
		api_login
		exit 0
		;;
esac

# Everything below requires a session.
require_auth

# Mutating actions are POST-only: never allowed through a GET link/preview.
case "$ACTION" in
	service|config.apply|config.block|config.backup|config.restore|config.upload|config.delete-backup|files.write|files.delete|cache.flush|logout|password)
		if [ "$METHOD" != "POST" ]; then
			respond_error 405 "method" "Требуется POST"
			exit 0
		fi
		;;
esac

# State-changing requests need CSRF + same-origin.
if [ "$METHOD" = "POST" ] || [ "$METHOD" = "PUT" ] || [ "$METHOD" = "DELETE" ]; then
	if ! origin_guard; then
		respond_error 403 "origin" "Запрос с другого origin отклонён"
		exit 0
	fi
	require_csrf
fi

case "$ACTION" in
	# ---- service / status -------------------------------------------------
	status) api_status ;;
	capabilities) api_capabilities ;;
	diag) api_diag ;;
	about) api_about ;;
	service) api_service ;;
	logs.tail) api_logs_tail ;;

	# ---- configuration ----------------------------------------------------
	config.get) api_config_get ;;
	config.blocks) api_config_blocks ;;
	config.validate) api_config_validate ;;
	config.apply) api_config_apply ;;
	config.block) api_config_block ;;
	config.backups) api_backups ;;
	config.backup) api_backup_create ;;
	config.restore) api_backup_restore ;;
	config.upload) api_backup_upload ;;
	config.download) api_backup_download ;;
	config.delete-backup) api_backup_delete ;;

	# ---- list files -------------------------------------------------------
	files.list) api_files_list ;;
	files.read) api_files_read ;;
	files.write) api_files_write ;;
	files.delete) api_files_delete ;;

	# ---- stats / core bridge ---------------------------------------------
	stats.overview) proxy_core GET /api/stats/overview ;;
	stats.metrics) proxy_core GET /api/stats/metrics ;;
	stats.hourly) api_stats_hourly ;;
	stats.daily) api_stats_daily ;;
	stats.top.domain) api_top_domain ;;
	stats.top.client) api_top_client ;;
	stats.upstream) proxy_core GET /api/upstream-server ;;
	cache.count) proxy_core GET /api/cache/count ;;
	cache.list) proxy_core GET /api/cache/domains ;;
	cache.flush)
		[ "$METHOD" = "POST" ] || { respond_error 405 "method" "Требуется POST"; exit 0; }
		api_cache_flush
		;;
	querylog) api_querylog ;;
	querylog.count) proxy_core GET /api/domain/count ;;

	logout) api_logout ;;
	password) api_password ;;

	*) respond_error 404 "not_found" "Неизвестное действие API" ;;
esac
exit 0
