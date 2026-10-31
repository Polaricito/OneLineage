#!/system/bin/sh
# OneLineage host-side health guard.
#
# The guest shares the host's binder namespace, so a broken media handover can
# turn into a userspace CPU/binder storm. Samsung's software watchdog panics the
# kernel when watchdogd has not run for ~100 s. This guard is deliberately tiny
# and lives in the host mount namespace: it samples the log tail, looks for
# watchdog warnings, and rolls back to One UI before the panic deadline.
#
# It is started by switch_to_lineage.sh before the takeover daemon.
STAGE="/data/local/tmp/lineage_stage"
LOG="$STAGE/guest_guard.log"
FLAG="$STAGE/guard_triggered"
STOP="$STAGE/stop_guard"
UI_READY="$STAGE/ui_ready"
ROOTFS="$STAGE/rootfs"

BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
LOGCAT=/system/bin/logcat
[ -x "$LOGCAT" ] || LOGCAT=logcat
DMESG=/system/bin/dmesg
[ -x "$DMESG" ] || DMESG=dmesg

# Keep the guard itself on CPU 0 with the host watchdog path. It is mostly
# sleeping, so this costs nothing and keeps its samples responsive under load.
$BB taskset -p 1 $$ 2>/dev/null || taskset -p 1 $$ 2>/dev/null || true

# Idempotently re-assert the headless wake lock. switch_to_lineage.sh takes it
# before stopping One UI, but the guard is the component that lives for the
# whole session; re-taking it here means a takeover launched without the
# orchestrator still cannot suspend the device mid-boot. Check first: writing
# the name twice registers two wakeup sources and the single unlock in
# return_to_oneui.sh would leave one behind.
if [ -w /sys/power/wake_lock ]; then
    if ! $BB grep -q onelineage_takeover /sys/power/wake_lock 2>/dev/null; then
        echo "onelineage_takeover" > /sys/power/wake_lock 2>/dev/null || true
    fi
fi

say() {
    echo "$($BB date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

rollback() {
    [ -f "$FLAG" ] && exit 0
    say "ROLLBACK: $*"
    echo "$($BB date '+%Y-%m-%d %H:%M:%S') $*" > "$FLAG"
    sync 2>/dev/null || true
    # return_to_oneui.sh handles the final "host never came back" reboot.
    /system/bin/sh "$STAGE/return_to_oneui.sh" >> "$LOG" 2>&1
    exit 0
}

# A system_server is the guest's only if it runs in the guest mount namespace.
# /proc/<pid>/root reads "/" for every process after pivot_root, so the old
# root-link test never matched and the guard rolled back a healthy boot.
# master_inner.sh writes the namespace to $STAGE/guest_mnt_ns; the loop source
# written by master_prepare.sh catches children in private mount namespaces.
guest_system_server() {
    want=$($BB cat "$STAGE/guest_mnt_ns" 2>/dev/null)
    src=$($BB cat "$STAGE/guest_root_src" 2>/dev/null)
    for pid in $($BB pidof system_server 2>/dev/null); do
        if [ -n "$want" ]; then
            ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)
            [ "$ns" = "$want" ] && return 0
        fi
        if [ -n "$src" ] && $BB grep -q "^$src / " "/proc/$pid/mounts" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Keep watchdogd/logd/adbd/imsd/netd on CPU 0 and watchdogd at RT priority.
# switch_to_lineage.sh does this once before the guest starts; init can restart
# adbd/imsd later, so the guard re-applies it periodically.
protect_host() {
    NCPU=$($BB grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [ -n "$NCPU" ] || NCPU=1
    [ "$NCPU" -gt 1 ] || return 0
    for p in watchdogd logd adbd imsd netd; do
        pid=$($BB pidof "$p" 2>/dev/null | $BB awk '{print $1}')
        [ -n "$pid" ] || continue
        $BB taskset -p 1 "$pid" 2>/dev/null || taskset -p 1 "$pid" 2>/dev/null || true
        $BB renice -n -20 "$pid" 2>/dev/null || renice -n -20 "$pid" 2>/dev/null || true
        if [ "$p" = "watchdogd" ]; then
            $BB chrt -f -p 10 "$pid" 2>/dev/null || chrt -f -p 10 "$pid" 2>/dev/null || true
        fi
    done
}

# Count matching lines in the most recent guest log window. This intentionally
# looks at saturation instead of a cumulative count: when the guest is spinning,
# the tail of every buffer is made of these lines. Three consecutive samples
# (about 6 s) trigger the rollback.
#
# Read the rotating file that master_inner.sh captures instead of running
# `logcat -d -t 2000`: under a binder/CPU storm logcat itself can block, which
# would freeze the guard exactly when it is needed. tail(1) on a 4 MB file is
# bounded and cannot hang on a dead logd.
storm_count() {
    [ -f "$STAGE/data/guest_logcat.log" ] || { echo 0; return; }
    $BB tail -n 2000 "$STAGE/data/guest_logcat.log" 2>/dev/null | \
        $BB grep -cE 'MediaCodecList|codecHandlesFormat|AString: ctor NULL|AString: ctor got NULL'
}

say "guard started (pid $$)"
START=$($BB date +%s)
protect_host
BAD=0
TICK=0

# The softdog feeder is the only thing keeping the kernel alive after the host
# system_server dies. If it crashed, restart it: the guard is the long-lived
# component and can do that without the orchestrator.
check_kicker() {
    kpid=$($BB cat "$STAGE/softdog_kicker.pid" 2>/dev/null)
    if [ -n "$kpid" ] && kill -0 "$kpid" 2>/dev/null; then
        return 0
    fi
    [ -f "$STAGE/stop_softdog_kicker" ] && return 0
    say "WARNING: softdog kicker is not running; restarting it"
    rm -f "$STAGE/stop_softdog_kicker"
    if [ -x "$STAGE/softdog_kicker.sh" ]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid /system/bin/sh "$STAGE/softdog_kicker.sh" </dev/null >/dev/null 2>&1 &
        else
            nohup /system/bin/sh "$STAGE/softdog_kicker.sh" </dev/null >/dev/null 2>&1 &
        fi
    fi
}

while true; do
    $BB sleep 2
    [ -f "$STOP" ] && { say "stop flag seen"; exit 0; }
    [ -f "$FLAG" ] && exit 0

    # If the host root vanished, a takeover pivoted it without a private mount
    # namespace. Recover from the host init's original root immediately.
    if [ ! -x /system/bin/sh ]; then
        say "host /system missing; recovering via /proc/1/root"
        if [ -x /proc/1/root/system/bin/sh ]; then
            $BB chroot /proc/1/root /system/bin/sh "$STAGE/return_to_oneui.sh" >> "$LOG" 2>&1
        else
            sync
            echo b > /proc/sysrq-trigger 2>/dev/null || reboot -f 2>/dev/null || true
        fi
        exit 1
    fi

    TICK=$((TICK + 1))
    if [ $((TICK % 5)) -eq 0 ]; then
        protect_host
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

    NOW=$($BB date +%s)
    ELAPSED=$((NOW - START))
    # A missing system_server means zygote never came up; waiting longer cannot
    # help. A *slow* boot, however, is normal on this eMMC (load average ~15),
    # and rolling back a healthy guest is worse than waiting: the storm check
    # above is what protects the watchdog, and the guest is pinned off CPU 0.
    # The previous successful run needed between 150s and 233s for system_server
    # to appear; 360s gives ample margin without risking the softdog (the kicker
    # feeds independently every 10s).
    if [ "$ELAPSED" -gt 360 ] && ! guest_system_server; then
        rollback "guest system_server is not running after ${ELAPSED}s"
    fi
    # The UI activator waits up to ~600 s for WindowManager (300 iterations),
    # then up to 180 s for boot completion, a 15 s settle, and up to 96 s of
    # launcher retries on this slow eMMC. The softdog kicker keeps the kernel
    # alive independently, so a long boot is safe; only roll back after the
    # activator's full budget.
    if [ "$ELAPSED" -gt 720 ] && [ ! -f "$UI_READY" ]; then
        rollback "guest UI not ready after ${ELAPSED}s"
    fi

    if [ $((TICK % 15)) -eq 0 ]; then
        # Bound every dmesg read. The kernel log is 2 MB on this device and
        # dmesg can block in klogctl when the kernel is under stress; an
        # unbounded read froze the guard during a previous media storm.
        if $BB timeout -s KILL 5 $DMESG 2>/dev/null | $BB tail -n 200 | \
            $BB grep -qiE 'watchdog: BUG|watchdog timer expired|watchdog did not stop|softdog: .*failed|BUG: soft lockup'; then
            rollback "host watchdog/soft-lockup warning in dmesg"
        fi
        check_kicker
        # Re-assert the headless wake lock. If anything released it (e.g. an
        # older rollback path), the next suspend would stop the softdog timer
        # and panic the kernel ~100 s later.
        if [ -w /sys/power/wake_lock ] && \
           ! $BB grep -q onelineage_takeover /sys/power/wake_lock 2>/dev/null; then
            echo "onelineage_takeover" > /sys/power/wake_lock 2>/dev/null || true
            say "re-acquired takeover wake lock"
        fi
        if [ -f "$UI_READY" ]; then
            say "alive: ${ELAPSED}s, storm=${STORM}, ui=ready"
        else
            say "alive: ${ELAPSED}s, storm=${STORM}, ui=booting"
        fi
    fi
done
