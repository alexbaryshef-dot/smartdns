#!/bin/sh
# forksmartdns WebUI — API action implementations.

api_tmp() {
	_t="$FSD_RUN/api.$$.$RANDOM"
	: >"$_t"
	printf '%s' "$_t"
}

emit_records_filter() {
	# emit_records_filter FILE SEVERITY -> JSON array
	_f=$1
	_s=$2
	_tmp=$(api_tmp)
	awk -F '	' -v want="$_s" '$1 == want { print $2 "	" $3 }' "$_f" 2>/dev/null >"$_tmp"
	printf '['
	_first=1
	while IFS='	' read -r _ln _msg; do
		[ -n "$_ln" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '{"line":%s,"message":%s}' "$(json_int_or_null "$_ln")" "$(json_str "$_msg")"
	done <"$_tmp"
	printf ']'
	rm -f "$_tmp"
}

json_array_strings() {
	# json_array_strings FILE (one value per line)
	_f=$1
	printf '['
	_first=1
	while IFS= read -r _v; do
		[ -n "$_v" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '%s' "$(json_str "$_v")"
	done <"$_f"
	printf ']'
}

# ---------------------------------------------------------------------------
# status / capabilities / diagnostics
# ---------------------------------------------------------------------------

api_status() {
	_running=false
	service_is_running && _running=true
	_bridge=$(core_bridge_state)
	_ui_expected=false
	grep -qE '^[ \t]*ui-enable[ \t]+yes' "$FSD_CONF" 2>/dev/null && _ui_expected=true
	_arch=$(uname -m 2>/dev/null || echo unknown)
	_kernel=$(uname -r 2>/dev/null || echo unknown)
	_cfg_exists=false
	_cfg_lines=0
	_cfg_sha=""
	_cfg_mtime=0
	if [ -f "$FSD_CONF" ]; then
		_cfg_exists=true
		_cfg_lines=$(wc -l <"$FSD_CONF" | tr -d ' ')
		_cfg_sha=$(json_sha "$FSD_CONF")
		_cfg_mtime=$(file_mtime "$FSD_CONF")
	fi
	_setup=false
	[ -r "$FSD_ETC/setup-token" ] && ! auth_initialized && _setup=true
	_initialized=false
	auth_initialized && _initialized=true

	_winet=0
	command -v nft >/dev/null 2>&1 && _winet=1
	_ipset=0
	command -v ipset >/dev/null 2>&1 && _ipset=1
	_busybox=0
	command -v busybox >/dev/null 2>&1 && _busybox=1

	respond_begin "200 OK"
	printf '{"ok":true,"data":{'
	printf '"service":%s,' "$(service_summary_json)"
	printf '"instance":{"version":%s,"core_kind":%s,"core_binary":%s,"core_source":%s,"core_version":%s,"web_server":%s,' \
		"$(json_str "$FSD_VERSION")" "$(json_str "$FSD_CORE_KIND")" "$(json_str "$FSD_CORE_BIN")" \
		"$(json_str "${FSD_CORE_SOURCE:-}")" "$(json_str "${FSD_CORE_VERSION:-}")" "$(json_str "$FSD_WEB_SERVER")"
	printf '"dns":{"port":%s,"bind":%s},' "$(json_int_or_null "$FSD_DNS_PORT")" "$(json_str "$FSD_DNS_BIND")"
	printf '"ui":{"port":%s,"bind":%s,"internal_port":%s,"url":%s},' \
		"$(json_int_or_null "$FSD_UI_PORT")" "$(json_str "$FSD_UI_BIND")" "$(json_int_or_null "$FSD_UI_INTERNAL_PORT")" \
		"$(json_str "http://$(hostname 2>/dev/null || echo router):$FSD_UI_PORT/")"
	printf '"paths":{"etc":%s,"var":%s,"log":%s,"run":%s,"www":%s}},' \
		"$(json_str "$FSD_ETC")" "$(json_str "$FSD_VAR")" "$(json_str "$FSD_LOG")" "$(json_str "$FSD_RUN")" "$(json_str "$FSD_WWW")"
	printf '"platform":{"arch":%s,"kernel":%s,"nft":%s,"ipset":%s,"busybox":%s},' \
		"$(json_str "$_arch")" "$(json_str "$_kernel")" "$(json_bool "$_winet")" "$(json_bool "$_ipset")" "$(json_bool "$_busybox")"
	printf '"config":{"path":%s,"exists":%s,"lines":%s,"sha256":%s,"mtime":%s},' \
		"$(json_str "$FSD_CONF")" "$_cfg_exists" "$(json_int_or_null "$_cfg_lines")" "$(json_str "$_cfg_sha")" "$(json_int_or_null "$_cfg_mtime")"
	printf '"bridge":%s,"ui_expected":%s,"auth":{"initialized":%s,"setup_required":%s},' \
		"$(json_str "$_bridge")" "$_ui_expected" "$_initialized" "$_setup"
	printf '"warnings":['
	_wfirst=1
	if [ "$_running" = false ]; then
		[ "$_wfirst" -eq 1 ] || printf ','
		_wfirst=0
		printf '%s' "$(json_str 'Служба forksmartdns остановлена')"
	fi
	if [ "$_ui_expected" = true ] && [ "$_bridge" = down ]; then
		[ "$_wfirst" -eq 1 ] || printf ','
		_wfirst=0
		printf '%s' "$(json_str 'Stats-мост ядра недоступен: страницы статистики, кэша и журнала будут пусты')"
	fi
	if [ "$_winet" = 0 ]; then
		[ "$_wfirst" -eq 1 ] || printf ','
		_wfirst=0
		printf '%s' "$(json_str 'nftables не обнаружен: nftset недоступен (ipset работает)')"
	fi
	printf ']}}'
}

api_capabilities() {
	_quic=false
	[ -x "$FSD_CORE_BIN" ] && "$FSD_CORE_BIN" --is-quic-supported >/dev/null 2>&1 && _quic=true
	_nft=false
	command -v nft >/dev/null 2>&1 && _nft=true
	_ipset=false
	command -v ipset >/dev/null 2>&1 && _ipset=true
	_bridge=$(core_bridge_state)
	respond_begin "200 OK"
	printf '{"ok":true,"data":{"core":{"binary":%s,"version":%s,"quic":%s,"bridge":%s},' \
		"$(json_str "$FSD_CORE_BIN")" "$(json_str "$(service_core_version 2>/dev/null || echo '')")" "$_quic" "$(json_str "$_bridge")"
	printf '"platform":{"nft":%s,"ipset":%s},' "$_nft" "$_ipset"
	printf '"features":['
	_first=1
	_emit_feature() {
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '{"id":%s,"state":%s,"reason":%s}' "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")"
	}
	_emit_feature "upstream.udp" supported ""
	_emit_feature "upstream.tcp" supported ""
	_emit_feature "upstream.tls" supported "Требуется корректный CA (ca-file/ca-path)"
	_emit_feature "upstream.https" supported "DoH; требует CA и системного времени"
	_emit_feature "upstream.quic" "$([ "$_quic" = true ] && echo supported || echo unsupported)" "$([ "$_quic" = true ] && echo '' || echo 'Сборка ядра без QUIC/HTTP3')"
	_emit_feature "upstream.http3" "$([ "$_quic" = true ] && echo supported || echo unsupported)" "$([ "$_quic" = true ] && echo '' || echo 'Сборка ядра без QUIC/HTTP3')"
	_emit_feature "listener.udp" supported ""
	_emit_feature "listener.tcp" supported ""
	_emit_feature "listener.tls" supported "Сертификат создаётся ядром автоматически"
	_emit_feature "listener.https" supported "DoH-сервер; сертификат создаётся автоматически"
	_emit_feature "listener.http" supported "DoH без TLS (не рекомендуется)"
	_emit_feature "groups" supported ""
	_emit_feature "domain.rules" supported ""
	_emit_feature "domain.set" supported ""
	_emit_feature "ip.set" supported ""
	_emit_feature "client.rules" supported "IP, CIDR, MAC и ip-set"
	_emit_feature "ipset" "$([ "$_ipset" = true ] && echo supported || echo partial)" "$([ "$_ipset" = true ] && echo '' || echo 'Пакет/утилита ipset не найден; ядро сможет писать только при его наличии')"
	_emit_feature "nftset" "$([ "$_nft" = true ] && echo partial || echo unsupported)" "$([ "$_nft" = true ] && echo 'Требует nftables и поддержки в ядре' || echo 'nftables отсутствует на Keenetic; раздел недоступен')"
	_emit_feature "cache" supported "Используется stats-мост ядра"
	_emit_feature "querylog" "$([ "$_bridge" = up ] && echo supported || echo partial)" "$([ "$_bridge" = up ] && echo '' || echo 'Без stats-моста журнал недоступен')"
	_emit_feature "stats" "$([ "$_bridge" = up ] && echo supported || echo partial)" "$([ "$_bridge" = up ] && echo '' || echo 'Без stats-моста статистика недоступна')"
	_emit_feature "service" supported "start/stop/restart/autostart"
	_emit_feature "backup" supported "tar.gz, ротация, откат"
	_emit_feature "tls.autocert" supported ""
	_emit_feature "dns64" supported "Требуется IPv6 на роутере"
	_emit_feature "mdns" supported ""
	printf ']}}'
}

api_diag() {
	_out=$(api_tmp)
	_stat() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$_out"; }
	if [ -x "$FSD_CORE_BIN" ]; then
		_stat core_binary ok "$("$FSD_CORE_BIN" -v 2>/dev/null | head -n 1)"
	else
		_stat core_binary error "ядро не найдено: $FSD_CORE_BIN"
	fi
	if [ -f "$FSD_CONF" ]; then
		_r=$(api_tmp)
		run_static_validation "$FSD_CONF" "$_r"
		_e=$(validation_error_count "$_r")
		_w=$(validation_warning_count "$_r")
		if [ "$_e" -gt 0 ]; then
			_stat config error "ошибок: $_e, предупреждений: $_w"
		else
			_stat config ok "ошибок нет, предупреждений: $_w"
		fi
		rm -f "$_r"
	else
		_stat config error "конфигурация отсутствует"
	fi
	if service_is_running; then
		_stat service ok "PID $(service_pid), uptime $(service_uptime) c"
	else
		_stat service error "служба не запущена"
	fi
	if port_listening "$FSD_UI_PORT" tcp; then
		_stat ui_port ok "TCP $FSD_UI_PORT слушается"
	else
		_stat ui_port error "TCP $FSD_UI_PORT не слушается"
	fi
	if port_listening "$FSD_DNS_PORT" udp; then
		_stat dns_port ok "UDP $FSD_DNS_PORT слушается"
	else
		_stat dns_port warn "UDP $FSD_DNS_PORT не слушается"
	fi
	if tcp_connect_ok 127.0.0.1 "$FSD_UI_PORT" 2; then
		_stat web ok "HTTP-сервер отвечает"
	else
		_stat web error "HTTP-сервер не отвечает на 127.0.0.1:$FSD_UI_PORT"
	fi
	if core_api_ok; then
		_stat bridge ok "stats-мост доступен"
	else
		_stat bridge warn "stats-мост недоступен"
	fi
	for _d in "$FSD_VAR" "$FSD_LOG" "$FSD_RUN"; do
		if [ -w "$_d" ]; then
			_stat "dir:$(basename "$_d")" ok "запись разрешена"
		else
			_stat "dir:$(basename "$_d")" error "нет записи: $_d"
		fi
	done
	_avail=$(df -k "$FSD_PREFIX" 2>/dev/null | awk 'NR == 2 { print $4 }')
	if is_uint "${_avail:-}" && [ "$_avail" -gt 1024 ]; then
		_stat disk ok "свободно ${_avail} КБ"
	else
		_stat disk warn "мало свободного места"
	fi
	if command -v nft >/dev/null 2>&1; then
		_stat nftables info "nft найден"
	else
		_stat nftables info "nftables отсутствует — nftset помечен как неподдерживаемый"
	fi

	respond_begin "200 OK"
	printf '{"ok":true,"data":{"checks":['
	_first=1
	while IFS='	' read -r _id _state _detail; do
		[ -n "$_id" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '{"id":%s,"state":%s,"detail":%s}' "$(json_str "$_id")" "$(json_str "$_state")" "$(json_str "$_detail")"
	done <"$_out"
	printf ']}}'
	rm -f "$_out"
}

api_about() {
	_ui_ver=$FSD_VERSION
	_src="https://github.com/alexbaryshef-dot/smartdns/tree/main/webui"
	printf '{"ok":true,"data":{"ui_version":%s,"api_version":%s,"core_kind":%s,"core_version":%s,"license":%s,"source":%s,"docs":%s}}' \
		"$(json_str "$_ui_ver")" "$(json_str "1")" "$(json_str "$FSD_CORE_KIND")" \
		"$(json_str "$(service_core_version 2>/dev/null || echo '')")" \
		"$(json_str 'GPL-3.0 (проект), ядро hrdns/smartdns — GPL-3.0')" \
		"$(json_str "$_src")" "$(json_str "$FSD_LIB/docs")"
}

# ---------------------------------------------------------------------------
# service and logs
# ---------------------------------------------------------------------------

api_service() {
	_act=$(form_param action "$FSD_BODY")
	case "$_act" in
		start|stop|restart|enable|disable) ;;
		*) respond_error 400 "bad_action" "Допустимо: start, stop, restart, enable, disable"; return 0 ;;
	esac
	if [ "$METHOD" != "POST" ]; then
		respond_error 405 "method" "Требуется POST"
		return 0
	fi
	_out=$("$FSD_INIT" "$_act" 2>&1)
	_rc=$?
	if [ "$_act" = "restart" ] || [ "$_act" = "start" ]; then
		service_wait_ready 20 || true
	fi
	if [ "$_rc" -ne 0 ]; then
		_outj=$(json_str "$_out")
		_svcj=$(service_summary_json)
		respond_json 500 "{\"ok\":false,\"error\":{\"code\":\"service\",\"message\":$_outj},\"data\":{\"service\":$_svcj}}"
		return 0
	fi
	respond_json 200 "{\"ok\":true,\"data\":{\"output\":$(json_str "$_out"),\"service\":$(service_summary_json)}}"
}

api_logs_tail() {
	_name=$(param name)
	_lines=$(param lines)
	is_uint "$_lines" || _lines=200
	[ "$_lines" -gt 2000 ] && _lines=2000
	case "$_name" in
		core) _f=$FSD_CORE_LOG ;;
		audit) _f=$FSD_AUDIT_LOG ;;
		web) _f=$FSD_WEB_LOG ;;
		validate) _f=$FSD_LOG/validate.log ;;
		*) respond_error 400 "bad_log" "Допустимо: core, audit, web, validate"; return 0 ;;
	esac
	_text=""
	_size=0
	if [ -f "$_f" ]; then
		_size=$(wc -c <"$_f" | tr -d ' ')
		_text=$(tail -n "$_lines" "$_f" 2>/dev/null)
	fi
	_nj=$(json_str "$_name")
	_fj=$(json_str "$_f")
	_sj=$(json_int_or_null "$_size")
	_tj=$(json_str "$_text")
	respond_json 200 "{\"ok\":true,\"data\":{\"name\":$_nj,\"path\":$_fj,\"size\":$_sj,\"text\":$_tj}}"
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

api_config_get() {
	_raw=""
	[ -f "$FSD_CONF" ] && _raw=$(cat "$FSD_CONF")
	_blocks=""
	_first=1
	for _b in $FSD_BLOCKS; do
		[ "$_first" -eq 1 ] || _blocks="$_blocks,"
		_first=0
		_blocks="$_blocks\"$_b\":$(json_str "$(block_get "$_b")")"
	done
	respond_begin "200 OK"
	printf '{"ok":true,"data":{"raw":%s,"blocks":{%s},"path":%s,"mtime":%s,"sha256":%s,"lines":%s}}' \
		"$(json_str "$_raw")" "$_blocks" "$(json_str "$FSD_CONF")" \
		"$(json_int_or_null "$(file_mtime "$FSD_CONF")")" "$(json_str "$(json_sha "$FSD_CONF")")" \
		"$(json_int_or_null "$(config_total_lines)")"
}

api_config_blocks() {
	_blocks=""
	_first=1
	for _b in $FSD_BLOCKS; do
		[ "$_first" -eq 1 ] || _blocks="$_blocks,"
		_first=0
		_blocks="$_blocks\"$_b\":$(json_str "$(block_get "$_b")")"
	done
	respond_json 200 "{\"ok\":true,\"data\":{$_blocks}}"
}

api_config_validate() {
	_f=$(api_tmp)
	cat "$FSD_BODY" >"$_f" 2>/dev/null
	_records=$(api_tmp)
	_vlog=$(api_tmp)
	run_static_validation "$_f" "$_records"
	_rt=0
	if [ "$(param runtime)" != "0" ]; then
		runtime_validate "$_f" "$_vlog" && _rt=1 || _rt=0
	fi
	_e=$(validation_error_count "$_records")
	_valid=false
	[ "$_e" -eq 0 ] && [ "$_rt" -ge 0 ] && _valid=true
	if [ "$(param runtime)" != "0" ] && [ "$_rt" -ne 1 ]; then
		_valid=false
	fi
	respond_json 200 "{\"ok\":true,\"data\":{\"valid\":$_valid,\"errors\":$(emit_records_filter "$_records" E),\"warnings\":$(emit_records_filter "$_records" W),\"runtime\":{\"requested\":$([ "$(param runtime)" != "0" ] && echo true || echo false),\"ok\":$([ "$_rt" -eq 1 ] && echo true || echo false),\"log\":$(json_str "$(config_test_summary "$_vlog")")}}}"
	rm -f "$_f" "$_records" "$_vlog"
}

api_config_apply() {
	_f=$(api_tmp)
	cat "$FSD_BODY" >"$_f" 2>/dev/null
	if [ ! -s "$_f" ]; then
		respond_error 400 "empty" "Пустая конфигурация"
		rm -f "$_f"
		return 0
	fi
	if apply_config_file "$_f" "apply" 1; then
		_svcj=$(service_summary_json)
		respond_json 200 "{\"ok\":true,\"data\":{\"backup\":\"$APPLY_BACKUP\",\"service\":$_svcj}}"
	else
		_ej=$(json_str "$APPLY_ERROR")
		_dj=$(json_str "$APPLY_DETAIL")
		respond_json 400 "{\"ok\":false,\"error\":{\"code\":\"config_invalid\",\"message\":$_ej,\"detail\":$_dj}}"
	fi
	rm -f "$_f"
}

api_config_block() {
	_name=$(param name)
	block_allowed "$_name" || { respond_error 400 "bad_block" "Неизвестный блок: $_name"; return 0; }
	_f=$(api_tmp)
	cat "$FSD_BODY" >"$_f" 2>/dev/null
	_new="$FSD_RUN/newconf.$$"
	block_render "$_name" "$_f" >"$_new"
	if [ "$(param restart)" = "0" ]; then
		_nr=0
	else
		_nr=1
	fi
	if apply_config_file "$_new" "block-$_name" "$_nr"; then
		_nj=$(json_str "$_name")
		_svcj=$(service_summary_json)
		respond_json 200 "{\"ok\":true,\"data\":{\"block\":$_nj,\"backup\":\"$APPLY_BACKUP\",\"service\":$_svcj}}"
	else
		_ej=$(json_str "$APPLY_ERROR")
		_dj=$(json_str "$APPLY_DETAIL")
		respond_json 400 "{\"ok\":false,\"error\":{\"code\":\"config_invalid\",\"message\":$_ej,\"detail\":$_dj}}"
	fi
	rm -f "$_f" "$_new"
}

# ---------------------------------------------------------------------------
# backups
# ---------------------------------------------------------------------------

api_backups() {
	respond_json 200 "{\"ok\":true,\"data\":{\"backups\":$(backup_list_json)}}"
}

api_backup_create() {
	_b=$(make_backup "manual" 2>/dev/null)
	if [ -z "$_b" ]; then
		respond_error 500 "backup" "Не удалось создать резервную копию"
		return 0
	fi
	respond_json 200 "{\"ok\":true,\"data\":{\"name\":$(json_str "$_b")}}"
}

api_backup_restore() {
	_name=$(form_param name "$FSD_BODY")
	[ -n "$_name" ] || _name=$(param name)
	_path=$(backup_path "$_name" 2>/dev/null) || { respond_error 400 "bad_name" "Некорректное имя архива"; return 0; }
	if restore_archive "$_path"; then
		_nj=$(json_str "$_name")
		_pj=$(json_str "${RESTORE_BACKUP:-}")
		_svcj=$(service_summary_json)
		respond_json 200 "{\"ok\":true,\"data\":{\"restored\":$_nj,\"pre_backup\":$_pj,\"service\":$_svcj}}"
	else
		_ej=$(json_str "$RESTORE_ERROR")
		_dj=$(json_str "${RESTORE_DETAIL:-}")
		respond_json 400 "{\"ok\":false,\"error\":{\"code\":\"restore\",\"message\":$_ej,\"detail\":$_dj}}"
	fi
}

api_backup_upload() {
	_name=$(param name)
	[ -n "$_name" ] || _name="upload-$(backup_stamp).tgz"
	backup_name_valid "$_name" || { respond_error 400 "bad_name" "Некорректное имя архива"; return 0; }
	_tmp="$FSD_RUN/upload.$$.tgz"
	cp "$FSD_BODY" "$_tmp" 2>/dev/null
	if [ ! -s "$_tmp" ]; then
		rm -f "$_tmp"
		respond_error 400 "empty" "Пустое тело запроса"
		return 0
	fi
	if ! tar tzf "$_tmp" >/dev/null 2>&1; then
		rm -f "$_tmp"
		respond_error 400 "bad_archive" "Файл не является tar.gz"
		return 0
	fi
	if restore_archive "$_tmp"; then
		_svcj=$(service_summary_json)
		respond_json 200 "{\"ok\":true,\"data\":{\"restored\":\"$_name\",\"service\":$_svcj}}"
	else
		_ej=$(json_str "$RESTORE_ERROR")
		_dj=$(json_str "${RESTORE_DETAIL:-}")
		respond_json 400 "{\"ok\":false,\"error\":{\"code\":\"restore\",\"message\":$_ej,\"detail\":$_dj}}"
	fi
	rm -f "$_tmp"
}

api_backup_download() {
	_name=$(param name)
	_path=$(backup_path "$_name" 2>/dev/null) || { respond_error 400 "bad_name" "Некорректное имя архива"; return 0; }
	[ -f "$_path" ] || { respond_error 404 "not_found" "Архив не найден"; return 0; }
	respond_file "$_path" "application/gzip"
}

api_backup_delete() {
	_name=$(form_param name "$FSD_BODY")
	[ -n "$_name" ] || _name=$(param name)
	delete_backup "$_name" || { respond_error 400 "bad_name" "Некорректное имя архива"; return 0; }
	respond_json 200 "{\"ok\":true,\"data\":null}"
}

# ---------------------------------------------------------------------------
# list files (lists/)
# ---------------------------------------------------------------------------

file_name_valid() {
	case "${1:-}" in
		''|*/*|*..*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	[ "${#1}" -le 128 ] && return 0
	return 1
}

api_files_list() {
	_dir="$FSD_LISTS"
	mkdir -p "$_dir" 2>/dev/null
	_out=$(api_tmp)
	if [ -d "$_dir" ]; then
		for _f in "$_dir"/*; do
			[ -f "$_f" ] || continue
			printf '%s\t%s\t%s\n' "$(basename "$_f")" "$(wc -c <"$_f" | tr -d ' ')" "$(file_mtime "$_f")" >>"$_out"
		done
	fi
	respond_begin "200 OK"
	printf '{"ok":true,"data":{"dir":%s,"files":[' "$(json_str "$_dir")"
	_first=1
	while IFS='	' read -r _name _size _mt; do
		[ -n "$_name" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '{"name":%s,"size":%s,"mtime":%s}' "$(json_str "$_name")" "$(json_int_or_null "$_size")" "$(json_int_or_null "$_mt")"
	done <"$_out"
	printf ']}}'
	rm -f "$_out"
}

api_files_read() {
	_name=$(param name)
	file_name_valid "$_name" || { respond_error 400 "bad_name" "Некорректное имя файла"; return 0; }
	_f="$FSD_LISTS/$_name"
	[ -f "$_f" ] || { respond_error 404 "not_found" "Файл не найден"; return 0; }
	_size=$(wc -c <"$_f" | tr -d ' ')
	if [ "$_size" -gt 1048576 ]; then
		respond_error 413 "too_large" "Файл больше 1 МиБ"
		return 0
	fi
	_nj=$(json_str "$_name")
	_sj=$(json_int_or_null "$_size")
	_cj=$(json_str_file "$_f")
	respond_json 200 "{\"ok\":true,\"data\":{\"name\":$_nj,\"size\":$_sj,\"content\":$_cj}}"
}

api_files_write() {
	_name=$(param name)
	file_name_valid "$_name" || { respond_error 400 "bad_name" "Некорректное имя файла"; return 0; }
	mkdir -p "$FSD_LISTS" 2>/dev/null
	_f="$FSD_LISTS/$_name"
	_size=$(wc -c <"$FSD_BODY" | tr -d ' ')
	if [ "$_size" -gt 1048576 ]; then
		respond_error 413 "too_large" "Содержимое больше 1 МиБ"
		return 0
	fi
	# Back up before changing anything referenced by the configuration.
	_b=""
	if grep -q "$_name" "$FSD_CONF" 2>/dev/null; then
		_b=$(make_backup "pre-file-$_name" 2>/dev/null || true)
	fi
	_tmp="$_f.tmp.$$"
	cp "$FSD_BODY" "$_tmp" || { respond_error 500 "write" "Не удалось записать файл"; return 0; }
	chmod 600 "$_tmp" 2>/dev/null || true
	mv "$_tmp" "$_f" || { rm -f "$_tmp"; respond_error 500 "write" "Не удалось записать файл"; return 0; }
	_nj=$(json_str "$_name")
	_bj=$(json_str "$_b")
	_sj=$(json_int_or_null "$_size")
	respond_json 200 "{\"ok\":true,\"data\":{\"name\":$_nj,\"size\":$_sj,\"backup\":$_bj}}"
}

api_files_delete() {
	_name=$(param name)
	file_name_valid "$_name" || { respond_error 400 "bad_name" "Некорректное имя файла"; return 0; }
	_f="$FSD_LISTS/$_name"
	[ -f "$_f" ] || { respond_error 404 "not_found" "Файл не найден"; return 0; }
	_b=""
	if grep -q "$_name" "$FSD_CONF" 2>/dev/null; then
		_b=$(make_backup "pre-delete-$_name" 2>/dev/null || true)
	fi
	rm -f "$_f"
	_nj=$(json_str "$_name")
	_bj=$(json_str "$_b")
	respond_json 200 "{\"ok\":true,\"data\":{\"deleted\":$_nj,\"backup\":$_bj}}"
}

# ---------------------------------------------------------------------------
# core bridge proxies
# ---------------------------------------------------------------------------

proxy_core() {
	_method=$1
	_path=$2
	_out=$(api_tmp)
	if ! core_fetch "$_method" "$_path" "" "$_out"; then
		respond_error 503 "bridge" "${CORE_API_ERROR:-stats bridge is unavailable}"
		rm -f "$_out"
		return 0
	fi
	_body=$(cat "$_out")
	rm -f "$_out"
	if [ -z "$_body" ]; then
		_body=null
	fi
	respond_json 200 "{\"ok\":true,\"data\":$_body}"
}

api_stats_hourly() {
	_h=$(raw_param past_hours)
	is_uint "$_h" || _h=24
	proxy_core GET "/api/stats/hourly-query-count?past_hours=$_h"
}

api_stats_daily() {
	_d=$(raw_param past_days)
	is_uint "$_d" || _d=30
	proxy_core GET "/api/stats/daily-query-count?past_days=$_d"
}

api_top_domain() {
	_c=$(raw_param count)
	is_uint "$_c" || _c=10
	_b=$(raw_param is_blocked)
	_q="?count=$_c"
	[ "$_b" = "true" ] && _q="$_q&is_blocked=true"
	proxy_core GET "/api/stats/top/domain$_q"
}

api_top_client() {
	_c=$(raw_param count)
	is_uint "$_c" || _c=10
	proxy_core GET "/api/stats/top/client?count=$_c"
}

api_cache_flush() {
	_out=$(api_tmp)
	if core_fetch PUT /api/cache/flush "" "$_out"; then
		respond_json 200 "{\"ok\":true,\"data\":{\"flushed\":true}}"
	else
		respond_error 503 "bridge" "${CORE_API_ERROR:-stats bridge is unavailable}"
	fi
	rm -f "$_out"
}

api_querylog() {
	_q=""
	_add() {
		_v=$(raw_param "$1")
		[ -n "$_v" ] && _q="$_q&$1=$_v"
	}
	_add page_num
	_add page_size
	_add order
	_add id
	_add cursor
	_add cursor_direction
	_add total_count
	_add domain
	_add domain_filter_mode
	_add domain_type
	_add client
	_add domain_group
	_add reply_code
	_add is_blocked
	_add is_cached
	_add timestamp_after
	_add timestamp_before
	[ -n "$_q" ] || _q="?page_size=50"
	case "$_q" in
		"&"*) _q="?${_q#&}" ;;
	esac
	proxy_core GET "/api/domain$_q"
}
