#!/bin/bash
# Build OneLineage without Gradle.
#
# Works from Git Bash / MSYS on Windows, macOS and Linux. Override any of the
# variables below from the environment, e.g.:
#   ANDROID_SDK_ROOT=/path/to/sdk BUILD_TOOLS=/path/to/build-tools/34.0.0 ./build_apk.sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    PROJECT_DIR="$(cygpath -m "$PROJECT_DIR")"
fi

die() {
    echo "ERROR: $*" >&2
    exit 1
}

find_tool() {
    name="$1"
    for cand in "$BUILD_TOOLS/$name" "$BUILD_TOOLS/$name.exe" \
                "$BUILD_TOOLS/$name.bat" "$BUILD_TOOLS/$name.cmd"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# --- JDK -------------------------------------------------------------------
if [ -z "${JAVA_HOME:-}" ]; then
    if ! command -v javac >/dev/null 2>&1; then
        for d in "$HOME/Desktop/jdk-21.0.2" "/c/Program Files/Java"/* \
                 "/usr/lib/jvm"/*; do
            [ -x "$d/bin/javac" ] && JAVA_HOME="$d" && break
        done
    fi
fi
if [ -n "${JAVA_HOME:-}" ]; then
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
fi
JAVAC=$(command -v javac || true)
JAR=$(command -v jar || true)
KEYTOOL=$(command -v keytool || true)
[ -n "$JAVAC" ] || die "javac not found. Set JAVA_HOME to a JDK 17+ installation."
[ -n "$KEYTOOL" ] || die "keytool not found. Set JAVA_HOME to a JDK installation."

# --- Android SDK -----------------------------------------------------------
if [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    ANDROID_SDK_ROOT="${ANDROID_HOME:-}"
fi
if [ -z "$ANDROID_SDK_ROOT" ]; then
    for d in "$HOME/AppData/Local/Android/Sdk" "$LOCALAPPDATA/Android/Sdk" \
             "$HOME/Library/Android/sdk" "/opt/android-sdk" \
             "/usr/lib/android-sdk"; do
        [ -n "$d" ] && [ -d "$d" ] && ANDROID_SDK_ROOT="$d" && break
    done
fi
[ -n "$ANDROID_SDK_ROOT" ] && [ -d "$ANDROID_SDK_ROOT" ] || \
    die "Android SDK not found. Set ANDROID_SDK_ROOT (contains build-tools/ and platforms/)."

if [ -z "${BUILD_TOOLS:-}" ]; then
    BUILD_TOOLS=$(ls -1d "$ANDROID_SDK_ROOT"/build-tools/* 2>/dev/null | sort | tail -n 1)
fi
[ -n "$BUILD_TOOLS" ] && [ -d "$BUILD_TOOLS" ] || \
    die "build-tools not found under $ANDROID_SDK_ROOT/build-tools."

if [ -z "${PLATFORM_JAR:-}" ]; then
    if [ -f "$ANDROID_SDK_ROOT/platforms/android-34/android.jar" ]; then
        PLATFORM_JAR="$ANDROID_SDK_ROOT/platforms/android-34/android.jar"
    else
        PLATFORM_DIR=$(ls -1d "$ANDROID_SDK_ROOT"/platforms/android-* 2>/dev/null | sort | tail -n 1)
        PLATFORM_JAR="$PLATFORM_DIR/android.jar"
    fi
fi
[ -f "$PLATFORM_JAR" ] || die "android.jar not found. Install platform 34 with sdkmanager."

AAPT2=$(find_tool aapt2) || die "aapt2 not found in $BUILD_TOOLS"
D8=$(find_tool d8) || die "d8 not found in $BUILD_TOOLS"
ZIPALIGN=$(find_tool zipalign) || die "zipalign not found in $BUILD_TOOLS"
APKSIGNER=$(find_tool apksigner) || die "apksigner not found in $BUILD_TOOLS"

BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
OUT_APK="${OUT_APK:-$PROJECT_DIR/OneLineage-5.13.apk}"
KEYSTORE="${KEYSTORE:-$PROJECT_DIR/keystore/debug.keystore}"

echo "=== Build configuration ==="
echo "Project:      $PROJECT_DIR"
echo "SDK:          $ANDROID_SDK_ROOT"
echo "Build tools:  $BUILD_TOOLS"
echo "Platform jar: $PLATFORM_JAR"
echo "Output APK:   $OUT_APK"

echo "=== 1. Cleaning & preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

cd "$PROJECT_DIR"

echo "=== 2. Compiling resources with aapt2 ==="
"$AAPT2" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources with aapt2 ==="
"$AAPT2" link \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    -o "$BUILD_DIR/base.apk" \
    --java "$BUILD_DIR/gen" \
    "$BUILD_DIR/compiled_res.zip" \
    -A assets

echo "=== 4. Compiling Java sources ==="
"$JAVAC" -source 1.8 -target 1.8 -Xlint:-options \
    -cp "$PLATFORM_JAR" \
    -d "$BUILD_DIR/classes" \
    src/com/wewaffles/onelineage/MainActivity.java \
    "$BUILD_DIR/gen/com/wewaffles/onelineage/R.java"

echo "=== 5. Generating Dalvik Executable (classes.dex) with d8 ==="
"$D8" \
    --lib "$PLATFORM_JAR" \
    --min-api 29 \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/wewaffles/onelineage"/*.class

echo "=== 6. Packaging classes.dex into APK ==="
if command -v zip >/dev/null 2>&1; then
    (cd "$BUILD_DIR/dex" && zip -q -u "$BUILD_DIR/base.apk" classes.dex)
else
    [ -n "$JAR" ] || die "Neither zip nor jar is available to package classes.dex."
    (cd "$BUILD_DIR/dex" && "$JAR" uf "$BUILD_DIR/base.apk" classes.dex)
fi

echo "=== 7. Aligning APK with zipalign ==="
"$ZIPALIGN" -f -v -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
    echo "=== 8. Creating debug keystore ==="
    mkdir -p "$(dirname "$KEYSTORE")"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=OneLineage,O=Polaricito,C=US"
fi

echo "=== 9. Signing APK ==="
mkdir -p "$(dirname "$OUT_APK")"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --ks-key-alias androiddebugkey \
    --key-pass pass:android \
    --min-sdk-version 29 \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

"$APKSIGNER" verify --min-sdk-version 29 "$OUT_APK" >/dev/null

echo "=== BUILD SUCCESSFUL ==="
echo "Output APK: $OUT_APK"
ls -lh "$OUT_APK"
