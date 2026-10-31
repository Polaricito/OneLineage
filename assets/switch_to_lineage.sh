#!/system/bin/sh
# OneLineage Userspace Takeover Orchestrator
STAGE="/data/local/tmp/lineage_stage"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
RP=$(which resetprop 2>/dev/null || echo "/data/adb/ksu/bin/resetprop")
[ -x "$RP" ] || RP=$(find /data/adb /system -name resetprop 2>/dev/null | head -n 1)

export BB
export RP
export STAGE

# Refuse to run two orchestrators at once. A second run pkill's the active
# guest_guard and tears down a healthy takeover halfway through (observed
# 2026-10-30 when the app's Start button was tapped during an adb-launched run).
SWITCH_LOCK="$STAGE/switch.lock"
if [ -f "$SWITCH_LOCK" ]; then
    OLD_PID=$(cat "$SWITCH_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "ERROR: switch_to_lineage.sh already running (pid $OLD_PID); refusing second takeover"
        exit 1
    fi
fi
echo $$ > "$SWITCH_LOCK"
trap 'rm -f "$SWITCH_LOCK"' EXIT INT TERM

set_prop() {
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        "$RP" "$1" "$2" 2>/dev/null || true
    else
        setprop "$1" "$2" 2>/dev/null || true
    fi
}

# service(1) lives in /system/bin; keep a fallback for ROMs that only expose
# the `cmd service` form. Wrap in timeout to avoid binder hangs when
# system_server is down (the previous run hung indefinitely in
# binder_wait_for_work, causing the prep window to exceed the softdog
# deadline and panic the kernel).
SVC="service"
command -v service >/dev/null 2>&1 || SVC="/system/bin/service"
service_list() {
    # 5 s timeout is generous for a local servicemanager call.
    timeout -s KILL 5 $SVC list 2>/dev/null || timeout -s KILL 5 cmd service list 2>/dev/null
}

# Reserve CPU 0 for the host's watchdog path and pin the guest to the rest.
# The media storm is a userspace CPU/binder storm; if watchdogd cannot run for
# 100 s Samsung's software watchdog panics the kernel. watchdogd sleeps almost
# all the time, so SCHED_FIFO is safe here.
protect_host_cpu() {
    NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    [ "$NCPU" -gt 1 ] || return 0
    HOST_MASK=1
    if ! pidof watchdogd >/dev/null 2>&1; then
        setprop ctl.start watchdogd 2>/dev/null || true
        sleep 1
    fi
    for p in watchdogd logd adbd imsd netd; do
        pid=$(pidof "$p" 2>/dev/null | awk '{print $1}')
        [ -n "$pid" ] || continue
        taskset -p "$HOST_MASK" "$pid" 2>/dev/null || $BB taskset -p "$HOST_MASK" "$pid" 2>/dev/null || true
        renice -n -20 "$pid" 2>/dev/null || $BB renice -n -20 "$pid" 2>/dev/null || true
        if [ "$p" = "watchdogd" ]; then
            chrt -f -p 10 "$pid" 2>/dev/null || $BB chrt -f -p 10 "$pid" 2>/dev/null || true
        fi
    done
    echo "Host watchdog path pinned to CPU 0 (watchdogd=$(pidof watchdogd 2>/dev/null))"
}

BACKUP_DIR="/data/local/tmp/lineage_backups"

echo "=== LINEAGEOS 23.2 TAKEOVER STARTING ==="

# Put SELinux in permissive mode for the duration of the takeover. The guest
# userspace is a foreign, unlabelled-for-this-policy userspace: its
# system_server runs as u:r:system_server:s0 against Samsung's policy, and MAC
# denials there surface as confusing EACCES/ENOENT deep inside system_server
# (e.g. settings.db "doesn't exist", users/0.xml EACCES). master_prepare.sh
# relabels the staged /data properly, but permissive is the safety net that
# keeps the rest of the guest boot from tripping over labels we cannot predict.
# return_to_oneui.sh restores enforcing.
setenforce 0 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"

# Prevent suspend during the takeover. When One UI (zygote/system_server/
# surfaceflinger) is stopped, all Android wakelocks are released and the
# device can enter suspend. The Samsung softdog watchdog uses a hrtimer that
# does NOT run during suspend; if the hrtimer misses its 100 s deadline, the
# kernel panics ("Software Watchdog Timer expired 100s"). Hold a kernel
# wakelock via /sys/power/wake_lock for the entire headless window.
if [ -w /sys/power/wake_lock ]; then
    if ! $BB grep -q onelineage_takeover /sys/power/wake_lock 2>/dev/null; then
        echo "onelineage_takeover" > /sys/power/wake_lock 2>/dev/null && \
            echo "Wake lock acquired: onelineage_takeover"
    else
        echo "Wake lock already held: onelineage_takeover"
    fi
else
    echo "WARNING: /sys/power/wake_lock not writable; suspend may occur"
fi

# IMPORTANT: do NOT release this lock when this orchestrator exits. It exits
# as soon as the takeover daemon is launched, but the device stays headless
# (no One UI PowerManager) until the guest framework is up. Releasing here let
# the device suspend mid-boot, the softdog hrtimer stopped, and the kernel
# panicked 100 s later (2026-10-29). The lock is released by
# return_to_oneui.sh only after One UI is confirmed running again.

# Keep the host's watchdog path schedulable before the guest starts.
protect_host_cpu

# --- ADB TCP FALLBACK -----------------------------------------------------
# The guest's system_server reconfigures the USB gadget during boot and the
# host adbd can end up with a dead /dev/usb-ffs/adb/ep0 even though init still
# reports it as running. USB alone is then a single point of failure: without a
# shell there is no way to read logs or trigger a clean rollback. Keep a second
# channel over Wi-Fi. adbd listens on this port whenever it starts, so a
# watchdog restart re-creates the TCP listener even if USB is broken.
if [ "$(getprop service.adb.tcp.port)" != "5555" ]; then
    setprop service.adb.tcp.port 5555 2>/dev/null || true
    setprop ctl.stop adbd 2>/dev/null || true
    sleep 1
    setprop ctl.start adbd 2>/dev/null || true
    sleep 2
    echo "ADB TCP fallback enabled on port 5555 (ip: $(ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | cut -d' ' -f2))"
fi

# --- SOFTDOG FEEDER -------------------------------------------------------
# The HOST system_server is the only process that pings Samsung's software
# watchdog (/dev/watchdog1, soft_margin=100 soft_panic=1). We are about to kill
# it, and the guest's GSI system_server has no Samsung softdog feeder, so the
# timer would expire exactly 100 s later:
#   Kernel panic - not syncing: Software Watchdog Timer expired 100s
# Start the feeder BEFORE One UI is stopped so it can capture system_server's
# watchdog fd; it waits for system_server to exit and then feeds the device for
# the whole guest session. return_to_oneui.sh stops it before restarting the
# host zygote so the new system_server can open the device.
rm -f "$STAGE/stop_softdog_kicker" "$STAGE/softdog_kicker.pid"
if [ -f "$STAGE/softdog_kicker.sh" ]; then
    chmod 755 "$STAGE/softdog_kicker.sh" 2>/dev/null || true
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh "$STAGE/softdog_kicker.sh" </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh "$STAGE/softdog_kicker.sh" </dev/null >/dev/null 2>&1 &
    fi
    echo "Softdog kicker started (pid $!)"
else
    echo "WARNING: softdog_kicker.sh missing; the kernel softdog may panic 100s after system_server dies"
fi

# --- IMS / SMS REGISTRATION GATE -----------------------------------------
# The guest has no ImsService of its own, so the modem's IMS registration is
# owned by One UI's imsd and survives the takeover. That registration is what
# makes SMS behave: with it, T-Mobile delivers inbound SMS promptly (Samsung's
# RIL hands SMSoIP messages to the framework as normal SMS) and the modem
# accepts mobile-originated SMS. Without it, voice sits OUT_OF_SERVICE, sends
# fail with RESULT_ERROR_NO_SERVICE and inbound codes fall back to the SMSC
# retry schedule, arriving 20-40 minutes late - and every radio nudge then
# appears to "magically" deliver them.
# So: make sure imsd is up, and give the modem a moment to (re)register before
# the pivot. Never stop imsd afterwards; killing it was what degraded SMS.
if ! pidof imsd >/dev/null 2>&1; then
    setprop ctl.start imsd 2>/dev/null || true
fi
ims_i=0
ims_st=1
while [ "$ims_i" -lt 45 ]; do
    if dumpsys telephony.registry 2>/dev/null | grep -q 'mVoiceRegState=0'; then
        ims_st=0
        break
    fi
    ims_i=$((ims_i + 1))
    sleep 2
done
echo "IMS gate: voiceRegState=$ims_st after $((ims_i * 2))s, imsd=${ims_pid:-$(pidof imsd)}"

# --- ADB WATCHDOG ---------------------------------------------------------
# adb is the only way into the phone while Lineage is up (until wifi is
# configured), and the host adbd occasionally dies or loses the adb function
# when the container's system_server touches the USB configuration. init does
# not reliably restart it, which is the "adb randomly stopped working" symptom.
# Keep it supervised from the host namespace for the whole session; the watchdog
# is stopped again by return_to_oneui.sh.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "adb_watchdog.sh"; then
    cat > /data/local/tmp/adb_watchdog.sh <<'ADBW'
#!/system/bin/sh
# Watchdog for the host adbd, which is the only way into the phone while Lineage
# is up. Failure modes handled:
#   1. the host adbd died -> ask init to start it again;
#   2. the guest started its own adbd inside the container namespace and the two
#      fight over /dev/usb-ffs/adb/ep0 (observed 2026-10-29: the guest adbd kept
#      logging "transport endpoint shutdown" and the PC saw an offline device
#      with no serial) -> kill the guest adbd, keep the host one;
#   3. the USB gadget lost the adb function -> re-apply it;
#   4. USB is unusable -> the TCP fallback on service.adb.tcp.port=5555 still
#      gives a shell over Wi-Fi, and a restarted adbd re-creates that listener.
LOG=/data/local/tmp/adb_watchdog.log
SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
last_toggle=0
echo "$(date) adb watchdog started (ns=$SELF_NS, tcp=$(getprop service.adb.tcp.port))" >> "$LOG"
while true; do
    sleep 5
    host_adbd=""
    for p in $(pidof adbd 2>/dev/null); do
        pns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
        [ -n "$pns" ] || continue
        if [ -n "$SELF_NS" ] && [ "$pns" != "$SELF_NS" ]; then
            kill -9 "$p" 2>/dev/null && echo "$(date) killed guest adbd $p" >> "$LOG"
        else
            host_adbd="$p"
        fi
    done
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ -z "$host_adbd" ]; then
        setprop ctl.start adbd 2>/dev/null
        echo "$(date) host adbd missing; started (svc=$st usb.state=$usb usb.config=$cfg)" >> "$LOG"
    fi
    # Re-assert the TCP port so any adbd restart also re-creates the Wi-Fi
    # listener. This does not disturb a running adbd.
    [ "$(getprop service.adb.tcp.port)" = "5555" ] || setprop service.adb.tcp.port 5555 2>/dev/null
    case "$cfg" in
        *adb*) ;;
        *)
            setprop sys.usb.config "$cfg,adb" 2>/dev/null
            echo "$(date) added adb to usb.config (was: $cfg)" >> "$LOG"
            ;;
    esac
    case "$usb" in
        *adb*) ;;
        "")
            ;;
        *)
            now=$(date +%s 2>/dev/null || echo 0)
            if [ $((now - last_toggle)) -gt 60 ]; then
                last_toggle=$now
                echo "$(date) gadget lost adb, toggling (state: $usb, config: $cfg)" >> "$LOG"
                setprop sys.usb.config none 2>/dev/null
                sleep 1
                setprop sys.usb.config rndis,adb 2>/dev/null
                sleep 2
                setprop ctl.start adbd 2>/dev/null
            fi
            ;;
    esac
done
ADBW
    chmod 755 /data/local/tmp/adb_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "adbd watchdog started (log: /data/local/tmp/adb_watchdog.log)"
fi

# --- IMS KEEPALIVE --------------------------------------------------------
# imsd is the daemon holding the modem's IMS registration (see the IMS gate
# above). init does not always bring it back if it dies, and a dead imsd means
# SMS quietly degrades to "arrives whenever the SMSC next retries", so keep it
# supervised for the whole Lineage session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "ims_watchdog.sh"; then
    cat > /data/local/tmp/ims_watchdog.sh <<'IMSW'
#!/system/bin/sh
LOG=/data/local/tmp/ims_watchdog.log
while true; do
    sleep 60
    if ! pidof imsd >/dev/null 2>&1; then
        setprop ctl.start imsd 2>/dev/null
        echo "$(date) restarted imsd (was missing)" >> "$LOG"
    fi
done
IMSW
    chmod 755 /data/local/tmp/ims_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "imsd keepalive started (log: /data/local/tmp/ims_watchdog.log)"
fi

# Set permissive privapp permissions to avoid Signature|privileged fatal exceptions
set_prop ro.control_privapp_permissions log

# --- ONEUI PROTECTION & RESCUEPARTY DISABLE ---
echo "=== [1/6] Protecting OneUI Home Screen and Disabling RescueParty ==="
set_prop persist.sys.disable_rescue true
set_prop sys.rescue_boot_count 0
mkdir -p "$BACKUP_DIR"
if [ -d "/data/user/0/com.sec.android.app.launcher/databases" ]; then
    cp -a /data/user/0/com.sec.android.app.launcher/databases/* "$BACKUP_DIR/" 2>/dev/null || true
    echo "One UI Home databases snapshotted to $BACKUP_DIR"
fi

# --- AUDIO LOW LATENCY TUNING ---
# Deep buffer must stay OFF. Tested live: with audio.deep_buffer.media=true the
# deep-buffer output opens but never consumes, and an AudioTrack write blocks
# forever (app_process hung in futex_wait). The 20 ms normal path is the one
# that actually works; a streamed tone on it is clean (0 underruns, 0 late
# writes). Offload stays off: no working vendor DSP session in the container.
echo "=== [2/6] Configuring Low-Latency Audio ==="
set_prop audio.offload.disable 1
set_prop audio.deep_buffer.media false
set_prop audio.offload.video false
set_prop vendor.audio.offload.track.enable false

# --- NETWORK BPF FIREWALL & DNS BYPASS ---
echo "=== [3/6] Configuring Network BPF Filters ==="
bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_configuration_map key hex 00 00 00 00 value hex 00 00 00 00 2>/dev/null || true
chmod 666 /dev/socket/dnsproxyd 2>/dev/null || true

# --- VERIFY STAGING ENVIRONMENT ---
echo "=== [4/6] Verifying Staging Environment ==="
if [ ! -f "$STAGE/system.raw" ]; then
    echo "ERROR: LineageOS system image ($STAGE/system.raw) not found!"
    echo "Please tap 'Download LineageOS' in the app first."
    exit 1
fi

# Ensure all scripts and engine binaries exist in $STAGE.
#
# The app re-extracts its APK assets into files/ on every launch, so a blind
# `cp -f` here would overwrite scripts pushed to the stage for testing. That is
# how the pre-unshare takeover script survived a reboot, pivoted the host root
# and made the rollback unmount its own /system. Replace a staged file only
# when it is missing or older than the installed APK; a file pushed after the
# install is newer and wins.
mkdir -p "$STAGE/data"
APP_FILES="/data/user/0/com.wewaffles.onelineage/files"
APP_PKG="com.wewaffles.onelineage"
APK_PATH=$(pm path "$APP_PKG" 2>/dev/null | sed -n 's/^package://p' | head -n 1)
APK_MTIME=0
if [ -n "$APK_PATH" ]; then
    APK_MTIME=$(stat -c %Y "$APK_PATH" 2>/dev/null || $BB stat -c %Y "$APK_PATH" 2>/dev/null || echo 0)
fi
if [ -d "$APP_FILES" ]; then
    for f in "$APP_FILES"/*; do
        [ -f "$f" ] || continue
        base=${f##*/}
        dst="$STAGE/$base"
        dst_mtime=0
        [ -e "$dst" ] && dst_mtime=$(stat -c %Y "$dst" 2>/dev/null || $BB stat -c %Y "$dst" 2>/dev/null || echo 0)
        if [ ! -e "$dst" ] || [ "$dst_mtime" -lt "$APK_MTIME" ]; then
            cp -f "$f" "$dst" 2>/dev/null || true
        fi
    done
fi
chmod 755 "$STAGE"/*.sh "$STAGE/zygote_exec" 2>/dev/null || true
echo "Staged assets: $(ls -l "$STAGE/switch_to_lineage.sh" "$STAGE/master_inner.sh" 2>/dev/null | $BB awk '{print $6, $7, $8, $9}')"

# --- STOP HOST DAEMONS & LAUNCH CONTAINER ---
echo "=== [5/6] Stopping One UI and handing over media/wifi ==="
# This must happen BEFORE master_prepare.sh. Prep bind-mounts the staged
# /data/{app,user,...} trees over the host's real ones so the host's installd
# and artd write into the guest. If One UI is still running while those bridges
# are active, its zygote/system_server crash-loop on the guest data and the
# host watchdog can panic before the guard is even started. The IMS gate above
# already ran while One UI was alive, so stopping it now is safe.
# Kill leftovers from a previous session and clear per-session health flags
# BEFORE starting the new suppress loops. These pkill patterns match the new
# loops' own command lines, so running them later would kill the suppression
# that keeps Samsung init from resurrecting the host media stack mid-boot.
pkill -9 -f "guest_guard.sh" 2>/dev/null || true
pkill -9 -f "UI Activator" 2>/dev/null || true
pkill -9 -f "onelineage_media_suppress" 2>/dev/null || true
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
rm -f "$STAGE/ui_ready" "$STAGE/guard_triggered" "$STAGE/stop_guard" "$STAGE/media_suppress.pid"
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
setprop ctl.stop zygote
setprop ctl.stop surfaceflinger
# cameraserver is deliberately left running. The guest shares this binder
# namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). The host audioserver is
# therefore stopped only in the media handover below, and master_inner.sh starts
# the GSI's audioserver before zygote so media.audiopolicy is registered again.
# Freezing a server with kill -STOP is the worst of both worlds - the binder
# registration survives while the process can never answer.
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true
kill -9 $(pidof app_process64) 2>/dev/null || true
kill -9 $(pidof zygote_exec) 2>/dev/null || true
kill -9 $(pidof zygote64) 2>/dev/null || true
kill -9 $(pidof system_server) 2>/dev/null || true
sleep 1

# --- MEDIA STACK HANDOVER ---
# The guest's MediaCodecList does NOT ask the `media.codec` service for its
# codec list. AOSP's MediaCodecList::getRemoteInstance() gets `media.player`
# (mediaserver) and calls IMediaPlayerService::getCodecList(); MediaPlayerService
# returns MediaCodecList::getLocalInstance() from the HOST. Keeping mediaserver
# alive therefore keeps Samsung's incompatible IMediaCodecList alive, and the
# guest parses it with its own parcel layout until the CPU/watchdog dies.
#
# Samsung's init services are named after the process, not the binder service:
#   media          -> /system/bin/mediaserver      -> media.player/resource_*
#   mediaextractor -> /system/bin/mediaextractor   -> media.extractor
#   mediametrics   -> /system/bin/mediametrics     -> media.metrics
#   media.swcodec  -> .../bin/mediaswcodec         -> media.c2 (software)
# `media.codec` is the vendor OMX HAL (init service vendor.media.omx), not a
# platform service. Leave it and the vendor C2/DRM HALs running: the guest uses
# them through stable AIDL/HIDL for hardware codecs.
#
# master_inner.sh starts the GSI's own mediaextractor/mediametrics/mediaswcodec/
# mediaserver64/audioserver after pivot_root, so media.player/media.c2 and
# media.audiopolicy belong to the guest and MediaPlayer/AudioService have
# working services.
HOST_MEDIA_SVCS="media mediaextractor mediametrics media.swcodec audioserver"
for svc in $HOST_MEDIA_SVCS; do
    setprop ctl.stop "$svc" 2>/dev/null || true
done
# init names argv[0] after the service, so pidof needs media.metrics and
# media.extractor rather than mediametrics/mediaextractor.
for p in mediaserver media.metrics media.extractor media.swcodec audioserver; do
    kill -9 $(pidof "$p") 2>/dev/null || true
done
# Catch stragglers by cmdline too. Do NOT match media.codec: that is the vendor
# OMX HAL, which the guest still needs.
pkill -9 -f "/system/bin/mediaserver" 2>/dev/null || true
pkill -9 -f "/system/bin/mediaextractor" 2>/dev/null || true
pkill -9 -f "/system/bin/mediametrics" 2>/dev/null || true
pkill -9 -f "mediaswcodec" 2>/dev/null || true
pkill -9 -f "/system/bin/audioserver" 2>/dev/null || true

# Wait until the service names are actually gone. If a host mediaserver is still
# registered, the guest's mediaserver cannot claim media.player and falls back
# to the incompatible host list again. media.c2 is registered as the AIDL
# interface name with the "software" instance, not as "media.c2".
MEDIA_SVC_RE='media\.(player|extractor|metrics|resource_manager|resource_observer)|android\.hardware\.media\.c2\.IComponentStore/software'
i=0
while [ $i -lt 50 ]; do
    service_list | grep -qE "$MEDIA_SVC_RE" || break
    i=$((i+1))
    sleep 0.1
done
if service_list | grep -qE "$MEDIA_SVC_RE"; then
    echo "WARNING: host media services still registered after stop:"
    service_list | grep -E "$MEDIA_SVC_RE" || true
fi

# Keep Samsung init from resurrecting the host media stack while Lineage owns
# the service names. The guest's media processes are not init services, so this
# loop only affects the host.
nohup $BB sh -c '
  # onelineage_media_suppress
  while true; do
    for svc in media mediaextractor mediametrics media.swcodec audioserver; do
      [ "$(getprop init.svc.$svc)" = "running" ] && setprop ctl.stop "$svc"
    done
    sleep 1
  done
' </dev/null >/dev/null 2>&1 &
echo $! > "$STAGE/media_suppress.pid"
echo "Host media stack stopped; guest media stack will start after pivot."

# --- BIOMETRIC TEE GUARD ---
# The guest's GSI FingerprintService binds the host's vendor HAL and calls
# setActiveUser(0) with the guest's own gatekeeper SID. The fingerprint TA keys
# its templates by that SID, so a guest session can invalidate the host's
# enrolled fingerprints (observed 2026-10-29: One UI asked to re-enrol after the
# guest ran). The guest does not need biometrics, so stop both vendor HALs for
# the session and restart them before host zygote in return_to_oneui.sh.
for svc in vendor.fps_hal sec-biometrics-face-aidl; do
    setprop ctl.stop "$svc" 2>/dev/null || true
done
pkill -9 -f "vendor.samsung.hardware.biometrics.fingerprint@3.0-service" 2>/dev/null || true
pkill -9 -f "vendor.samsung.hardware.biometrics.face-service" 2>/dev/null || true
echo "Host biometric HALs stopped (TEE templates protected)"

# Same handover for wifi. The guest's WifiService binds IWificond (service
# "wifinl80211") and drives the vendor HAL through it. Samsung's wificond is
# still holding the client interface that One UI's (now dead) WifiService
# created, so every startScan() comes back "status: -1" and the framework sees
# "No scan results" - wifi looks broken but only the scanner is wedged. The
# GSI's own wificond starts in master_inner.sh and scans fine against the same
# vendor HAL.
setprop ctl.stop wificond 2>/dev/null || true
kill -9 $(pidof wificond) 2>/dev/null || true
sleep 1

# Suppress the host zygote only, so Samsung init does not resurrect it.
# The old check watched the global init.svc.zygote property: when the guest
# init started its own zygote, the property became "running" and this loop
# sent ctl.stop zygote, killing the guest's zygote too (observed 2026-10-30:
# surfaceflinger/media came up but no zygote/system_server ever appeared).
# Compare the mount namespace instead and only stop host-namespace zygotes.
HOST_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
nohup $BB sh -c '
  HOST_NS="$1"
  while true; do
    for p in $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
      ns=$(readlink /proc/$p/ns/mnt 2>/dev/null)
      if [ -n "$ns" ] && [ "$ns" = "$HOST_NS" ]; then
        setprop ctl.stop zygote
        break
      fi
    done
    sleep 1
  done
' sh "$HOST_NS" </dev/null >/dev/null 2>&1 &

# Copy inner script and zygote_exec into container data partition
cp -f "$STAGE/master_inner.sh" "$STAGE/data/master_inner.sh"
chmod 755 "$STAGE/data/master_inner.sh"
cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
chmod 755 "$STAGE/data/zygote_exec"

# --- MOUNT PREPARATION ---
echo "=== [6/6] Executing Mount Hierarchy Preparation ==="
# Drop markers from a previous session. master_prepare.sh rewrites
# guest_root_src, and master_inner.sh rewrites guest_mnt_ns once it has entered
# the private namespace. A stale namespace would make guest_guard.sh believe a
# dead guest is healthy.
rm -f "$STAGE/guest_mnt_ns" "$STAGE/guest_root_src"
/system/bin/sh "$STAGE/master_prepare.sh"
PREP_RET=$?
if [ $PREP_RET -ne 0 ]; then
    echo "ERROR: master_prepare.sh failed (code $PREP_RET)!"
    # One UI is already stopped at this point, and the softdog feeder is holding
    # the kernel watchdog. Roll back instead of exiting headless.
    /system/bin/sh "$STAGE/return_to_oneui.sh" >> "$STAGE/guest_guard.log" 2>&1
    exit 1
fi

# Start the host-side guard BEFORE the guest. If the takeover ever runs in the
# host mount namespace by mistake, the guard must already be alive in the real
# host namespace so its rollback still sees /system.
if [ -f "$STAGE/guest_guard.sh" ]; then
    chmod 755 "$STAGE/guest_guard.sh" 2>/dev/null || true
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh "$STAGE/guest_guard.sh" </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh "$STAGE/guest_guard.sh" </dev/null >/dev/null 2>&1 &
    fi
    echo "Guest health guard started."
else
    echo "WARNING: guest_guard.sh missing; no automatic rollback on media storm."
fi

# Launch takeover inside an isolated mount namespace.
$BB unshare -m $BB sh "$STAGE/data/master_inner.sh" </dev/null >"$STAGE/data/takeover.log" 2>&1 &
TAKEOVER_PID=$!
echo "Takeover daemon PID: $TAKEOVER_PID"
$BB sleep 1
TAKEOVER_NS=$(readlink "/proc/$TAKEOVER_PID/ns/mnt" 2>/dev/null)
HOST_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
echo "Takeover mount namespace: ${TAKEOVER_NS:-unknown} (host: ${HOST_NS:-unknown})"
if [ -z "$TAKEOVER_NS" ] || [ "$TAKEOVER_NS" = "$HOST_NS" ]; then
    echo "FATAL: takeover did not get a private mount namespace; aborting before pivot."
    kill -9 "$TAKEOVER_PID" 2>/dev/null || true
    /system/bin/sh "$STAGE/return_to_oneui.sh" >> "$STAGE/guest_guard.log" 2>&1
    exit 1
fi

# Start UI Activator daemon
$BB sh -c "
BB=\"$BB\"
[ -n \"\$BB\" ] || BB=\$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
i=0
DONE=
while [ \$i -lt 300 ]; do
    i=\$((i + 1))
    sleep 2
    [ -f \"\$STAGE/guard_triggered\" ] && { echo '[UI Activator] Guard triggered; exiting.'; break; }
    PID=\$(pidof system_server | awk '{print \$1}')
    if [ -n \"\$PID\" ]; then
        if $BB timeout -s KILL 10 $BB nsenter -t \$PID -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'; then
            DONE=1
            echo '[UI Activator] WindowManager is ready; waiting for boot completion...'
            setprop service.bootanim.exit 1
            kill -9 \$(pidof bootanimation) 2>/dev/null
            sleep 1

            # Do not unlock or start Home until the guest framework has finished
            # booting. In the 19:52 run the activator fired as soon as
            # WindowManager appeared, the launcher's TouchInteractionService
            # started at 19:52:00 -- before BOOT_COMPLETED at 19:52:07 -- and
            # OverviewComponentObserver crashed because
            # resolveActivity(MAIN/HOME) returned null while PMS was settling.
            b=0
            BC=
            while [ \$b -lt 90 ]; do
                BC=\$($BB nsenter -t \$PID -m /system/bin/getprop sys.boot_completed 2>/dev/null)
                [ \"\$BC\" = \"1\" ] && break
                b=\$((b + 1))
                sleep 2
            done
            echo \"[UI Activator] boot_completed=\$BC after \$((b * 2))s; settling\"
            # The property may still read 1 from One UI (it is not reset when the
            # host system_server is killed), so always give PMS/SystemUI a
            # settle window before unlocking the user and binding the launcher.
            sleep 15

            $BB nsenter -t \$PID -m /system/bin/svc power stayon true
            $BB nsenter -t \$PID -m /system/bin/settings put global stay_on_while_plugged_in 7
            $BB nsenter -t \$PID -m /system/bin/settings put system screen_off_timeout 2147483647
            $BB nsenter -t \$PID -m /system/bin/settings put system haptic_feedback_enabled 1
            $BB nsenter -t \$PID -m /system/bin/settings put system peak_refresh_rate 120.0
            $BB nsenter -t \$PID -m /system/bin/settings put system min_refresh_rate 120.0
            # Gesture navigation. The GSI boots with the three-button overlay, and
            # this line used to force it back on every takeover.
            $BB nsenter -t \$PID -m /system/bin/cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/settings put secure navigation_mode 2 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/pm disable android.ext.services/android.ext.services.notification.Assistant 2>/dev/null || true

            # Realign app data dirs BEFORE the launcher starts. master_prepare
            # pre-creates them as 1000:1000, but PMS expects the package uid
            # (launcher3=10131); that mismatch made prepareAppData fail and the
            # launcher crash on its first launch.
            echo '[UI Activator] Realigning app data dirs...'
            $BB nsenter -t \$PID -m /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/sh /data/local/tmp/ensure_app_storage.sh 2>/dev/null || true

            # The staged settings still name One UI's launcher, which does not
            # exist in the guest. Point Home at the GSI launcher explicitly.
            $BB nsenter -t \$PID -m /system/bin/cmd package set-home-activity --user 0 com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher 2>/dev/null || true

            $BB nsenter -t \$PID -m /system/bin/input keyevent 224
            $BB nsenter -t \$PID -m /system/bin/input keyevent 82
            $BB nsenter -t \$PID -m /system/bin/am unlock-user 0
            sleep 3
            $BB nsenter -t \$PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME

            # The system may restart a launcher that crashed during unlock. Keep
            # retrying Home until a launcher process survives two samples.
            l=0
            FOUND=
            while [ \$l -lt 12 ]; do
                # pidof matches the 15-char comm, which is not stable across
                # launcher builds (this one is com.android.launcher3, comm
                # "com.android.lau" or "droid.launcher3"). Match the full
                # cmdline instead, and require the process to survive two
                # samples.
                if $BB nsenter -t \$PID -m /system/bin/ps -A -o NAME,ARGS 2>/dev/null | grep -q 'com.android.launcher3'; then
                    sleep 3
                    if $BB nsenter -t \$PID -m /system/bin/ps -A -o NAME,ARGS 2>/dev/null | grep -q 'com.android.launcher3'; then
                        FOUND=1
                        break
                    fi
                fi
                l=\$((l + 1))
                echo \"[UI Activator] launcher not running; retry \$l/12\"
                $BB nsenter -t \$PID -m /system/bin/am force-stop com.android.launcher3 2>/dev/null || true
                sleep 5
                $BB nsenter -t \$PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true
            done
            if [ -z \"\$FOUND\" ]; then
                echo '[UI Activator] launcher never survived; rolling back.'
                /system/bin/sh \"\$STAGE/return_to_oneui.sh\"
                break
            fi
            echo \"[UI Activator] Home activated (launcher retries=\$l)!\"
            echo ok > \"\$STAGE/ui_ready\"

            # Install microG if requested
            if [ -f \"\$STAGE/install_microg.flag\" ]; then
                echo '[UI Activator] Installing microG components...'
                for apk in \"\$STAGE/GmsCore.apk\" \"\$STAGE/FakeStore.apk\" /data/local/tmp/GmsCore.apk /data/local/tmp/FakeStore.apk; do
                    if [ -f \"\$apk\" ]; then
                        echo \"[UI Activator] Installing \$apk...\"
                        \$BB nsenter -t \$PID -m /system/bin/pm install -r -g \"\$apk\" 2>/dev/null || true
                    fi
                done
                rm -f \"\$STAGE/install_microg.flag\" 2>/dev/null || true
            fi

            # Populate network permissions for all installed packages
            for uid in \$($BB nsenter -t \$PID -m /system/bin/pm list packages -U 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | sort -u); do
                [ -n \"\$uid\" ] || continue
                b0=\$(printf \"%02x\" \$((uid & 0xff)))
                b1=\$(printf \"%02x\" \$(((uid >> 8) & 0xff)))
                b2=\$(printf \"%02x\" \$(((uid >> 16) & 0xff)))
                b3=\$(printf \"%02x\" \$(((uid >> 24) & 0xff)))
                bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_uid_permission_map key hex \$b0 \$b1 \$b2 \$b3 value hex 0c 2>/dev/null || true
            done

            # Ensure default routing
            DEF_IF=\$(ip route | grep -o 'dev [^ ]*' | head -n 1 | awk '{print \$2}')
            [ -n \"\$DEF_IF\" ] && ip route add default dev \"\$DEF_IF\" 2>/dev/null || true

            # Mount emulated primary storage
            $BB nsenter -t \$PID -m /system/bin/sm mount \"emulated;0\" 2>/dev/null || true
            break
        fi
    fi
done
if [ -z \"\$DONE\" ]; then
    echo '[UI Activator] Timeout waiting for WindowManager; rolling back.'
    /system/bin/sh \"\$STAGE/return_to_oneui.sh\"
fi
" </dev/null >/data/local/tmp/ui_activator.log 2>&1 &

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="
