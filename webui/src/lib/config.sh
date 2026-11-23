#!/bin/sh
# forksmartdns WebUI — configuration model, validation and safe apply.

FSD_BLOCKS="globals listeners upstreams groups domains lists clients ipset extra"

config_exists() { [ -f "$FSD_CONF" ]; }

config_read() { cat "$FSD_CONF" 2>/dev/null; }

config_total_lines() {
	[ -r "$FSD_CONF" ] && wc -l <"$FSD_CONF" | tr -d ' ' || echo 0
}

block_allowed() {
	for _b in $FSD_BLOCKS; do
		[ "$_b" = "$1" ] && return 0
	done
	return 1
}

block_get() {
	# block_get NAME -> content between "# >>> fsd:NAME" and "# <<< fsd:NAME"
	[ -n "$1" ] && [ -r "$FSD_CONF" ] || return 0
	awk -v name="$1" '
		$0 ~ ("^#[ \t]*>>>[ \t]*fsd:" name "$") { inside = 1; next }
		$0 ~ ("^#[ \t]*<<<[ \t]*fsd:" name "$") { inside = 0; next }
		inside { print }
	' "$FSD_CONF"
}

block_render() {
	# block_render NAME BLOCKFILE -> full config on stdout
	awk -v name="$1" -v blockfile="$2" '
		BEGIN {
			n = 0
			while ((getline line < blockfile) > 0) {
				block[++n] = line
			}
			close(blockfile)
			done = 0
			inside = 0
		}
		$0 ~ ("^#[ \t]*>>>[ \t]*fsd:" name "$") {
			print
			for (i = 1; i <= n; i++) print block[i]
			inside = 1
			done = 1
			next
		}
		$0 ~ ("^#[ \t]*<<<[ \t]*fsd:" name "$") {
			if (inside) {
				print
				inside = 0
			}
			next
		}
		inside { next }
		{ print }
		END {
			if (!done) {
				print ""
				print "# >>> fsd:" name
				for (i = 1; i <= n; i++) print block[i]
				print "# <<< fsd:" name
			}
		}
	' "$FSD_CONF"
}

# run_static_validation FILE OUTFILE
run_static_validation() {
	_file=$1
	_out=$2
	: >"$_out"
	FSD_SCHEMA_DIR="$FSD_WWW" awk -v DIR="$FSD_WWW" -f "$FSD_LIBDIR/validate.awk" "$_file" >"$_out" 2>/dev/null

	# Check referenced files (warnings only; paths may be created later).
	awk '
		/^[ \t]*(block-file|hosts-file|ca-file|resolv-file|dnsmasq-lease-file|odhcpd-lease-file)[ \t]+/ { print NR " " $2 }
		/^[ \t]*(domain-set|ip-set)[ \t]/ {
			for (i = 2; i <= NF; i++) {
				if ($i == "-file" || $i == "-f") print NR " " $(i + 1)
			}
		}
	' "$_file" | while read -r _ln _path; do
		[ -n "$_path" ] || continue
		case "$_path" in
			*'*'*|'$'*) continue ;;
		esac
		if [ ! -e "$_path" ]; then
			printf 'W\t%s\t%s\n' "$_ln" "файл не найден: $_path (будет ошибкой при загрузке ядром)" >>"$_out"
		fi
	done

	if ! grep -q '^# >>> fsd:globals' "$_file" 2>/dev/null; then
		printf 'W\t0\t%s\n' "в конфигурации нет управляемых блоков fsd: — структурированные разделы будут добавлены в конец файла" >>"$_out"
	fi
}

# emit_validation_json OUTFILE -> JSON array
emit_validation_json() {
	_out=$1
	printf '['
	_first=1
	while IFS='	' read -r _sev _ln _msg; do
		[ -n "$_sev" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		case "$_sev" in
			E) _sev_name=error ;;
			W) _sev_name=warning ;;
			*) _sev_name=info ;;
		esac
		printf '{"severity":%s,"line":%s,"message":%s}' \
			"$(json_str "$_sev_name")" "$(json_int_or_null "$_ln")" "$(json_str "$_msg")"
	done <"$_out"
	printf ']'
}

validation_error_count() {
	awk -F '	' '$1 == "E" { n++ } END { print n + 0 }' "$1" 2>/dev/null
}

validation_warning_count() {
	awk -F '	' '$1 == "W" { n++ } END { print n + 0 }' "$1" 2>/dev/null
}

# runtime_validate FILE OUTLOG -> 0 valid, 1 invalid (OUTLOG has details)
runtime_validate() {
	_file=$1
	_log=$2
	_tmp="$FSD_RUN/validate.$$"
	rm -rf "$_tmp"
	mkdir -p "$_tmp" || return 1
	_cfg="$_tmp/check.conf"
	: >"$_log"

	awk '
		BEGIN { skip = 0 }
		/^[ \t]*#/ { print; next }
		/^[ \t]*(bind|bind-tcp|bind-tls|bind-https|bind-http)[ \t]/ { next }
		/^[ \t]*ui-enable[ \t]/ { next }
		/^[ \t]*ui-exec[ \t]/ { next }
		/^[ \t]*log-file[ \t]/ { next }
		/^[ \t]*audit-file[ \t]/ { next }
		/^[ \t]*cache-file[ \t]/ { next }
		/^[ \t]*data-dir[ \t]/ { next }
		/^[ \t]*restart-on-crash[ \t]/ { next }
		/^[ \t]*no-daemon[ \t]/ { next }
		/^[ \t]*no-pidfile[ \t]/ { next }
		/^[ \t]*user[ \t]/ { next }
		/^[ \t]*log-syslog[ \t]/ { next }
		/^[ \t]*audit-syslog[ \t]/ { next }
		{ print }
	' "$_file" >"$_cfg"

	cat >>"$_cfg" <<EOF
ui-enable no
log-file $_tmp/check.log
log-console yes
log-size 64k
log-num 1
audit-enable no
cache-file $_tmp/check.cache
data-dir $_tmp/data
restart-on-crash no
bind 127.0.0.1:0
EOF

	mkdir -p "$_tmp/data"
	(
		cd "$_tmp" || exit 1
		"$FSD_CORE_BIN" -f -c "$_cfg" -p - >"$_log" 2>&1 &
		echo $! >"$_tmp/pid"
	)
	_pid=$(cat "$_tmp/pid" 2>/dev/null)
	if [ -z "$_pid" ]; then
		echo "ядро не запустилось" >>"$_log"
		rm -rf "$_tmp"
		return 1
	fi
	_alive=0
	_i=0
	while [ "$_i" -lt 3 ]; do
		pid_alive "$_pid" && _alive=1
		sleep 1
		_i=$((_i + 1))
	done
	if pid_alive "$_pid"; then
		kill "$_pid" 2>/dev/null
		sleep 1
		pid_alive "$_pid" && kill -9 "$_pid" 2>/dev/null
	fi
	wait "$_pid" 2>/dev/null

	if grep -qiE 'process config failed|unsupported config|invalid parameter' "$_log" 2>/dev/null; then
		rm -rf "$_tmp" 2>/dev/null
		return 1
	fi
	# The process may be gone because the platform does not support kill -0/TERM
	# for detached processes; the startup banner is a reliable success marker.
	if [ "$_alive" -eq 1 ] || grep -qiE 'starting\.\.\.|startup|listen on' "$_log" 2>/dev/null; then
		rm -rf "$_tmp" 2>/dev/null
		return 0
	fi
	rm -rf "$_tmp" 2>/dev/null
	return 1
}

config_test_summary() {
	# Human readable tail of a validation log for API errors.
	_l=$1
	[ -r "$_l" ] || return 0
	tail -n 25 "$_l" | sed 's/[[:cntrl:]]//g'
}

# write_config_atomic FILE_FROM_TMP
write_config_atomic() {
	_src=$1
	_tmp="$FSD_CONF.tmp.$$"
	cp "$_src" "$_tmp" || return 1
	chmod 600 "$_tmp" 2>/dev/null || true
	mv "$_tmp" "$FSD_CONF" || { rm -f "$_tmp"; return 1; }
	return 0
}

# apply_config_file NEWFILE REASON RESTART -> 0 ok; sets APPLY_ERROR / APPLY_DETAIL
apply_config_file() {
	_new=$1
	_reason=${2:-apply}
	_restart=${3:-1}
	APPLY_ERROR=""
	APPLY_DETAIL=""
	_work="$FSD_RUN/apply.$$"
	mkdir -p "$_work" || { APPLY_ERROR="Внутренняя ошибка: каталог run недоступен"; return 1; }
	_records="$_work/records"
	_vlog="$_work/validator.log"

	run_static_validation "$_new" "$_records"
	if [ "$(validation_error_count "$_records")" -gt 0 ]; then
		APPLY_ERROR="Конфигурация не прошла статическую проверку"
		APPLY_DETAIL=$(cat "$_records")
		rm -rf "$_work"
		return 1
	fi

	if ! runtime_validate "$_new" "$_vlog"; then
		APPLY_ERROR="Ядро отвергло конфигурацию при пробном запуске"
		APPLY_DETAIL=$(config_test_summary "$_vlog")
		rm -rf "$_work"
		return 1
	fi

	_bak=$(make_backup "pre-$_reason" 2>/dev/null || true)
	_old="$FSD_RUN/apply.old.$$"
	if [ -f "$FSD_CONF" ]; then cp "$FSD_CONF" "$_old"; fi

	if ! write_config_atomic "$_new"; then
		APPLY_ERROR="Не удалось записать конфигурацию"
		rm -rf "$_work"
		return 1
	fi

	if [ "$_restart" = "1" ] && service_is_running; then
		if ! service_restart >/dev/null 2>&1; then
			# rollback
			[ -f "$_old" ] && cp "$_old" "$FSD_CONF"
			service_restart >/dev/null 2>&1 || true
			APPLY_ERROR="Служба не перезапустилась с новой конфигурацией; выполнен откат"
			APPLY_DETAIL=$(tail -n 30 "$FSD_CORE_LOG" 2>/dev/null)
			rm -rf "$_work"
			return 1
		fi
		if ! service_wait_ready 25; then
			[ -f "$_old" ] && cp "$_old" "$FSD_CONF"
			service_restart >/dev/null 2>&1 || true
			APPLY_ERROR="Служба не стала готовой после применения; выполнен откат"
			APPLY_DETAIL=$(tail -n 30 "$FSD_CORE_LOG" 2>/dev/null)
			rm -rf "$_work"
			return 1
		fi
	fi

	rm -rf "$_work"
	rm -f "$_old" 2>/dev/null || true
	APPLY_BACKUP="$_bak"
	return 0
}

config_schema_path() { printf '%s/schema.tsv' "$FSD_WWW"; }
