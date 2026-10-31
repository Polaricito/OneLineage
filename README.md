# OneLineage

 **NOTE: OneLineage is just a proof of concept, this repo should provide you with enough to port other roms to bootloader locked devices, the lineageos with this repo is just a demo of this capability, and therefore does not fully work. Have fun!**

Hot-switch between stock **One UI** and a **LineageOS 23.2 (Android 16) GSI** on a rooted Samsung phone, with no reflashing and no second partition. OneLineage stages the GSI under `/data/local/tmp`, pivots into it as a container with its own zygote and system_server, and can hand the screen back to One UI.

> ## Disclaimer
> **This has been tested on only a handful of devices, and it seems if you want to install it without making modifications, it has to be on Android 16**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

## Current state (5.19 / versionCode 24)
- **Commit:** `dada0f3` on `https://github.com/Polaricito/OneLineage.git`
- **APK:** `OneLineage-5.19.apk` (SHA-256 `3bdf30a8f0a983cc7e64ce789910fc9f15fe4828781082b3e6f72045fe447989`)
- **Tested device:** SM-A536E (`a53xnsxx` / `a53x`), Android 16, One UI — not just the maintainer's S26 Ultra.
- **Works:** guest zygote + system_server start, guest UI ready in ~140 s, SIM registers (LOADED / LTE IN_SERVICE / voice+SMS+DATA), Trebuchet launcher + systemui + phone run, audioserver + mediaserver64 + media.swcodec run, guest can take screenshots once storage is free, cold-boot rollback returns to One UI without a stuck boot screen, softdog feeder keeps `/dev/watchdog1` alive so the kernel doesn't panic, host biometric HALs restart on rollback, ADB TCP fallback on port 5555 during takeover.
- **Fixed in 5.19:** zygote abort (`JNI FatalError: Not allowlisted (54): /data/zygote_stderr.log`) — `zygote_exec` stdio now goes to `/dev/null` and the wrapper keeps no `/data` fd open while zygote lives; rollback uses `reboot -f` instead of `setprop sys.powerctl reboot` (init's shutdown stalled on guest bridges and powered the phone off); `return_to_oneui.sh` writes `reboot_diag.log` before rebooting; stage sync only replaces files older than the installed APK; host zygote suppression is namespace-aware so the guest's own zygote isn't killed.
- **Budgets:** 360 s system_server / 720 s UI-ready guard deadlines, 300-iteration (~600 s) UI Activator.

## Requirements
- A rooted Samsung phone (tested on SM-A536E and S26 Ultra)
- Enough free space on `/data` for the extracted GSI (guest needs several GB free to launch apps, take screenshots, etc.)
- Internet access for the GSI download (LineageOS 23.2 GSI, EXT4, VANILLA or GAPPS builds from SourceForge)

## What's in here
| Path | What it is |
| --- | --- |
| `src/`, `res/`, `AndroidManifest.xml` | The Android app (`com.wewaffles.onelineage`) |
| `assets/master_prepare.sh` | Stages the rootfs, binds the patched files, fixes labels/ownership |
| `assets/master_inner.sh` | Runs inside the container, starts the guest media stack and zygote |
| `assets/switch_to_lineage.sh` / `return_to_oneui.sh` | Switch in and back out |
| `assets/guest_guard.sh` | Host-side watchdog/media-storm guard with automatic rollback |
| `assets/preflight.sh` | Collects model, watchdog, media, SELinux and storage diagnostics |
| `assets/zygote_exec` | Static aarch64 launcher for the guest zygote |
| `build_apk.sh` | Builds and signs the APK (portable paths, SDK auto-detection) |

## Patches

### Patched system files (bind-mounted over the GSI)
- `services_patched.jar` over `system/framework/services.jar`
- `framework_patched.jar` over `system/framework/framework.jar`
- `PermissionController_patched.apk`: removes the `android.permission.RANGING` reference so runtime-permission dialogs stop crashing (Samsung's PermissionController needs a permission the LineageOS 23.2 platform doesn't define)
- Optional bind-mounts when present: `framework-res_patched.apk`, `libaudio_aidl_conversion_common_cpp_patched.so`, `libaudioclient_aidl_conversion_patched.so`

### Boot and environment fixes
1. **APEX paths in the container.** Host `/system/apex` and `/system_ext/apex` are bound into the rootfs after the GSI payloads are extracted, so PackageManagerService stops dying in `scanApexPackages`.
2. **SELinux labels on the staged `/data`.** The tree is relabeled like a real `/data` (`system_data_file`, per-package `app_data_file`) instead of `shell_data_file`. Also `setenforce 0` during the takeover and `setenforce 1` on return.
3. **Audio hang.** Host `audioserver`/`cameraserver` are left running (they used to be stopped/frozen, which deadlocked `AudioService`). Only the host zygote is suppressed.
4. **Runaway `sf.log`.** SurfaceFlinger output goes to `/dev/null` (it was growing to hundreds of MB in minutes).
5. **App data ownership.** `fix_app_dirs.sh` re-owns app data dirs to the uid PackageManager assigned, strips write bits from dex/apk/jar files (ART refuses writable dex), and creates missing dirs such as `/data/misc/bluedroid`.
6. **No installd.** `ensure_app_storage.sh` plus a 15 s sweeper create `/data/user/0`, `/data/user_de/0` and shared-storage dirs for new installs, so apps installed inside Lineage can launch.
7. **Gesture navigation.** Overlay idmaps are generated with `idmap2 --ignore-overlayable` before zygote starts.
8. **Bluetooth crash loop** fixed by creating `/data/misc/bluedroid` before boot.
9. **adb.** `Settings.Global.ADB_ENABLED` is pre-seeded, host `adb_keys` are copied into the guest, and `adb_watchdog.sh` keeps adbd and the USB gadget alive.
10. **Networking.** The preferred APN is switched to `IPV4V6`, and `net_fix.sh` maintains a private routing table (4242) because the guest's ConnectivityService can't program the host's netd.
11. **SMS.** `ims_watchdog.sh` keeps One UI's `imsd` running and `switch_to_lineage.sh` waits for voice registration before pivoting.
12. **Boot diagnostics.** Each boot writes `/data/boot_failures.log`; the app's **Run diagnostics** button (or `preflight.sh` over adb) captures model, SELinux, watchdog, media-service, storage and dmesg state.
13. **Media handover and watchdog safety.** The host's platform media services (`media`, `mediaextractor`, `mediametrics`, `media.swcodec`) are stopped, while vendor C2/OMX/DRM HALs keep running. Inside the container the GSI's own `mediaserver64`, `mediaextractor`, `mediametrics` and `mediaswcodec` start from the GSI media APEX payloads; Samsung's media APEXes are never bound. `MediaCodecList` therefore gets a compatible `IMediaCodecList` from the guest instead of parsing Samsung's parcel layout in a loop. `watchdogd`, `logd`, `adbd`, `imsd` and `netd` are pinned to CPU 0, `watchdogd` gets RT priority, and the guest runs on CPUs 1..N-1. `guest_guard.sh` samples the log tail and `dmesg` and rolls back to One UI before the ~100 s watchdog panic.

## Known issues
- **Rollback:** Fixed in 5.19 — `return_to_oneui.sh` defaults to a cold reboot (`reboot -f`) so One UI comes back cleanly instead of a stuck boot screen. `ROLLBACK_REBOOT=0` keeps the old in-place restart for debugging.
- **No IMS in the guest** — give up on this: no LineageOS ROM has IMS support (only One UI-based ROMs do). Voice calls don't work in the guest; data and SMS ride One UI's `imsd`. Don't spend more time here.
- **WiFi:** shows "connected" but no internet in the guest. Needs investigation of the guest's netd/wificond vs the host's bridged interfaces (priority for next session).
- **Storage:** the guest needs several GB free on `/data` to launch apps and take screenshots; free up ~5 GB or add a storage-cleanup step before takeover (priority for next session).
- **Camera:** the camera app reports "camera in use" but doesn't actually work. Needs the guest's camera HAL vs the host's bridged camera service sorted out (priority for next session).
- Developer options crash (the guest registers no `adb` service).
- DTMF tones glitch, and deep-buffer audio hangs, so it stays disabled.
- Never kill the host `netd` while Lineage is running.

## Next steps (next session)
1. Guest WiFi: connected but no internet — trace `netd`/`wificond` in the guest, check the private routing table (4242) and the APN switch to `IPV4V6`.
2. Free ~5 GB on `/data` for the guest so apps launch and screenshots work; add a storage check/cleanup to `preflight.sh` or `master_prepare.sh`.
3. Guest camera "in use" but non-functional — reconcile the guest camera HAL with the host camera service.
4. Re-verify on SM-A536E after each fix: SIM registration, audio/media, launcher, cold-boot rollback, `reboot_diag.log`.
5. Commit/push progress checkpoints so nothing is lost.

## Building
`build_apk.sh` auto-detects the Android SDK (`ANDROID_SDK_ROOT`/`ANDROID_HOME`, then the usual Windows/macOS/Linux locations), the newest installed build-tools and the android-34 platform. It creates a debug keystore on first use and writes `OneLineage-5.19.apk` in the project root.

Requirements: JDK 17+ and Android SDK build-tools **36.0.0** (build-tools 34's `d8` crashes on the enum in `MainActivity` under JDK 21), plus platform 34. Install them with:

```sh
sdkmanager "platforms;android-34" "build-tools;36.0.0"
```

Then run:

```sh
./build_apk.sh
```

Override paths if needed:

```sh
ANDROID_SDK_ROOT=/path/to/sdk BUILD_TOOLS=/path/to/build-tools/36.0.0 ./build_apk.sh
```

To collect diagnostics on a device:

```sh
adb shell su -c 'sh /data/local/tmp/lineage_stage/preflight.sh'
```

### Upgrading a device to a new build

1. Bump `android:versionCode`/`android:versionName` in `AndroidManifest.xml`, `OUT_APK` in `build_apk.sh`, and the version in this README.
2. Run `./build_apk.sh`.
3. Install the new APK over the old one: `adb install -r OneLineage-5.19.apk`.
4. Force-stop the app (`adb shell am force-stop com.wewaffles.onelineage`) so a running process can't sync stale cached assets, then launch the app once. `extractAssets()` writes the new scripts into the app's `files/` directory and syncs them to `/data/local/tmp/lineage_stage`.
5. Compare an asset hash with the staged copy:

```sh
adb shell su -c 'sha256sum /data/local/tmp/lineage_stage/switch_to_lineage.sh'
adb shell su -c 'unzip -p $(pm path com.wewaffles.onelineage | sed s/package://) assets/switch_to_lineage.sh | sha256sum'
```

The sync is non-destructive: a staged script is replaced only when it is missing or older than the installed APK, so scripts pushed to `/data/local/tmp/lineage_stage` after the install (for testing) are kept.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
