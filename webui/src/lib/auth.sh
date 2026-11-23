#!/bin/sh
# forksmartdns WebUI — authentication, sessions and CSRF.

FSD_SESSION_TTL=${FSD_SESSION_TTL:-28800}
FSD_HASH_ITER=${FSD_HASH_ITER:-150}

auth_initialized() {
	[ -r "$FSD_AUTH" ] && grep -q '^hash=[0-9a-fA-F]\{32,\}$' "$FSD_AUTH" 2>/dev/null
}

auth_field() {
	sed -n "s/^$1=//p" "$FSD_AUTH" 2>/dev/null | head -n 1
}

fsd_hash_password() {
	# fsd_hash_password SALT PASSWORD [ITER]
	_salt=$1
	_pass=$2
	_iter=${3:-$FSD_HASH_ITER}
	is_uint "$_iter" || _iter=$FSD_HASH_ITER
	[ "$_iter" -ge 1 ] || _iter=1
	_h=$(printf '%s%s' "$_salt" "$_pass" | sha256sum 2>/dev/null | cut -c1-64)
	_i=1
	while [ "$_i" -lt "$_iter" ]; do
		_h=$(printf '%s%s%s' "$_salt" "$_h" "$_pass" | sha256sum 2>/dev/null | cut -c1-64)
		_i=$((_i + 1))
	done
	printf '%s' "$_h"
}

auth_set_password() {
	# auth_set_password PASSWORD
	_pass=$1
	_salt=$(rand_hex 8)
	_hash=$(fsd_hash_password "$_salt" "$_pass")
	mkdir -p "$FSD_ETC"
	(
		umask 077
		{
			echo "version=1"
			echo "user=admin"
			echo "salt=$_salt"
			echo "iter=$FSD_HASH_ITER"
			echo "hash=$_hash"
			echo "created=$(now_epoch)"
		} >"$FSD_AUTH"
	)
	chmod 600 "$FSD_AUTH" 2>/dev/null || true
	fsd_log info "admin password was set"
	return 0
}

auth_check_password() {
	_pass=$1
	auth_initialized || return 1
	_salt=$(auth_field salt)
	_iter=$(auth_field iter)
	_want=$(auth_field hash)
	[ -n "$_salt" ] && [ -n "$_want" ] || return 1
	_got=$(fsd_hash_password "$_salt" "$_pass" "$_iter")
	[ "$_got" = "$_want" ] || return 1
	return 0
}

setup_token_check() {
	_tok=$1
	[ -r "$FSD_ETC/setup-token" ] || return 1
	[ -n "$_tok" ] && [ "$_tok" = "$(cat "$FSD_ETC/setup-token" 2>/dev/null)" ] || return 1
	return 0
}

sessions_dir() {
	[ -d "$FSD_RUN/sessions" ] || { mkdir -p "$FSD_RUN/sessions" 2>/dev/null && chmod 700 "$FSD_RUN/sessions" 2>/dev/null; }
	printf '%s' "$FSD_RUN/sessions"
}

session_create() {
	_token=$(rand_hex 16)
	_csrf=$(rand_hex 16)
	_dir=$(sessions_dir)
	[ -n "$_dir" ] || return 1
	(
		umask 077
		printf 'exp=%s\ncsrf=%s\nip=%s\ncreated=%s\n' \
			"$(( $(now_epoch) + FSD_SESSION_TTL ))" "$_csrf" "$(remote_addr)" "$(now_epoch)" >"$_dir/$_token"
	)
	SESSION_TOKEN=$_token
	SESSION_CSRF=$_csrf
	SESSION_COOKIE="Set-Cookie: fsd_session=$_token; Path=/; Max-Age=$FSD_SESSION_TTL; HttpOnly; SameSite=Strict"
	return 0
}

session_destroy_current() {
	[ -n "${SESSION_TOKEN:-}" ] || return 0
	rm -f "$(sessions_dir)/$SESSION_TOKEN" 2>/dev/null || true
}

session_load() {
	SESSION_TOKEN=""
	SESSION_CSRF=""
	_token=$(cookie_get fsd_session)
	[ -n "$_token" ] || return 1
	case "$_token" in *[!0-9a-fA-F]*) return 1 ;; esac
	[ "${#_token}" -eq 32 ] || return 1
	_dir=$(sessions_dir)
	[ -r "$_dir/$_token" ] || return 1
	_exp=$(sed -n 's/^exp=//p' "$_dir/$_token" | head -n 1)
	_csrf=$(sed -n 's/^csrf=//p' "$_dir/$_token" | head -n 1)
	_ip=$(sed -n 's/^ip=//p' "$_dir/$_token" | head -n 1)
	is_uint "$_exp" || return 1
	[ "$_exp" -gt "$(now_epoch)" ] || { rm -f "$_dir/$_token"; return 1; }
	if [ -n "$_ip" ] && [ "$_ip" != "$(remote_addr)" ]; then
		return 1
	fi
	SESSION_TOKEN=$_token
	SESSION_CSRF=$_csrf
	return 0
}

session_cleanup() {
	_dir=$(sessions_dir)
	[ -d "$_dir" ] || return 0
	_now=$(now_epoch)
	for _f in "$_dir"/*; do
		[ -f "$_f" ] || continue
		_exp=$(sed -n 's/^exp=//p' "$_f" | head -n 1)
		if ! is_uint "$_exp" || [ "$_exp" -le "$_now" ]; then
			rm -f "$_f" 2>/dev/null || true
		fi
	done
}

require_auth() {
	if ! session_load; then
		respond_error 401 "unauthorized" "Требуется авторизация"
		exit 0
	fi
}

require_csrf() {
	_got=$(header_get X-FSD-CSRF)
	if [ -z "${SESSION_CSRF:-}" ] || [ -z "$_got" ] || [ "$_got" != "$SESSION_CSRF" ]; then
		respond_error 403 "csrf" "Неверный CSRF-токен. Обновите страницу и войдите снова."
		exit 0
	fi
}

# Same-origin guard for state-changing requests (defence in depth).
origin_guard() {
	_origin=${HTTP_ORIGIN:-}
	[ -n "$_origin" ] || return 0
	_host=${HTTP_HOST:-}
	case "$_origin" in
		http://*|https://*) ;;
		*) return 0 ;;
	esac
	_o=${_origin#*://}
	_o=${_o%%/*}
	[ "$_o" = "$_host" ] && return 0
	fsd_log warn "cross-origin request rejected: origin=$_origin host=$_host"
	return 1
}

# ---- login throttling ------------------------------------------------------

login_fail_file() {
	_ip=$(remote_addr | tr -c '0-9a-zA-Z.:_-' '_')
	printf '%s' "$FSD_RUN/login-fail.$_ip"
}

login_locked() {
	_f=$(login_fail_file)
	[ -r "$_f" ] || return 1
	_count=$(sed -n 's/^count=//p' "$_f" | head -n 1)
	_last=$(sed -n 's/^last=//p' "$_f" | head -n 1)
	is_uint "$_count" || _count=0
	is_uint "$_last" || _last=0
	if [ "$_count" -ge 5 ] && [ $(( $(now_epoch) - _last )) -lt 300 ]; then
		return 0
	fi
	return 1
}

login_fail_register() {
	_f=$(login_fail_file)
	_count=0
	if [ -r "$_f" ]; then
		_count=$(sed -n 's/^count=//p' "$_f" | head -n 1)
		is_uint "$_count" || _count=0
	fi
	_count=$((_count + 1))
	(
		umask 077
		printf 'count=%s\nlast=%s\n' "$_count" "$(now_epoch)" >"$_f"
	)
}

login_fail_clear() {
	rm -f "$(login_fail_file)" 2>/dev/null || true
}

# ---- API actions -----------------------------------------------------------

api_session() {
	_authed=0
	if session_load; then _authed=1; fi
	_initialized=0
	if auth_initialized; then _initialized=1; fi
	_setup=0
	if [ "$_initialized" -eq 0 ] && [ -r "$FSD_ETC/setup-token" ]; then _setup=1; fi
	respond_json 200 "{\"ok\":true,\"data\":{\"authenticated\":$([ "$_authed" -eq 1 ] && echo true || echo false),\"initialized\":$([ "$_initialized" -eq 1 ] && echo true || echo false),\"setup_required\":$([ "$_setup" -eq 1 ] && echo true || echo false),\"csrf\":$(json_str "${SESSION_CSRF:-}"),\"user\":\"admin\"}}"
}

api_setup() {
	if auth_initialized; then
		respond_error 409 "already_initialized" "Пароль уже задан"
		return 0
	fi
	_token=$(form_param token "$FSD_BODY")
	_pass=$(form_param password "$FSD_BODY")
	if ! setup_token_check "$_token"; then
		fsd_log warn "setup rejected: invalid setup token from $(remote_addr)"
		respond_error 403 "setup_token" "Неверный установочный токен. Он напечатан установщиком и лежит в $FSD_ETC/setup-token"
		return 0
	fi
	if [ "${#_pass}" -lt 8 ]; then
		respond_error 400 "weak_password" "Пароль должен быть не короче 8 символов"
		return 0
	fi
	auth_set_password "$_pass"
	rm -f "$FSD_ETC/setup-token" 2>/dev/null || true
	session_create || { respond_error 500 "session" "Не удалось создать сессию"; return 0; }
	respond_json 200 "{\"ok\":true,\"data\":{\"csrf\":$(json_str "$SESSION_CSRF")}}" "$SESSION_COOKIE"
}

api_login() {
	if ! auth_initialized; then
		respond_error 409 "setup_required" "Сначала задайте пароль администратора"
		return 0
	fi
	if login_locked; then
		respond_error 429 "locked" "Слишком много неудачных попыток. Повторите через 5 минут."
		return 0
	fi
	if ! origin_guard; then
		respond_error 403 "origin" "Запрос с другого origin отклонён"
		return 0
	fi
	_pass=$(form_param password "$FSD_BODY")
	if [ -z "$_pass" ] || ! auth_check_password "$_pass"; then
		login_fail_register
		fsd_log warn "failed login from $(remote_addr)"
		sleep 1
		respond_error 401 "invalid_credentials" "Неверный пароль"
		return 0
	fi
	login_fail_clear
	session_cleanup
	session_create || { respond_error 500 "session" "Не удалось создать сессию"; return 0; }
	fsd_log info "login from $(remote_addr)"
	respond_json 200 "{\"ok\":true,\"data\":{\"csrf\":$(json_str "$SESSION_CSRF")}}" "$SESSION_COOKIE"
}

api_logout() {
	require_auth
	require_csrf
	session_destroy_current
	respond_json 200 "{\"ok\":true,\"data\":null}" "Set-Cookie: fsd_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
}

api_password() {
	require_auth
	require_csrf
	_current=$(form_param current "$FSD_BODY")
	_new=$(form_param new "$FSD_BODY")
	if ! auth_check_password "$_current"; then
		respond_error 403 "invalid_current" "Текущий пароль неверен"
		return 0
	fi
	if [ "${#_new}" -lt 8 ]; then
		respond_error 400 "weak_password" "Пароль должен быть не короче 8 символов"
		return 0
	fi
	auth_set_password "$_new"
	# Invalidate every existing session, then create a fresh one.
	rm -f "$(sessions_dir)"/* 2>/dev/null || true
	session_create || true
	respond_json 200 "{\"ok\":true,\"data\":{\"csrf\":$(json_str "${SESSION_CSRF:-}")}}" "${SESSION_COOKIE:-X-Ignore: 1}"
}
