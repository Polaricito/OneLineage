#!/system/bin/sh
# OneLineage preflight / diagnostics.
#
# Run this on the host (One UI) before a takeover, or from adb while Lineage is
# running. It collects the facts needed to tell a media-handover failure from a
# watchdog/scheduler failure, an APEX mismatch, or a missing root helper.
STAGE="/data/local/tmp/lineage_stage"
OUT="${1:-/data/local/tmp/oneLineage_preflight.txt}"

BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
LOGCAT=/system/bin/logcat
[ -x "$LOGCAT" ] || LOGCAT=logcat
DMESG=/system/bin/dmesg
[ -x "$DMESG" ] || DMESG=dmesg

{
    echo "== OneLineage preflight =="
    echo "date: $(date 2>/dev/null)"
    echo "model: $(getprop ro.product.model)"
    echo "device: $(getprop ro.product.device)"
    echo "android: $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
    echo "oneui: $(getprop ro.build.version.oneui) / PDA $(getprop ro.build.PDA)"
    echo "board: $(getprop ro.board.platform) / hardware $(getprop ro.boot.hardware)"
    echo "lineage: $(getprop ro.lineage.version)"
    echo "selinux: $(getenforce 2>/dev/null || echo unknown)"
    echo "uptime: $(uptime 2>/dev/null)"
    echo "cpus: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
    echo "load: $(cat /proc/loadavg 2>/dev/null)"

    echo
    echo "-- root helpers --"
    for p in su busybox resetprop; do
        echo "$p: $(command -v "$p" 2>/dev/null || true)"
    done
    echo "BB=$BB"
    if [ -x "$BB" ]; then
        echo "-- busybox applets --"
        $BB --list 2>/dev/null | grep -E '^(unshare|pivot_root|mount|chcon|losetup|nsenter|setsid|taskset|chrt|setuidgid|renice|pidof)$'
    else
        echo "WARNING: busybox not found"
    fi

    echo
    echo "-- storage --"
    df -h /data 2>/dev/null
    echo "system.raw: $(ls -lh "$STAGE/system.raw" 2>/dev/null || echo missing)"
    echo "stage scripts:"
    ls -l "$STAGE"/*.sh 2>/dev/null | head -n 20

    echo
    echo "-- watchdog --"
    ls -l /dev/watchdog* 2>/dev/null || echo "no /dev/watchdog*"
    WDPID=$(pidof watchdogd 2>/dev/null | awk '{print $1}')
    echo "watchdogd pid: ${WDPID:-missing}"
    if [ -n "$WDPID" ]; then
        chrt -p "$WDPID" 2>/dev/null || $BB chrt -p "$WDPID" 2>/dev/null || true
        taskset -p "$WDPID" 2>/dev/null || $BB taskset -p "$WDPID" 2>/dev/null || true
    fi

    echo
    echo "-- media init services --"
    for svc in media mediaextractor mediametrics media.swcodec mediadrm vendor.media.omx wificond; do
        echo "$svc=$(getprop init.svc.$svc)"
    done
    echo "-- media binder services --"
    SVC=service
    command -v service >/dev/null 2>&1 || SVC=/system/bin/service
    $SVC list 2>/dev/null | grep -E 'media\.(player|extractor|metrics|resource_manager|resource_observer)|android\.hardware\.media\.c2\.IComponentStore|wifinl80211' || echo "none"
    echo "-- media processes --"
    ps -A -o PID,PPID,USER,NAME,ARGS 2>/dev/null | grep -iE 'media|codec|omx' | grep -v grep || true

    echo
    echo "-- recent media logs --"
    $LOGCAT -b all -d -t 80 2>/dev/null | grep -aE 'MediaCodecList|codecHandlesFormat|AString: ctor got NULL' | tail -n 30 || true

    echo
    echo "-- dmesg tail --"
    $DMESG 2>/dev/null | tail -n 40 || echo "dmesg unavailable"
} > "$OUT" 2>&1

echo "Preflight written to $OUT"
cat "$OUT"
