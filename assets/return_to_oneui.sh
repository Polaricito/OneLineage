#!/system/bin/sh
# Return to One UI / Safe State Restoration
STAGE="/data/local/tmp/lineage_stage"
BACKUP_DIR="/data/local/tmp/lineage_backups"
LOG="$STAGE/guest_guard.log"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

# NOTE: do not release the takeover wake lock here. It must stay held until
# One UI is actually running again (see the end of this script); releasing it
# while the display/services are still down lets the device suspend and the
# Samsung softdog hrtimer miss its 100 s deadline.

# Stop the guard from starting a second rollback while this one runs.
mkdir -p "$STAGE" 2>/dev/null || true
echo "rollback in progress" > "$STAGE/guard_triggered" 2>/dev/null || true

# If /system/bin is missing, this shell is running with the container's root
# (a takeover that skipped unshare -m). The host init's original root is still
# reachable through /proc/1/root; re-exec there before unmounting anything.
# Without this check the rollback unmounts its own /system and the kernel
# watchdog panics (2026-10-28).
if [ ! -x /system/bin/sh ]; then
    if [ -x /proc/1/root/system/bin/sh ]; then
        echo "WARNING: /system/bin missing; re-executing in the host root via /proc/1/root" >> "$LOG" 2>/dev/null
        exec "$BB" chroot /proc/1/root /system/bin/sh "$0" "$@"
    fi
    echo "FATAL: /system/bin missing and /proc/1/root is unusable; rebooting" >> "$LOG" 2>/dev/null
    sync
    echo b > /proc/sysrq-trigger 2>/dev/null || reboot -f 2>/dev/null || true
    exit 1
fi

SVC=service
command -v service >/dev/null 2>&1 || SVC=/system/bin/service

# Kill every process running in the guest mount namespace. After pivot_root,
# /proc/<pid>/root reads "/" for every process, so the old root-link test never
# matched and left the guest's surfaceflinger/vold holding the display and
# input devices (One UI came back with a dead touchscreen).
#
# Do NOT kill by "namespace differs from ours": Android app processes also run
# in private mount namespaces. Instead match the exact guest namespace written
# by master_inner.sh, plus the system.raw loop source recorded by
# master_prepare.sh for children that unshared a private namespace. The
# "^$src / " anchor matters: a plain "^$src " also matches the host's
# $STAGE/rootfs mount and would kill host processes.
kill_guest_root() {
    want=$($BB cat "$STAGE/guest_mnt_ns" 2>/dev/null)
    src=$($BB cat "$STAGE/guest_root_src" 2>/dev/null)
    echo "Guest mount namespace: ${want:-unknown}; guest root source: ${src:-unknown}"
    pass=0
    while [ "$pass" -lt 3 ]; do
        found=0
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}
            [ "$pid" = "1" ] && continue
            [ "$pid" = "$$" ] && continue
            [ "$pid" = "$PPID" ] && continue
            if [ -n "$want" ]; then
                ns=$(readlink "$d/ns/mnt" 2>/dev/null)
                if [ "$ns" = "$want" ]; then
                    kill -9 "$pid" 2>/dev/null && found=1
                    continue
                fi
            fi
            if [ -n "$src" ] && $BB grep -q "^$src / " "$d/mounts" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null && found=1
            fi
        done
        [ "$found" -eq 0 ] && break
        pass=$((pass + 1))
        $BB sleep 0.2
    done
}

echo "=== [1/6] Terminating Container Supervision & Zygote ==="
kill_guest_root
# Guest-only binaries. These names do not exist on One UI, so they are safe to
# match by cmdline even if a root link was not readable.
for pat in mediaserver64 mediaswcodec zygote_exec app_storage_loop.sh; do
    $BB pkill -9 -f "$pat" 2>/dev/null || true
done
# Guest media helpers and wificond share names with Samsung's. The host copies
# were stopped by the takeover; killing the remainder frees the service names
# before the restart below.
for pat in "/system/bin/mediaextractor" "/system/bin/mediametrics" "/system/bin/wificond"; do
    $BB pkill -9 -f "$pat" 2>/dev/null || true
done
# Stop the supervision loops started by switch_to_lineage.sh.
if [ -f "$STAGE/media_suppress.pid" ]; then
    kill -9 "$(cat "$STAGE/media_suppress.pid")" 2>/dev/null || true
    rm -f "$STAGE/media_suppress.pid"
fi
for pat in onelineage_media_suppress adb_watchdog.sh ims_watchdog.sh ui_activator "UI Activator" "ctl.stop zygote"; do
    $BB pkill -9 -f "$pat" 2>/dev/null || true
done

# Put the host's own /data trees back FIRST: master_prepare.sh bridged the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    $BB umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/6] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$($BB stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$($BB stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    $BB cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    $BB chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/6] Unmounting Container Overlays ==="
# Unmount deepest-first. Use the busybox mount table because /system/bin/mount
# may be unavailable if a previous takeover pivoted the host root.
for m in $($BB cat /proc/mounts 2>/dev/null | $BB awk -v r="$STAGE/rootfs" 'index($2, r) == 1 {print $2}' | $BB sort -r); do
    $BB umount -l "$m" 2>/dev/null || true
done
while $BB cat /proc/mounts 2>/dev/null | $BB grep -q "$STAGE/rootfs"; do
    $BB umount -l "$STAGE/rootfs" 2>/dev/null || true
    $BB sleep 0.1
done
# Detach every loop device backed by a staged image (system.raw and the APEX
# payloads). Do not touch loops owned by the host.
for l in $($BB losetup -a 2>/dev/null | $BB grep "$STAGE/" | $BB cut -d: -f1); do
    $BB losetup -d "$l" 2>/dev/null || true
done

echo "=== [4/6] Verifying Host Storage ==="
# The guest's /storage tmpfs lived in its private mount namespace, so the host
# mount table was never touched. Only report a missing FUSE mount; do not
# replace it with a raw /data/media bind, which bypasses vold's permissions.
if $BB cat /proc/mounts 2>/dev/null | $BB grep -q " /storage/emulated "; then
    echo "Host /storage/emulated is mounted."
else
    echo "WARNING: host /storage/emulated is missing; asking init to start vold."
    setprop ctl.start vold 2>/dev/null || true
fi

echo "=== [5/6] Starting One UI Display & Host Services ==="
# Start everything that does not need the watchdog first. zygote is started
# last because the host system_server is the only process that can feed
# /dev/watchdog1, and the softdog kicker is still holding it.
for svc in surfaceflinger audioserver cameraserver; do
    setprop ctl.start "$svc" 2>/dev/null || true
done

# Stop the softdog kicker immediately before zygote. A watchdog device has
# exactly one opener: the new system_server cannot open /dev/watchdog1 until
# the kicker's busybox feeder closes it. Busybox watchdog disarms the timer
# with the magic 'V' close on TERM, so the handover window is safe.
if [ -f "$STAGE/softdog_kicker.pid" ]; then
    KPID=$($BB cat "$STAGE/softdog_kicker.pid" 2>/dev/null)
    if [ -n "$KPID" ]; then
        echo "Stopping softdog kicker (pid $KPID) before host zygote"
        : > "$STAGE/stop_softdog_kicker"
        kill -TERM "$KPID" 2>/dev/null || true
        k=0
        while kill -0 "$KPID" 2>/dev/null && [ "$k" -lt 20 ]; do
            k=$((k + 1))
            $BB sleep 0.2
        done
        kill -9 "$KPID" 2>/dev/null || true
    fi
    rm -f "$STAGE/softdog_kicker.pid"
fi
# The kicker may run the feeder in its own process group (setsid); sweep any
# busybox watchdog still attached to the virtual softdog.
for p in $($BB pidof watchdog 2>/dev/null); do
    cmd=$($BB cat "/proc/$p/cmdline" 2>/dev/null | $BB tr '\0' ' ')
    case "$cmd" in
        *watchdog1*) kill -TERM "$p" 2>/dev/null || true ;;
    esac
done

setprop ctl.start zygote 2>/dev/null || true
# Start the swcodec component store before mediaserver so media.player can
# answer the codec-list query immediately. vendor.media.omx normally stayed
# running, but restarting a running init service is a no-op.
for svc in media.swcodec mediaextractor mediametrics media vendor.media.omx wificond; do
    setprop ctl.start "$svc" 2>/dev/null || true
done

# Wait for the host system_server. 25 s is the whole budget left after a 55 s
# guard trigger: beyond that the kernel watchdog is at risk, and a clean reboot
# is safer than letting watchdogd starve.
i=0
while [ "$i" -lt 25 ]; do
    if $SVC list 2>/dev/null | $BB grep -q 'activity'; then
        break
    fi
    i=$((i + 1))
    $BB sleep 1
done
if [ "$i" -ge 25 ]; then
    echo "ERROR: host activity service did not return after 25s; rebooting to recover One UI"
    sync
    echo b > /proc/sysrq-trigger 2>/dev/null || reboot -f 2>/dev/null || true
    exit 1
fi

am force-stop com.sec.android.app.launcher 2>/dev/null || true
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true

# Give watchdogd/logd/adbd/imsd/netd their normal affinity and scheduling back.
NCPU=$($BB grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
if [ "$NCPU" -gt 1 ]; then
    ALL_MASK=$(printf '%x' $(( (1 << NCPU) - 1 )))
    for p in watchdogd logd adbd imsd netd; do
        pid=$($BB pidof "$p" 2>/dev/null | $BB awk '{print $1}')
        [ -n "$pid" ] || continue
        taskset -p "$ALL_MASK" "$pid" 2>/dev/null || $BB taskset -p "$ALL_MASK" "$pid" 2>/dev/null || true
        if [ "$p" = "watchdogd" ]; then
            chrt -o -p 0 "$pid" 2>/dev/null || $BB chrt -o -p 0 "$pid" 2>/dev/null || true
        fi
    done
fi

# switch_to_lineage.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "One UI restored successfully."

# Now that One UI owns the display and its PowerManager wakelocks again, the
# headless window is over. Release the takeover wake lock last so the device
# could not suspend while the guest was being torn down.
if [ -w /sys/power/wake_unlock ]; then
    echo "onelineage_takeover" > /sys/power/wake_unlock 2>/dev/null && \
        echo "Wake lock released (One UI is up)"
fi
