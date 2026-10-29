#!/system/bin/sh
# OneLineage host-side health guard.
#
# The guest shares the host's binder namespace, so a broken media handover can
# turn into a userspace CPU/binder storm. Samsung's software watchdog panics the
# kernel when watchdogd has not run for ~100 s. This guard is deliberately tiny
# and lives in the host mount namespace: it samples the log tail, looks for
# watchdog warnings, and rolls back to One UI before the panic deadline.
#
# It is started by switch_to_lineage.sh after the takeover daemon is spawned.
STAGE="/data/local/tmp/lineage_stage"
LOG="$STAGE/guest_guard.log"
FLAG="$STAGE/guard_triggered"
STOP="$STAGE/stop_guard"
UI_READY="$STAGE/ui_ready"

BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
LOGCAT=/system/bin/logcat
[ -x "$LOGCAT" ] || LOGCAT=logcat
DMESG=/system/bin/dmesg
[ -x "$DMESG" ] || DMESG=dmesg

# Keep the guard itself on CPU 0 with the host watchdog path. It is mostly
# sleeping, so this costs nothing and keeps its samples responsive under load.
taskset -p 1 $$ 2>/dev/null || $BB taskset -p 1 $$ 2>/dev/null || true

say() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

rollback() {
    [ -f "$FLAG" ] && exit 0
    say "ROLLBACK: $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" > "$FLAG"
    sync 2>/dev/null || true
    /system/bin/sh "$STAGE/return_to_oneui.sh" >> "$LOG" 2>&1
    exit 0
}

# Keep watchdogd/logd/adbd/imsd/netd on CPU 0 and watchdogd at RT priority.
# switch_to_lineage.sh does this once before the guest starts; init can restart
# adbd/imsd later, so the guard re-applies it periodically.
protect_host() {
    NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [ -n "$NCPU" ] || NCPU=1
    [ "$NCPU" -gt 1 ] || return 0
    for p in watchdogd logd adbd imsd netd; do
        pid=$(pidof "$p" 2>/dev/null | awk '{print $1}')
        [ -n "$pid" ] || continue
        taskset -p 1 "$pid" 2>/dev/null || $BB taskset -p 1 "$pid" 2>/dev/null || true
        renice -n -20 "$pid" 2>/dev/null || $BB renice -n -20 "$pid" 2>/dev/null || true
        if [ "$p" = "watchdogd" ]; then
            chrt -f -p 10 "$pid" 2>/dev/null || $BB chrt -f -p 10 "$pid" 2>/dev/null || true
        fi
    done
}

# Count matching lines in the most recent logcat window. This intentionally
# looks at saturation instead of a cumulative count: when the guest is spinning,
# the tail of every buffer is made of these lines. Three consecutive samples
# (about 6 s) trigger the rollback.
storm_count() {
    $LOGCAT -b all -d -t 2000 2>/dev/null | \
        grep -cE 'MediaCodecList|codecHandlesFormat|AString: ctor got NULL'
}

say "guard started (pid $$)"
START=$(date +%s)
protect_host
BAD=0
TICK=0

while true; do
    sleep 2
    [ -f "$STOP" ] && { say "stop flag seen"; exit 0; }
    [ -f "$FLAG" ] && exit 0

    TICK=$((TICK + 1))
    if [ $((TICK % 5)) -eq 0 ]; then
        protect_host
    fi

    if $DMESG 2>/dev/null | tail -n 200 | \
        grep -qiE 'watchdog: BUG|watchdog timer expired|watchdog did not stop|softdog: .*failed|BUG: soft lockup'; then
        rollback "host watchdog/soft-lockup warning in dmesg"
    fi

    STORM=$(storm_count)
    [ -n "$STORM" ] || STORM=0
    if [ "$STORM" -gt 900 ]; then
        BAD=$((BAD + 1))
    else
        BAD=0
    fi
    if [ "$BAD" -ge 3 ]; then
        rollback "media codec storm (${STORM}/2000 recent log lines, 3 samples)"
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [ "$ELAPSED" -gt 75 ] && ! pidof system_server >/dev/null 2>&1; then
        rollback "guest system_server is not running after ${ELAPSED}s"
    fi
    if [ "$ELAPSED" -gt 85 ] && [ ! -f "$UI_READY" ]; then
        rollback "guest UI not ready after ${ELAPSED}s"
    fi

    if [ $((TICK % 15)) -eq 0 ]; then
        if [ -f "$UI_READY" ]; then
            say "alive: ${ELAPSED}s, storm=${STORM}, ui=ready"
        else
            say "alive: ${ELAPSED}s, storm=${STORM}, ui=booting"
        fi
    fi
done
