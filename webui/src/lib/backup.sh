#!/bin/sh
# forksmartdns WebUI — configuration backups, restore and retention.

backup_dir_ensure() {
	[ -d "$FSD_BACKUPS" ] || { mkdir -p "$FSD_BACKUPS" 2>/dev/null && chmod 700 "$FSD_BACKUPS" 2>/dev/null; }
	[ -d "$FSD_BACKUPS" ] && [ -w "$FSD_BACKUPS" ]
}

backup_name_valid() {
	case "${1:-}" in
		''|*/*|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
		*.tgz|*.tar.gz) return 0 ;;
		*) return 1 ;;
	esac
}

backup_path() {
	[ -n "${1:-}" ] || return 1
	backup_name_valid "$1" || return 1
	printf '%s/%s' "$FSD_BACKUPS" "$1"
}

backup_stamp() { date '+%Y%m%d-%H%M%S' 2>/dev/null || echo 0; }

file_mtime() {
	stat -c %Y "$1" 2>/dev/null || date -r "$1" '+%s' 2>/dev/null || echo 0
}

make_backup() {
	_reason=$(printf '%s' "${1:-manual}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
	backup_dir_ensure || return 1
	_stamp=$(backup_stamp)
	_name="$_stamp-$_reason.tgz"
	_path="$FSD_BACKUPS/$_name"
	[ -e "$_path" ] && _name="$_stamp-$_reason-$$.tgz" && _path="$FSD_BACKUPS/$_name"

	_stage="$FSD_RUN/backup.$$"
	rm -rf "$_stage"
	mkdir -p "$_stage" || return 1
	{
		echo "version=$FSD_VERSION"
		echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
		echo "reason=$_reason"
		echo "core=$FSD_CORE_KIND"
	} >"$_stage/MANIFEST"
	if [ -f "$FSD_CONF" ]; then
		echo "config_sha256=$(sha256sum "$FSD_CONF" | cut -c1-64)" >>"$_stage/MANIFEST"
	fi

	_entries="MANIFEST"
	for _f in forksmartdns.conf instance.env auth.conf setup-token lighttpd.conf; do
		if [ -e "$FSD_ETC/$_f" ]; then
			cp -p "$FSD_ETC/$_f" "$_stage/$_f" 2>/dev/null || true
			_entries="$_entries $_f"
		fi
	done
	if [ -d "$FSD_LISTS" ]; then
		cp -R "$FSD_LISTS" "$_stage/lists" 2>/dev/null || true
		_entries="$_entries lists"
	fi

	(
		cd "$_stage" || exit 1
		tar czf "$_path" $_entries 2>/dev/null
	)
	_rc=$?
	rm -rf "$_stage"
	[ "$_rc" -eq 0 ] || return 1
	chmod 600 "$_path" 2>/dev/null || true
	backup_retention
	printf '%s' "$_name"
}

backup_retention() {
	# Keep the most recent 30 archives.
	_n=$(ls -1 "$FSD_BACKUPS"/*.tgz 2>/dev/null | wc -l | tr -d ' ')
	[ "$_n" -gt 30 ] || return 0
	ls -1t "$FSD_BACKUPS"/*.tgz 2>/dev/null | tail -n $((_n - 30)) | while read -r _old; do
		rm -f "$_old"
	done
}

backup_reason() {
	# backup_reason FILE -> reason from MANIFEST or from filename
	_f=$1
	_r=$(tar xzf "$_f" -O MANIFEST 2>/dev/null | sed -n 's/^reason=//p' | head -n 1)
	[ -n "$_r" ] || _r=$(basename "$_f" .tgz | cut -d- -f3-)
	printf '%s' "$_r"
}

backup_list_json() {
	backup_dir_ensure || { printf '[]'; return 0; }
	printf '['
	_first=1
	for _f in $(ls -1t "$FSD_BACKUPS"/*.tgz 2>/dev/null); do
		[ -f "$_f" ] || continue
		_name=$(basename "$_f")
		_size=$(wc -c <"$_f" | tr -d ' ')
		_mtime=$(file_mtime "$_f")
		_reason=$(backup_reason "$_f")
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '{"name":%s,"size":%s,"mtime":%s,"reason":%s}' \
			"$(json_str "$_name")" "$(json_int_or_null "$_size")" "$(json_int_or_null "$_mtime")" "$(json_str "$_reason")"
	done
	printf ']'
}

restore_archive() {
	# restore_archive PATH -> 0 ok, sets RESTORE_ERROR / RESTORE_DETAIL
	_arc=$1
	RESTORE_ERROR=""
	RESTORE_DETAIL=""
	_name=$(basename "$_arc")
	backup_name_valid "$_name" || { RESTORE_ERROR="Некорректное имя архива"; return 1; }
	[ -f "$_arc" ] || { RESTORE_ERROR="Архив не найден"; return 1; }

	_tmp="$FSD_RUN/restore.$$"
	rm -rf "$_tmp"
	mkdir -p "$_tmp" || { RESTORE_ERROR="Не удалось создать временный каталог"; return 1; }
	if ! tar xzf "$_arc" -C "$_tmp" 2>/dev/null; then
		rm -rf "$_tmp"
		RESTORE_ERROR="Архив повреждён или это не tar.gz"
		return 1
	fi
	if [ ! -f "$_tmp/forksmartdns.conf" ]; then
		rm -rf "$_tmp"
		RESTORE_ERROR="В архиве нет forksmartdns.conf"
		return 1
	fi

	# Validate the archived configuration before touching the live one.
	_records="$_tmp/records"
	run_static_validation "$_tmp/forksmartdns.conf" "$_records"
	if [ "$(validation_error_count "$_records")" -gt 0 ]; then
		RESTORE_ERROR="Конфигурация из архива не прошла проверку"
		RESTORE_DETAIL=$(cat "$_records")
		rm -rf "$_tmp"
		return 1
	fi

	_pre=$(make_backup "pre-restore" 2>/dev/null || true)

	# Lists first, because the configuration references them.
	if [ -d "$_tmp/lists" ]; then
		mkdir -p "$FSD_LISTS"
		cp -R "$_tmp/lists/." "$FSD_LISTS/" 2>/dev/null || true
		chmod -R u+rwX,go-rwx "$FSD_LISTS" 2>/dev/null || true
	fi

	if ! apply_config_file "$_tmp/forksmartdns.conf" "restore" 1; then
		# Put lists back from the pre-restore backup.
		if [ -n "$_pre" ] && [ -f "$FSD_BACKUPS/$_pre" ]; then
			_ptmp="$FSD_RUN/restore-pre.$$"
			rm -rf "$_ptmp"
			mkdir -p "$_ptmp"
			tar xzf "$FSD_BACKUPS/$_pre" -C "$_ptmp" 2>/dev/null
			if [ -d "$_ptmp/lists" ]; then
				rm -rf "$FSD_LISTS"
				mkdir -p "$FSD_LISTS"
				cp -R "$_ptmp/lists/." "$FSD_LISTS/" 2>/dev/null || true
			fi
			rm -rf "$_ptmp"
		fi
		RESTORE_ERROR="Не удалось применить конфигурацию из архива (выполнен откат)"
		RESTORE_DETAIL=${APPLY_DETAIL:-}
		rm -rf "$_tmp"
		return 1
	fi

	rm -rf "$_tmp"
	RESTORE_BACKUP=$_pre
	return 0
}

delete_backup() {
	_name=$1
	backup_name_valid "$_name" || return 1
	rm -f "$FSD_BACKUPS/$_name"
}
