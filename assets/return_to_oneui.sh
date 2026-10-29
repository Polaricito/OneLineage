#!/system/bin/sh
# Return to One UI / Safe State Restoration
STAGE="/data/local/tmp/lineage_stage"
BACKUP_DIR="/data/local/tmp/lineage_backups"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
SVC=service
command -v service >/dev/null 2>&1 || SVC=/system/bin/service

echo "=== [1/6] Terminating Container Supervision & Zygote ==="
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "guest_guard.sh" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Stop the adb watchdog started by switch_to_lineage.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
pkill -9 -f "system_server" 2>/dev/null || true
pkill -9 -f org.lineageos 2>/dev/null || true
pkill -9 -x zygote64 2>/dev/null || true
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true

# The guest media stack was started manually inside the container, not by init.
# Kill it before restarting Samsung's media services so the service names are
# free and the host mediaserver cannot inherit a guest binder handle.
pkill -9 -f "/system/bin/mediaserver" 2>/dev/null || true
pkill -9 -f "/system/bin/media.codec" 2>/dev/null || true
pkill -9 -f "/system/bin/mediaextractor" 2>/dev/null || true
pkill -9 -f "/system/bin/mediametrics" 2>/dev/null || true
pkill -9 -f "/system/bin/mediaresourcemanager" 2>/dev/null || true
# switch_to_lineage.sh stopped the host wificond; the only one left is the
# guest's, so this frees the service name for the host restart below.
pkill -9 -f "/system/bin/wificond" 2>/dev/null || true

# vold is special: the host vold must keep running. Kill only the instance that
# lives in the container's mount namespace.
HOST_MNT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
for pid in $(pidof vold 2>/dev/null); do
    ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)
    if [ -n "$HOST_MNT_NS" ] && [ "$ns" != "$HOST_MNT_NS" ]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
done

# Stop the host media suppression loop from switch_to_lineage.sh.
if [ -f "$STAGE/media_suppress.pid" ]; then
    kill -9 "$(cat "$STAGE/media_suppress.pid")" 2>/dev/null || true
    rm -f "$STAGE/media_suppress.pid"
fi
pkill -9 -f "onelineage_media_suppress" 2>/dev/null || true

# Put the host's own /data trees back FIRST: master_prepare.sh bridges the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/6] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/6] Unmounting Container Overlays ==="
umount -l /data/local/tmp/lineage_stage/rootfs/* 2>/dev/null || true
umount -l /data/local/tmp/lineage_stage/rootfs/apex/* 2>/dev/null || true
while mount | grep -q "/data/local/tmp/lineage_stage/rootfs"; do
    umount -l /data/local/tmp/lineage_stage/rootfs 2>/dev/null || true
    sleep 0.1
done
if [ -x "$BB" ]; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
fi

echo "=== [4/6] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true

echo "=== [5/6] Starting One UI Display & Host Services ==="
setprop ctl.start surfaceflinger
setprop ctl.start zygote
setprop ctl.start audioserver
setprop ctl.start cameraserver
# switch_to_lineage.sh stops the whole host media stack; bring it back for One UI.
for svc in media media.codec media.extractor media.metrics media.resource_manager wificond; do
    setprop ctl.start "$svc" 2>/dev/null || true
done

# Wait for the host system_server before issuing ActivityManager commands.
i=0
while [ $i -lt 60 ]; do
    $SVC list 2>/dev/null | grep -q 'activity' && break
    i=$((i + 1))
    sleep 1
done
if [ "$i" -ge 60 ]; then
    echo "WARNING: host activity service did not come back; launcher restore skipped"
else
    am force-stop com.sec.android.app.launcher 2>/dev/null || true
    am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true
fi

# Give watchdogd/logd/adbd/imsd/netd their normal affinity and scheduling back.
NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
if [ "$NCPU" -gt 1 ]; then
    ALL_MASK=$(printf '%x' $(( (1 << NCPU) - 1 )))
    for p in watchdogd logd adbd imsd netd; do
        pid=$(pidof "$p" 2>/dev/null | awk '{print $1}')
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
