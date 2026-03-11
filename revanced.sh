#!/usr/bin/env bash
set -euo pipefail

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGFILE="$CURDIR/.yt_build.log"
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
MODULETEMPLATEPATH=$CURDIR/RevancedModule
MODULEBUILDROOT=$CURDIR/.module-build
DATE=$(date +%y%m%d)
MODE=${1:-build}
DRAFT=false
IS_TEST=false
if [ "$MODE" = "test" ]; then
    DRAFT=true
    IS_TEST=true
fi

if [ "$IS_TEST" = "true" ]; then
    DEFAULT_SKIP_UPLOAD=true
else
    DEFAULT_SKIP_UPLOAD=false
fi
SKIP_UPLOAD=${SKIP_UPLOAD:-$DEFAULT_SKIP_UPLOAD}
FAST_BUILD=${FAST_BUILD:-false}
APKMIRROR_BASE_URL=${APKMIRROR_BASE_URL:-https://www.apkmirror.com}

# ---------------------------------------------------------------------------
# Per-target arrays – populated by add_target() below.
T_PACKAGE=() T_APK_DIR=() T_MODULE_APK=() T_MODULE_ID=() T_MODULE_NAME=()
T_MODULE_DESC=() T_UPDATE_JSON=() T_UPDATE_FILE=() T_UNINSTALL_FIRST=()
T_LABEL=() T_DISPLAY_NAME=() T_FALLBACK_VERSION=()
T_VERSION=() T_VERSIONCODE=() T_NAME=() T_MODULE_PATH=()

# add_target SHORT DISPLAY PACKAGE APK_DIR SUFFIX UNINSTALL_FIRST [FALLBACK_VERSION]
#   SHORT           - key used in filenames/functions (e.g. "yt", "ytm")
#   DISPLAY         - human-readable app name   (e.g. "YouTube", "YouTubeMusic")
#   PACKAGE         - Android package name
#   APK_DIR         - base-APK subdirectory     (e.g. "youtube", "youtube-music")
#   SUFFIX          - module APK/ID suffix       (e.g. "" or "-music")
#   UNINSTALL_FIRST - "true" if old install must be removed first
#   FALLBACK_VERSION- pinned version when patch query returns nothing (optional)
add_target() {
    local short=$1 display=$2 pkg=$3 apk_dir=$4 suffix=$5 uninstall=$6 fallback=${7:-}
    local i=${#T_PACKAGE[@]}
    local label="Revanced${display/YouTube/YT}"    # e.g. "YouTubeMusic" → "RevancedYTMusic"
    T_PACKAGE[$i]="$pkg"
    T_APK_DIR[$i]="$apk_dir"
    T_MODULE_APK[$i]="revanced${suffix}.apk"
    T_MODULE_ID[$i]="revanced${suffix}"
    T_DISPLAY_NAME[$i]="$display"
    T_MODULE_NAME[$i]="${display} Revanced"
    T_LABEL[$i]="$label"
    T_MODULE_DESC[$i]="${label} Module by @Shekhawat2"
    T_UPDATE_FILE[$i]="${short}update.json"
    T_UPDATE_JSON[$i]="https://github.com/shekhawat2/RevancedYT/releases/latest/download/${short}update.json"
    T_UNINSTALL_FIRST[$i]="$uninstall"
    T_FALLBACK_VERSION[$i]="$fallback"
    T_MODULE_PATH[$i]="$MODULEBUILDROOT/${short}"
    T_VERSION[$i]="" T_VERSIONCODE[$i]="" T_NAME[$i]=""
}

# ---------------------------------------------------------------------------
# Target definitions – add a new add_target line here to support another app.
# ---------------------------------------------------------------------------
add_target "yt"  "YouTube"      "com.google.android.youtube"                "youtube"       ""       "false"
add_target "ytm" "YouTubeMusic" "com.google.android.apps.youtube.music"     "youtube-music" "-music" "true"  "8.46.53"
# ---------------------------------------------------------------------------

source "$CURDIR/revanced-common.sh"

patch_main_apks() {
    status "Patching apps in parallel. This is one of the longest steps..."
    local pids=() labels=()
    for i in "${!T_PACKAGE[@]}"; do
        (
            patch_apk_with_args \
                "${T_MODULE_PATH[$i]}/${T_MODULE_APK[$i]}" \
                "${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}/base.apk" \
                -d "GmsCore support"
            # Strip native libs from the root module APK (keeps size small).
            zip -d "${T_MODULE_PATH[$i]}/${T_MODULE_APK[$i]}" 'lib/*' >> "$LOGFILE" 2>&1 || true
        ) &
        pids+=("$!"); labels+=("Patching ${T_MODULE_NAME[$i]}")
    done
    local job_args=()
    for j in "${!pids[@]}"; do job_args+=("${labels[$j]}" "${pids[$j]}"); done
    wait_for_jobs "${job_args[@]}"
    for i in "${!T_PACKAGE[@]}"; do success "${T_MODULE_NAME[$i]} patched successfully"; done
}

create_noroot_apks() {
    status "Creating NoRoot APK variants..."
    local pids=() labels=()
    for i in "${!T_PACKAGE[@]}"; do
        (
            local base="${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}/base.apk"
            zip -d "$base" 'lib/x86/*' 'lib/x86_64/*' >> "$LOGFILE" 2>&1 || true
            patch_apk_with_args \
                "$CURDIR/${T_NAME[$i]}-noroot.apk" \
                "$base" \
                -e "GmsCore support"
        ) &
        pids+=("$!"); labels+=("Creating ${T_MODULE_NAME[$i]} NoRoot APK")
    done
    local job_args=()
    for j in "${!pids[@]}"; do job_args+=("${labels[$j]}" "${pids[$j]}"); done
    wait_for_jobs "${job_args[@]}"
    for i in "${!T_PACKAGE[@]}"; do success "Created ${T_NAME[$i]}-noroot.apk"; done
}

trap cleanup_on_exit EXIT

# Initialize logging
echo "========================================" > "$LOGFILE"
echo "ReVanced Build Script - $(date)" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"
success "Build log: $LOGFILE"

# Get latest version
init_runtime_deps
init_auth_env
init_java_env
init_keystore_env

# Clone Tools
clone_tools

# Patch Tools
patch_tools

# Build Tools
build_tools

# Cleanup
prepare_workspace

resolve_supported_versions
download_base_apks
prepare_release_meta
create_release_if_needed
patch_main_apks
create_module_zips
create_noroot_apks
generate_update_json_files
upload_release_assets_if_needed
