#!/usr/bin/env bash
# tests/vm/measure.sh: idle resource measurement. Runs INSIDE the test VM (copied there by baseline.sh).
# Prints one key=value per line. Uses sudo for powertop (passwordless inside the test VM only).
set -euo pipefail

SETTLE="${SETTLE:-120}"
WINDOW="${WINDOW:-300}"
QUIET="${QUIET:-1}"

# Quiet mode: pause the VM's background jobs (update checks, snap refreshes, the sysstat collector)
# for this boot only, so they don't swamp small differences. The snapshot itself is untouched.
if ((QUIET)); then
	sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
		unattended-upgrades.service fwupd-refresh.timer motd-news.timer anacron.timer sysstat-collect.timer \
		snapd.socket snapd.service man-db.timer 2>/dev/null || true
	pkill -x update-notifier 2>/dev/null || true
	pkill -f unattended-upgrade 2>/dev/null || true
fi

# A measurement is meaningless if GNOME has switched all user extensions off (it does that after a
# shell crash). Refuse rather than report a bare desktop as a result.
if [[ $(gsettings get org.gnome.shell disable-user-extensions) == true ]]; then
	echo "error=disable-user-extensions is true: user extensions are not running" >&2
	exit 1
fi

pid=$(pgrep -u "$(id -u)" -x gnome-shell | head -1) || {
	echo "error=gnome-shell not running" >&2
	exit 1
}
hz=$(getconf CLK_TCK)
# An unlocked, awake desktop on both sides: a measurement runs longer than a 5-minute idle delay, and
# a locked screen switches user extensions off (Ubuntu Ostrich locks after 5 minutes; the original
# setup never did), so one side would be measuring a lock screen. This boot only: the snapshot is
# restored for every measurement.
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true

cpu_ticks() { awk '{print $14 + $15}' "/proc/$pid/stat"; }
# Sum of voluntary + involuntary context switches over all gnome-shell threads: how often it wakes.
ctx_switches() { cat /proc/"$pid"/task/*/status 2>/dev/null | awk '/^(non)?voluntary_ctxt_switches/ { n += $2 } END { print n }'; }

sleep "$SETTLE"

# A private dir: in sticky /tmp, root may not write into a file the user pre-created.
csvdir=$(mktemp -d)
csv="$csvdir/powertop.csv"
sudo powertop --time="$WINDOW" --csv="$csv" >/dev/null 2>&1 &
pt=$!
t0=$(cpu_ticks)
c0=$(ctx_switches)
sleep "$WINDOW"
t1=$(cpu_ticks)
c1=$(ctx_switches)
wait "$pt" || true

awk -v d=$((t1 - t0)) -v hz="$hz" -v w="$WINDOW" 'BEGIN { printf "shell_cpu_pct=%.3f\n", 100 * d / hz / w }'
awk -v d=$((c1 - c0)) -v w="$WINDOW" 'BEGIN { printf "shell_ctxsw_per_s=%.2f\n", d / w }'
awk '/^VmRSS:/ { printf "shell_rss_mb=%.1f\n", $2 / 1024 }' "/proc/$pid/status"
awk '/^Pss:/ { printf "shell_pss_mb=%.1f\n", $2 / 1024 }' "/proc/$pid/smaps_rollup"
awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "mem_used_mb=%.0f\n", (t - a) / 1024 }' /proc/meminfo

# powertop CSV: "System:  236.2 wakeup/s" in the summary, and our gnome-shell's row
# ("Usage;Wakeups/s;...;Process;[PID n] /usr/bin/gnome-shell ...") in the consumer list.
sudo cat "$csv" | awk -F';' -v pid="$pid" '
	!w && match($0, /System: *[0-9.]+ wakeup\/s/) { split(substr($0, RSTART, RLENGTH), a, " "); w = a[2] }
	!s && index($0, "[PID " pid "]") && /Process/ { s = $2; gsub(/ /, "", s) }
	END { printf "wakeups_per_s=%s\nshell_wakeups_per_s=%s\n", (w == "" ? "na" : w), (s == "" ? "na" : s) }'
sudo rm -rf "$csvdir"

echo "processes=$(ps -e --no-headers | wc -l)"
echo "system_services=$(systemctl list-units --type=service --state=running --no-legend | wc -l)"
echo "user_services=$(systemctl --user list-units --type=service --state=running --no-legend | wc -l)"
echo "squashfs_mounts=$(findmnt -t squashfs -n | wc -l)"
# The shell's extension D-Bus API can briefly answer with an empty list; retry before trusting 0.
for _ in 1 2 3; do
	n=$(gnome-extensions list --enabled 2>/dev/null | wc -l)
	((n > 0)) && break
	sleep 5
done
echo "extensions_enabled=$n"
active=0
for u in $(gnome-extensions list --enabled 2>/dev/null); do
	[[ $(gnome-extensions info "$u" 2>/dev/null | sed -n 's/^ *State: //p') == ACTIVE ]] && active=$((active + 1))
done
echo "extensions_active=$active"
echo "screen_locked=$(gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q true && echo yes || echo no)"
systemd-analyze 2>/dev/null | awk '/^Startup finished/ { gsub(/s$/, "", $NF); print "boot_s=" $NF; exit }'
