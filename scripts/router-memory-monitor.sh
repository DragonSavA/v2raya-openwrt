#!/bin/sh

set -eu

interval="${1:-60}"
output="${2:-/tmp/v2raya-memory.csv}"

case "$interval" in
	''|*[!0-9]*)
		echo "Interval must be a positive number of seconds" >&2
		exit 2
		;;
	0)
		echo "Interval must be greater than zero" >&2
		exit 2
		;;
esac

if [ ! -f "$output" ]; then
	echo 'timestamp,mem_available_kb,process,pid,rss_kb,hwm_kb,vmsize_kb,threads' > "$output"
fi

status_value() {
	awk -v field="$2" '$1 == field ":" { print $2; found=1; exit } END { if (!found) print 0 }' "/proc/$1/status"
}

while :; do
	timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	mem_available="$(awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) print 0 }' /proc/meminfo)"

	for process in v2raya xray; do
		pids="$(pidof "$process" 2>/dev/null || true)"
		if [ -z "$pids" ]; then
			echo "$timestamp,$mem_available,$process,0,0,0,0,0" >> "$output"
			continue
		fi

		for pid in $pids; do
			[ -r "/proc/$pid/status" ] || continue
			rss="$(status_value "$pid" VmRSS)"
			hwm="$(status_value "$pid" VmHWM)"
			vmsize="$(status_value "$pid" VmSize)"
			threads="$(status_value "$pid" Threads)"
			echo "$timestamp,$mem_available,$process,$pid,$rss,$hwm,$vmsize,$threads" >> "$output"
		done
	done

	sleep "$interval"
done
