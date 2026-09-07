#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_DIR

PACKAGE_NAME="org.mavlink.qgroundcontrol"
readonly PACKAGE_NAME

BUILD_DIR="${MK15_BUILD_DIR:-${SOURCE_DIR}/build-android}"
ADB_BIN="${ADB_BIN:-}"
CMAKE_BIN="${CMAKE_BIN:-}"
DEVICE_SERIAL="${MK15_SERIAL:-}"
KEYSTORE_PATH="${MK15_KEYSTORE_PATH:-/home/${USER}/qgc-signing/qgc-mk15-release.keystore}"
KEYSTORE_ALIAS="${MK15_KEYSTORE_ALIAS:-qgc_mk15_release}"
KEYSTORE_PASSWORD_FILE="${MK15_KEYSTORE_PASSWORD_FILE:-/home/${USER}/qgc-signing/.keystore_password.txt}"
JOBS="${MK15_BUILD_JOBS:-4}"
CONFIGURE=false
BUILD=true
INSTALL=true
LAUNCH=true
REINSTALL_ON_SIG_MISMATCH=true

usage() {
    cat <<'EOF'
Build, sign, install, and launch QGroundControl on an MK15/UniRC7 controller.

Zero-argument usage (build, sign, install, launch with no prompts):

  tools/deploy-mk15.sh

Usage: tools/deploy-mk15.sh [options]

Options:
  --configure             Re-run CMake configuration before building
  --skip-build            Install the existing signed APK without building
  --no-install            Build the APK but do not install it
  --no-launch             Do not launch QGroundControl after installation
  --no-auto-reinstall     Fail instead of uninstalling on a signature mismatch
  --serial SERIAL         Select a specific ADB device
  --jobs COUNT            Set the parallel build job count (default: 4)
  --help                  Show this help

Environment:
  MK15_KEYSTORE_PATH          Signing keystore
                              (default: /home/$USER/qgc-signing/qgc-mk15-release.keystore)
  MK15_KEYSTORE_ALIAS         Signing alias (default: qgc_mk15_release)
  MK15_KEYSTORE_PASSWORD_FILE File holding the keystore password
                              (default: /home/$USER/qgc-signing/.keystore_password.txt);
                              read automatically when MK15_KEYSTORE_STORE_PASS is unset
  MK15_KEYSTORE_STORE_PASS    Keystore password; overrides the password file when set
  MK15_KEYSTORE_KEY_PASS      Key password; defaults to the keystore password
  MK15_BUILD_DIR              Android build directory (default: build-android)
  MK15_SERIAL                 ADB device serial
  MK15_BUILD_JOBS             Parallel build jobs (default: 4)
  ADB_BIN                     adb executable
  CMAKE_BIN                   cmake executable
  JAVA_HOME                   JDK used by the Android build (auto-detected if unset;
                              must be JDK 21+, see find_jdk21 below)

The build directory must already be configured unless --configure is passed. For a new build
directory, invoke CMake with the Qt Android toolchain variables in CMAKE_ARGS, for example:

  CMAKE_ARGS='-DQT_HOST_PATH=/opt/Qt/6.11.1/gcc_64 \
    -DCMAKE_TOOLCHAIN_FILE=/opt/Qt/6.11.1/android_arm64_v8a/lib/cmake/Qt6/qt.toolchain.cmake' \
    tools/deploy-mk15.sh --configure
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

find_tool() {
    local explicit_path="$1"
    local tool_name="$2"
    local sdk_fallback="${3:-}"

    if [[ -n "${explicit_path}" && -x "${explicit_path}" ]]; then
        printf '%s\n' "${explicit_path}"
        return
    fi
    if command -v "${tool_name}" >/dev/null 2>&1; then
        command -v "${tool_name}"
        return
    fi
    if [[ -n "${sdk_fallback}" && -x "${sdk_fallback}" ]]; then
        printf '%s\n' "${sdk_fallback}"
        return
    fi
    fail "${tool_name} was not found"
}

# The Android Gradle build requires JDK 21+ (older JDKs fail with
# "invalid source release: 21"). Auto-detect a usable JDK when JAVA_HOME
# is unset or points at something older, rather than failing deep inside Gradle.
jdk_major_version() {
    local java_home="$1"
    local version_output
    version_output="$("${java_home}/bin/javac" -version 2>&1)" || return 1
    [[ "${version_output}" =~ ([0-9]+)(\.[0-9]+)* ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

find_jdk21() {
    local candidate
    for candidate in "${JAVA_HOME:-}" /home/"${USER}"/.jdks/jdk-21* /usr/lib/jvm/*java-21*; do
        [[ -n "${candidate}" && -x "${candidate}/bin/javac" ]] || continue
        local major
        major="$(jdk_major_version "${candidate}")" || continue
        ((major >= 21)) || continue
        printf '%s\n' "${candidate}"
        return
    done
    return 1
}

while (($#)); do
    case "$1" in
    --configure)
        CONFIGURE=true
        ;;
    --skip-build)
        BUILD=false
        ;;
    --no-install)
        INSTALL=false
        LAUNCH=false
        ;;
    --no-launch)
        LAUNCH=false
        ;;
    --no-auto-reinstall)
        REINSTALL_ON_SIG_MISMATCH=false
        ;;
    --serial)
        (($# >= 2)) || fail "--serial requires a value"
        DEVICE_SERIAL="$2"
        shift
        ;;
    --jobs)
        (($# >= 2)) || fail "--jobs requires a value"
        JOBS="$2"
        shift
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        fail "unknown option: $1"
        ;;
    esac
    shift
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"

ADB_BIN="$(find_tool "${ADB_BIN}" adb "/home/${USER}/Android/Sdk/platform-tools/adb")"
CMAKE_BIN="$(find_tool "${CMAKE_BIN}" cmake "/home/${USER}/.local/bin/cmake")"

JAVA_HOME="$(find_jdk21)" || fail "no JDK 21+ found; set JAVA_HOME to one (Android Gradle build requires 21+)"
export JAVA_HOME

mapfile -t CONNECTED_DEVICES < <("${ADB_BIN}" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [[ -z "${DEVICE_SERIAL}" ]]; then
    ((${#CONNECTED_DEVICES[@]} == 1)) || fail "expected one connected ADB device; use --serial"
    DEVICE_SERIAL="${CONNECTED_DEVICES[0]}"
fi

DEVICE_MODEL="$("${ADB_BIN}" -s "${DEVICE_SERIAL}" shell getprop ro.product.model | tr -d '\r')"
case "${DEVICE_MODEL}" in
MK15 | Pro_94) ;; # Pro_94 is the ro.product.model reported by the SIYI UniRC7 controller
*) fail "device ${DEVICE_SERIAL} is '${DEVICE_MODEL}', not a recognized MK15/UniRC7 controller" ;;
esac
[[ -f "${KEYSTORE_PATH}" ]] || fail "keystore not found: ${KEYSTORE_PATH}"

STORE_PASS="${MK15_KEYSTORE_STORE_PASS:-}"
if [[ -z "${STORE_PASS}" && -f "${KEYSTORE_PASSWORD_FILE}" ]]; then
    STORE_PASS="$(<"${KEYSTORE_PASSWORD_FILE}")"
fi
if [[ -z "${STORE_PASS}" ]]; then
    read -r -s -p "Keystore password: " STORE_PASS
    echo
fi
[[ -n "${STORE_PASS}" ]] || fail "keystore password is empty"
KEY_PASS="${MK15_KEYSTORE_KEY_PASS:-${STORE_PASS}}"

export QT_ANDROID_KEYSTORE_PATH="${KEYSTORE_PATH}"
export QT_ANDROID_KEYSTORE_ALIAS="${KEYSTORE_ALIAS}"
export QT_ANDROID_KEYSTORE_STORE_PASS="${STORE_PASS}"
export QT_ANDROID_KEYSTORE_KEY_PASS="${KEY_PASS}"

if [[ "${CONFIGURE}" == true ]]; then
    read -r -a EXTRA_CMAKE_ARGS <<<"${CMAKE_ARGS:-}"
    "${CMAKE_BIN}" -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -DQT_ANDROID_SIGN_APK=ON "${EXTRA_CMAKE_ARGS[@]}"
elif [[ ! -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
    fail "${BUILD_DIR} is not configured; run again with --configure and CMAKE_ARGS"
fi

if [[ "${BUILD}" == true ]]; then
    "${CMAKE_BIN}" --build "${BUILD_DIR}" --target apk --parallel "${JOBS}"
fi

APK_PATH="${BUILD_DIR}/android-build/build/outputs/apk/debug/android-build-debug-signed.apk"
[[ -f "${APK_PATH}" ]] || fail "signed APK not found: ${APK_PATH}"

if [[ "${INSTALL}" == true ]]; then
    INSTALL_LOG="$(mktemp)"
    trap 'rm -f "${INSTALL_LOG}"' EXIT
    if ! "${ADB_BIN}" -s "${DEVICE_SERIAL}" install -r "${APK_PATH}" 2>&1 | tee "${INSTALL_LOG}"; then
        if [[ "${REINSTALL_ON_SIG_MISMATCH}" == true ]] && grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "${INSTALL_LOG}"; then
            echo "Signature differs from the installed package; uninstalling ${PACKAGE_NAME} and retrying (app data on the device will be lost)." >&2
            "${ADB_BIN}" -s "${DEVICE_SERIAL}" uninstall "${PACKAGE_NAME}"
            "${ADB_BIN}" -s "${DEVICE_SERIAL}" install "${APK_PATH}"
        else
            fail "adb install failed; see output above"
        fi
    fi
fi

if [[ "${LAUNCH}" == true ]]; then
    "${ADB_BIN}" -s "${DEVICE_SERIAL}" shell am start -n "${PACKAGE_NAME}/${PACKAGE_NAME}.QGCActivity"
fi

echo "MK15 deployment complete: ${APK_PATH}"
