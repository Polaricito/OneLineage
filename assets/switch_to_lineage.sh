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
    echo "onelineage_takeover" > /sys/power/wake_lock 2>/dev/null && \
        echo "Wake lock acquired: onelineage_takeover"
else
    echo "WARNING: /sys/power/wake_lock not writable; suspend may occur"
fi

# Release the wake lock on exit (rollback, success, or error).
release_wakelock() {
    if [ -w /sys/power/wake_unlock ]; then
        echo "onelineage_takeover" > /sys/power/wake_unlock 2>/dev/null && \
            echo "Wake lock released"
    fi
}
trap release_wakelock EXIT INT TERM

# Keep the host's watchdog path schedulable before the guest starts.
protect_host_cpu

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
# is up. Two failure modes are handled:
#   1. adbd simply died -> ask init to start it again.
#   2. adbd is alive but the USB gadget lost the adb function. The guest's own
#      UsbService rewrites sys.usb.config during boot, and a plain setprop is a
#      no-op in that state, so the gadget has to be re-applied by toggling it.
LOG=/data/local/tmp/adb_watchdog.log
last_toggle=0
while true; do
    sleep 10
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ "$st" != "running" ]; then
        setprop ctl.start adbd 2>/dev/null
        echo "$(date) restarted adbd (was: $st, usb.state=$usb, usb.config=$cfg)" >> "$LOG"
    fi
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
            if [ $((now - last_toggle)) -gt 300 ]; then
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
pkill -9 -f "onelineage_media_suppress" 2>/dev/null || true
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
rm -f "$STAGE/ui_ready" "$STAGE/guard_triggered" "$STAGE/stop_guard" "$STAGE/media_suppress.pid"
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
setprop ctl.stop zygote
setprop ctl.stop surfaceflinger
# audioserver/cameraserver are deliberately left running. The guest shares this
# binder namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). Freezing them with
# kill -STOP is the worst of both worlds - the binder registration survives
# while the process can never answer.
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
# mediaserver64 after pivot_root, so media.player/media.c2 belong to the guest
# and MediaPlayer still has a working service.
HOST_MEDIA_SVCS="media mediaextractor mediametrics media.swcodec"
for svc in $HOST_MEDIA_SVCS; do
    setprop ctl.stop "$svc" 2>/dev/null || true
done
# init names argv[0] after the service, so pidof needs media.metrics and
# media.extractor rather than mediametrics/mediaextractor.
for p in mediaserver media.metrics media.extractor media.swcodec; do
    kill -9 $(pidof "$p") 2>/dev/null || true
done
# Catch stragglers by cmdline too. Do NOT match media.codec: that is the vendor
# OMX HAL, which the guest still needs.
pkill -9 -f "/system/bin/mediaserver" 2>/dev/null || true
pkill -9 -f "/system/bin/mediaextractor" 2>/dev/null || true
pkill -9 -f "/system/bin/mediametrics" 2>/dev/null || true
pkill -9 -f "mediaswcodec" 2>/dev/null || true

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
    for svc in media mediaextractor mediametrics media.swcodec; do
      [ "$(getprop init.svc.$svc)" = "running" ] && setprop ctl.stop "$svc"
    done
    sleep 1
  done
' </dev/null >/dev/null 2>&1 &
echo $! > "$STAGE/media_suppress.pid"
echo "Host media stack stopped; guest media stack will start after pivot."

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

# Suppress the host zygote only, so Samsung init does not resurrect it
nohup $BB sh -c "while true; do [ \"\$(getprop init.svc.zygote)\" = \"running\" ] && setprop ctl.stop zygote; sleep 1; done" </dev/null >/dev/null 2>&1 &

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
while [ \$i -lt 100 ]; do
    i=\$((i + 1))
    sleep 2
    [ -f \"\$STAGE/guard_triggered\" ] && { echo '[UI Activator] Guard triggered; exiting.'; break; }
    PID=\$(pidof system_server | awk '{print \$1}')
    if [ -n \"\$PID\" ]; then
        if $BB nsenter -t \$PID -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'; then
            echo '[UI Activator] WindowManager is ready! Dismissing bootanim and unlocking...'
            setprop service.bootanim.exit 1
            kill -9 \$(pidof bootanimation) 2>/dev/null
            sleep 1
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
            $BB nsenter -t \$PID -m /system/bin/input keyevent 224
            $BB nsenter -t \$PID -m /system/bin/input keyevent 82
            $BB nsenter -t \$PID -m /system/bin/am unlock-user 0
            $BB nsenter -t \$PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME
            echo '[UI Activator] Home activated!'
            echo ok > \"\$STAGE/ui_ready\"
            echo '[UI Activator] Creating missing app data dirs...'
            $BB nsenter -t \$PID -m /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true

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
if [ \$i -ge 100 ]; then
    echo '[UI Activator] Timeout waiting for WindowManager; rolling back.'
    /system/bin/sh \"\$STAGE/return_to_oneui.sh\"
fi
" </dev/null >/data/local/tmp/ui_activator.log 2>&1 &

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="
