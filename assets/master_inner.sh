#!/system/bin/sh
STAGE=/data/local/tmp/lineage_stage
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

# Stage a guest-visible busybox before the pivot. $BB resolves to the host's
# /data/adb/ksu/bin/busybox, which does not exist inside the guest /data; after
# pivot_root every mount/setuidgid/sleep call would fail with ENOENT (that is
# why the media stack used to fall back to root and /data_mirror stayed empty).
if [ -x "$BB" ] && [ -d "$STAGE/data" ]; then
    cp -f "$BB" "$STAGE/data/busybox" 2>/dev/null || true
    chmod 755 "$STAGE/data/busybox" 2>/dev/null || true
fi

# pivot_root MUST run in a private mount namespace. If the caller forgot
# `unshare -m`, this script would move the HOST's / into the container rootfs:
# /system would then belong to the GSI, and return_to_oneui.sh would unmount
# its own /system while rolling back. That is exactly what happened on
# 2026-10-28 (the stale APK asset had no unshare call) and it ended in a
# kernel panic. Refuse to continue unless we are isolated.
MY_MNT_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
HOST_MNT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
echo "[Pivoted Root] mount namespace: ${MY_MNT_NS:-unknown} (host: ${HOST_MNT_NS:-unknown})"
if [ -z "$MY_MNT_NS" ] || [ "$MY_MNT_NS" = "$HOST_MNT_NS" ]; then
    echo "[Pivoted Root] FATAL: running in the host mount namespace; refusing to pivot."
    echo "[Pivoted Root] Start this script with: unshare -m sh master_inner.sh"
    exit 1
fi

# Publish the guest mount namespace. After pivot_root, /proc/<pid>/root reads
# as "/" for every process, so the guard and the rollback identify guest
# processes by this namespace (plus the system.raw loop source recorded by
# master_prepare.sh).
echo "$MY_MNT_NS" > "$STAGE/guest_mnt_ns"
echo "[Pivoted Root] Guest mount namespace: $MY_MNT_NS"

# Keep the guest off CPU 0. switch_to_lineage.sh pins watchdogd/logd/adbd/imsd/
# netd there, so a runaway guest process cannot starve the 100 s host watchdog.
# Children (zygote, system_server, surfaceflinger, media, apps) inherit this
# affinity mask.
NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
if [ "$NCPU" -gt 1 ]; then
    GUEST_MASK=$(printf '%x' $(( (1 << NCPU) - 2 )))
    $BB taskset -p "$GUEST_MASK" $$ 2>/dev/null || taskset -p "$GUEST_MASK" $$ 2>/dev/null || true
    echo "[Pivoted Root] Guest CPU affinity mask: $GUEST_MASK (CPU 0 reserved for host)"
fi

echo "[Pivoted Root] Preparing pivot..."
cd "$STAGE/rootfs"
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
$BB mount -t proc proc /proc

export PATH=/system/bin:/system/xbin

# /data is the staged tree now, so use the guest-visible busybox copy staged
# above. The host path /data/adb/ksu/bin/busybox is not part of the guest.
if [ -x /data/busybox ]; then
    BB=/data/busybox
elif [ -x /system/bin/busybox ]; then
    BB=/system/bin/busybox
fi
echo "[Pivoted Root] Post-pivot busybox: $BB"

echo "[Pivoted Root] Setting up /data_mirror and /data/data mounts for Zygote isolation..."
$BB mount --bind /data/user/0 /data/data 2>/dev/null || true
$BB mount -t tmpfs tmpfs /data_mirror 2>/dev/null || true
mkdir -p /data_mirror/data_de/null/0 /data_mirror/data_ce/null/0 /data_mirror/cur_profiles /data_mirror/ref_profiles
chmod -R 777 /data_mirror
$BB mount --bind /data/user_de/0 /data_mirror/data_de/null/0 2>/dev/null || true
$BB mount --bind /data/user/0 /data_mirror/data_ce/null/0 2>/dev/null || true
mkdir -p /data/misc/profiles/cur /data/misc/profiles/ref
$BB mount --bind /data/misc/profiles/cur /data_mirror/cur_profiles 2>/dev/null || true
$BB mount --bind /data/misc/profiles/ref /data_mirror/ref_profiles 2>/dev/null || true

echo "[Pivoted Root] Setting up /data/media and emulated storage..."
mkdir -p /data/media/0/Android /data/media/0/Pictures/Screenshots /data/media/0/Download /data/media/0/DCIM /data/media/0/Documents
chown -R 1023:1023 /data/media 2>/dev/null || true
chmod -R 777 /data/media 2>/dev/null || true
$BB mount -t tmpfs tmpfs /storage 2>/dev/null || true
mkdir -p /storage/emulated/0
$BB mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true
mkdir -p /mnt/user/0
$BB mount -t tmpfs tmpfs /mnt/user/0 2>/dev/null || true
mkdir -p /mnt/user/0/emulated
$BB mount --bind /data/media/0 /mnt/user/0/emulated 2>/dev/null || true

echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"

echo "[Pivoted Root] Starting LineageOS SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting LineageOS BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting LineageOS Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# Wifi. switch_to_lineage.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting LineageOS wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
sleep 1

# Media. switch_to_lineage.sh stopped Samsung's platform media services so the
# guest can own media.player/media.c2. Start the GSI's own stack here:
#   mediaserver64   -> media.player, media.resource_manager, media.resource_observer
#   mediaextractor  -> media.extractor
#   mediametrics    -> media.metrics
#   mediaswcodec    -> android.hardware.media.c2.IComponentStore/software
# MediaCodecList::getRemoteInstance() asks media.player for the codec list, so
# media.player MUST be the guest's mediaserver64. If Samsung's mediaserver keeps
# the name, the guest parses Samsung's IMediaCodecList parcel layout with its own
# ABI in a loop until the CPU/watchdog dies. The vendor C2/OMX/DRM HALs are left
# running: they speak stable AIDL/HIDL and give the guest hardware codecs.
mkdir -p /data/misc/media /data/vendor/media
chown 1013:1013 /data/misc/media /data/vendor/media 2>/dev/null || true
chmod 0770 /data/misc/media /data/vendor/media 2>/dev/null || true

start_guest_media() {
    b="$1"
    user="$2"
    pname="$3"
    if [ ! -x "$b" ]; then
        echo "[Pivoted Root] MISSING media binary: $b"
        return 0
    fi
    name=$(basename "$b")
    echo "[Pivoted Root] Starting $pname ($b) as $user..."
    $BB setuidgid "$user" "$b" > "/data/$name.log" 2>&1 &
    sleep 1
    running=0
    pidof "$pname" >/dev/null 2>&1 && running=1
    if [ "$running" -eq 0 ]; then
        echo "[Pivoted Root] $pname did not start as $user; retrying as root"
        echo "setuidgid $user failed, retrying as root" >> "/data/$name.log"
        "$b" >> "/data/$name.log" 2>&1 &
        sleep 1
        if ! pidof "$pname" >/dev/null 2>&1; then
            echo "[Pivoted Root] WARNING: $pname is not running; see /data/$name.log"
        fi
    fi
}

# Match the GSI's own init users: media / mediaex / mediacodec. Start the
# component store and the helpers before mediaserver64 so media.player can
# resolve them as soon as the framework asks for a codec list.
#
# pidof matches the process name the binary sets, not its file name:
#   mediaserver64  -> "mediaserver"
#   mediaextractor -> "media.extractor"
#   mediametrics   -> "media.metrics"
#   mediaswcodec   -> "media.swcodec"
start_guest_media /system/bin/mediametrics media media.metrics
start_guest_media /system/bin/mediaextractor mediaex media.extractor
start_guest_media /apex/com.android.media.swcodec/bin/mediaswcodec mediacodec media.swcodec
start_guest_media /system/bin/mediaserver64 media mediaserver

# media.player is the service the framework asks for its codec list. If it did
# not come up, MediaCodecList falls back to a remote call on a dead/foreign
# service and the boot storm starts. Make the failure loud in the log.
if ! pidof mediaserver >/dev/null 2>&1; then
    echo "[Pivoted Root] WARNING: mediaserver (mediaserver64) is not running; media.player is unavailable"
    echo "[Pivoted Root] mediaserver64 log:"
    tail -n 20 /data/mediaserver64.log 2>/dev/null
fi

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
NAV_IDMAP="/data/resource-cache/system@product@overlay@NavigationBarModeGestural@NavigationBarModeGesturalOverlay.apk@idmap"
NAV_OV="/system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
mkdir -p /data/resource-cache
if [ ! -s "$NAV_IDMAP" ] && [ -f "$NAV_OV" ]; then
    echo "[Pivoted Root] Generating gesture-nav overlay idmap..."
    /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
        --overlay-apk-path "$NAV_OV" --idmap-path "$NAV_IDMAP" --ignore-overlayable \
        > /data/idmap.log 2>&1 \
        && chmod 644 "$NAV_IDMAP" && chown system:system "$NAV_IDMAP" \
        && echo "[Pivoted Root] idmap OK ($(wc -c < "$NAV_IDMAP") bytes)" \
        || echo "[Pivoted Root] idmap FAILED: $(head -n1 /data/idmap.log 2>/dev/null)"
fi

# Newly installed apps have no data directories (the guest has no installd), and
# zygote kills their first launch with "Failed to mount /data_mirror/...". This
# sweep creates them while Lineage runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."

echo "[Pivoted Root] Cleaning stale sockets..."
# /dev is the host's /dev (master_prepare.sh does not bind a private tmpfs), so
# stopping the host zygote leaves /dev/socket/zygote and usap_pool_primary
# behind. The guest zygote would then fail at bind() before it can open its own
# log, leaving no clue why system_server never appeared.
#
# init can restart the host zygote while master_inner.sh is starting the media
# stack, which recreates the sockets. Wait until the service is actually stopped
# and kill any late zygote64 before removing them, so the guest's bind() cannot
# race a fresh host socket.
i=0
while [ "$i" -lt 25 ]; do
    [ "$(getprop init.svc.zygote 2>/dev/null)" = "stopped" ] && break
    setprop ctl.stop zygote 2>/dev/null || true
    for p in $(pidof zygote64 2>/dev/null); do
        kill -9 "$p" 2>/dev/null || true
    done
    i=$((i + 1))
    $BB sleep 0.2
done
echo "[Pivoted Root] Host zygote service: $(getprop init.svc.zygote 2>/dev/null || echo unknown)"
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

echo "[Pivoted Root] Launching LineageOS Zygote & SystemServer via zygote_exec..."
# zygote_exec redirects its own stdio to /data/zygote_stderr.log (patched from
# /dev/null so an execve/linker failure is no longer silent). Create/truncate it
# first: the binary opens it O_RDWR without O_CREAT.
: > /data/zygote_stderr.log 2>/dev/null || true
: > /data/zygote_early.log 2>/dev/null || true
{
    echo "== zygote preflight =="
    ls -l /system/bin/app_process64 /system/bin/linker64 \
        /apex/com.android.runtime/bin/linker64 \
        /apex/com.android.art/lib64/libnativeloader.so \
        /apex/com.android.art/lib64/libsigchain.so 2>&1
    echo "== boot/systemserver classpath jars =="
    for j in /apex/com.android.telephonycore/javalib/framework-telephony.jar \
             /apex/com.android.wifi/javalib/framework-wifi.jar \
             /apex/com.android.wifi/javalib/service-wifi.jar \
             /apex/com.android.compos/javalib/service-compos.jar \
             /apex/com.android.media/javalib/service-media-s.jar \
             /system/framework/framework.jar \
             /system/framework/services.jar; do
        if [ -e "$j" ]; then
            echo "OK $j $(wc -c < "$j" 2>/dev/null)"
        else
            echo "MISSING $j"
        fi
    done
    echo "== linker --list =="
    /system/bin/linker64 --list /system/bin/app_process64 2>&1
    echo "linker_list_rc=$?"
} >> /data/zygote_early.log 2>&1
exec /system/bin/sh -c 'exec /data/zygote_exec >> /data/zygote_early.log 2>&1'
