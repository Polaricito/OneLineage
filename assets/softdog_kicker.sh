#!/system/bin/sh
# OneLineage host-side Samsung softdog feeder.
#
# On Exynos Samsung kernels the HOST system_server is the only process that
# pings the software watchdog (/dev/watchdog1, cmdline
# softdog.soft_margin=100 softdog.soft_panic=1). The takeover kills
# system_server to free the binder namespace, and the guest's GSI system_server
# contains no Samsung softdog feeder, so nothing resets the timer:
#
#   Kernel panic - not syncing: Software Watchdog Timer expired 100s
#
# This daemon captures the watchdog device from system_server's fd table BEFORE
# it is killed, waits for system_server to exit, then feeds the device every
# 10 s for the rest of the guest session. It must stop just before the host
# zygote is restarted: a watchdog device has exactly one opener, so the new
# host system_server cannot take over until this feeder closes it.
#
# /proc/<pid>/fd/N cannot be dup'ed (opening it re-opens the device and fails
# with EBUSY), so the feeder waits for the close and then opens the node itself.
STAGE="/data/local/tmp/lineage_stage"
LOG="$STAGE/softdog_kicker.log"
STOP="$STAGE/stop_softdog_kicker"
PIDFILE="$STAGE/softdog_kicker.pid"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

say() {
    echo "$($BB date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

echo $$ > "$PIDFILE" 2>/dev/null
say "softdog kicker started (pid $$)"

# Mostly sleeping, but keep it on CPU 0 with the host watchdog path so a busy
# guest cannot delay the reset past the 100 s deadline.
$BB taskset -p 1 $$ 2>/dev/null || taskset -p 1 $$ 2>/dev/null || true

# Find the exact device system_server is feeding. This is a single-PID fd scan;
# scanning every process can block on a dead process (that hung a previous
# experiment), and only system_server's table matters here.
#
# Pick the HOST system_server: after a takeover the guest's GSI system_server
# also matches pidof. It does not hold the softdog, and waiting for it to exit
# would leave the timer unfed forever. The host process shares init's mount
# namespace; the guest runs in the container namespace.
DEV=""
SS=""
SS_HOLDS=0
SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
for p in $(pidof system_server 2>/dev/null); do
    pns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
    if [ -z "$SS" ]; then
        SS="$p"
    fi
    if [ -n "$SELF_NS" ] && [ "$pns" = "$SELF_NS" ]; then
        SS="$p"
        break
    fi
done
if [ -n "$SS" ]; then
    say "host system_server=$SS; scanning its watchdog fds"
    for f in /proc/$SS/fd/*; do
        t=$(readlink "$f" 2>/dev/null)
        case "$t" in
            /dev/watchdog*)
                DEV="$t"
                SS_HOLDS=1
                say "system_server fd ${f##*/} -> $t"
                break
                ;;
        esac
    done
    [ "$SS_HOLDS" = "1" ] || say "system_server $SS does not hold a watchdog device"
else
    say "no host system_server at start; will open the softdog directly"
fi

# Fallback: the softdog is the watchdog class device under devices/virtual.
# On this kernel watchdog0 is the hardware cluster watchdog and watchdog1 is
# the virtual softdog; /dev/watchdog (misc 10:130) is held by watchdogd.
if [ -z "$DEV" ]; then
    for w in /sys/class/watchdog/watchdog*; do
        case "$($BB readlink -f "$w" 2>/dev/null)" in
            */devices/virtual/*)
                DEV="/dev/${w##*/}"
                say "fallback: virtual watchdog class device $w -> $DEV"
                break
                ;;
        esac
    done
fi
[ -n "$DEV" ] || DEV=/dev/watchdog1
say "using watchdog device: $DEV"

# Wait for system_server to exit only when it actually owns the device.
# Opening while it is alive returns EBUSY, and racing its close is pointless.
# If the system_server found above is the guest's (no watchdog fd), skip the
# wait and open the node directly. 600 s bounds a takeover that was cancelled.
if [ "$SS_HOLDS" = "1" ] && [ -n "$SS" ]; then
    i=0
    while kill -0 "$SS" 2>/dev/null; do
        if [ -f "$STOP" ]; then
            say "stop flag while waiting for system_server; exiting"
            rm -f "$PIDFILE"
            exit 0
        fi
        $BB sleep 1
        i=$((i + 1))
        if [ $((i % 30)) -eq 0 ]; then
            say "waiting for system_server $SS to exit (${i}s)"
        fi
        if [ "$i" -ge 600 ]; then
            say "system_server still alive after ${i}s; giving up"
            rm -f "$PIDFILE"
            exit 0
        fi
    done
    say "host system_server $SS exited after ${i}s"
fi

FPID=""
cleanup() {
    if [ -n "$FPID" ]; then
        kill -TERM "$FPID" 2>/dev/null || true
        wait "$FPID" 2>/dev/null || true
        FPID=""
    fi
}
trap 'say "stopping feeder (TERM)"; cleanup; rm -f "$PIDFILE"; exit 0' TERM INT
trap 'cleanup; rm -f "$PIDFILE"' EXIT

# Start one feeder. Busybox watchdog exits immediately when the device is busy
# or missing, so a one-second liveness check tells us whether it opened it.
try_dev() {
    d="$1"
    [ -e "$d" ] || return 1
    say "starting feeder on $d (reset 10s, timeout 100s)"
    "$BB" watchdog -t 10 -T 100 -F "$d" >> "$LOG" 2>&1 &
    FPID=$!
    $BB sleep 1
    if kill -0 "$FPID" 2>/dev/null; then
        return 0
    fi
    wait "$FPID" 2>/dev/null || true
    FPID=""
    return 1
}

while true; do
    [ -f "$STOP" ] && { say "stop flag before open; exiting"; exit 0; }

    if try_dev "$DEV"; then
        say "feeding $DEV every 10s (feeder pid $FPID)"
        while kill -0 "$FPID" 2>/dev/null; do
            if [ -f "$STOP" ]; then
                say "stop flag seen; stopping feeder"
                cleanup
                rm -f "$PIDFILE"
                exit 0
            fi
            $BB sleep 2
        done
        say "feeder exited; will retry $DEV"
        FPID=""
        $BB sleep 5
        continue
    fi

    say "could not open $DEV"
    # Do NOT fall back to watchdog0. That is the hardware cluster watchdog,
    # already fed by the kernel; feeding it would look healthy while the
    # virtual softdog that actually panics this device stays starved. The only
    # reason the open fails is that system_server (or a rollback's new
    # system_server) still holds the node, so retry the same device.
    say "retrying $DEV in 5s"
    $BB sleep 5
done
