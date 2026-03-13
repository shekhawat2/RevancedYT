#!/usr/bin/env bash
set -euo pipefail

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGFILE="$CURDIR/.yt_build.log"
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
MODULETEMPLATEPATH=$CURDIR/RevancedModule
MODULEBUILDROOT=$CURDIR/.module-build
DATE=$(date +%y%m%d)
MODE=${1:-build}
IS_TEST=false
if [ "$MODE" = "test" ]; then
    IS_TEST=true
fi
DRAFT=$IS_TEST
SKIP_UPLOAD=${SKIP_UPLOAD:-false}
FAST_BUILD=${FAST_BUILD:-false}
APKMIRROR_BASE_URL=${APKMIRROR_BASE_URL:-https://www.apkmirror.com}

# ---------------------------------------------------------------------------
# Per-target arrays – populated by add_target() below.
T_PACKAGE=() T_APK_DIR=() T_MODULE_ID=() T_MODULE_NAME=()
T_MODULE_DESC=() T_UPDATE_JSON=() T_UPDATE_FILE=() T_UNINSTALL_FIRST=()
T_LABEL=() T_DISPLAY_NAME=() T_FALLBACK_VERSION=()
T_RESOLVED_VERSION=() T_FALLBACK_PREFERRED=()
T_VERSION=() T_VERSIONCODE=() T_NAME=() T_MODULE_PATH=()

# add_target DISPLAY PACKAGE APK_DIR UNINSTALL_FIRST [FALLBACK_VERSION]
#   DISPLAY         - human-readable app name   (e.g. "YouTube", "YouTubeMusic")
#   PACKAGE         - Android package name
#   APK_DIR         - base-APK subdirectory     (e.g. "youtube", "youtube-music")
#   UNINSTALL_FIRST - "true" if old install must be removed first
#   FALLBACK_VERSION- preferred fallback version (used if higher than resolved)
add_target() {
    local display=$1 pkg=$2 apk_dir=$3 uninstall=$4 fallback=${5:-}
    local i=${#T_PACKAGE[@]}
    local label="Revanced${display/YouTube/YT}"    # e.g. "YouTubeMusic" → "RevancedYTMusic"
    T_PACKAGE[$i]="$pkg"
    T_APK_DIR[$i]="$apk_dir"
    T_MODULE_ID[$i]="revanced-${apk_dir}"
    T_DISPLAY_NAME[$i]="$display"
    T_MODULE_NAME[$i]="${display} Revanced"
    T_LABEL[$i]="$label"
    T_MODULE_DESC[$i]="${label} Module by @Shekhawat2"
    T_UPDATE_FILE[$i]="${apk_dir}update.json"
    T_UPDATE_JSON[$i]="https://github.com/shekhawat2/RevancedYT/releases/latest/download/${apk_dir}update.json"
    T_UNINSTALL_FIRST[$i]="$uninstall"
    T_FALLBACK_VERSION[$i]="$fallback"
    T_RESOLVED_VERSION[$i]=""
    T_FALLBACK_PREFERRED[$i]="false"
    T_MODULE_PATH[$i]="$MODULEBUILDROOT/${apk_dir}"
    T_VERSION[$i]="" T_VERSIONCODE[$i]="" T_NAME[$i]=""
}

# ---------------------------------------------------------------------------
# Target definitions – add a new add_target line here to support another app.
# ---------------------------------------------------------------------------
add_target "YouTube"      "com.google.android.youtube"                "youtube"       "false" "20.40.45"
add_target "YouTubeMusic" "com.google.android.apps.youtube.music"     "youtube-music" "true"  "8.46.53"
# ---------------------------------------------------------------------------

source "$CURDIR/revanced-common.sh"

patch_main_apks() {
    status "Patching apps..."
    for i in "${!T_PACKAGE[@]}"; do
        local output_apk="${T_MODULE_PATH[$i]}/${T_MODULE_ID[$i]}.apk"
        local input_apk="${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}/base.apk"

        if patch_apk_with_args "$output_apk" "$input_apk" -d "GmsCore support"; then
            zip -d "$output_apk" 'lib/*' >> "$LOGFILE" 2>&1 || true
            success "${T_MODULE_NAME[$i]} patched successfully"
            continue
        fi

        if [ "${T_FALLBACK_PREFERRED[$i]:-false}" = "true" ] && [ -n "${T_RESOLVED_VERSION[$i]:-}" ] && [ "${T_VERSION[$i]}" != "${T_RESOLVED_VERSION[$i]}" ]; then
            warn "${T_MODULE_NAME[$i]} failed with preferred fallback ${T_VERSION[$i]}; retrying with resolved ${T_RESOLVED_VERSION[$i]}"
            T_VERSION[$i]="${T_RESOLVED_VERSION[$i]}"
            download_target_base_apk "$i" "${T_VERSION[$i]}"
            rm -f "$output_apk"

            if patch_apk_with_args "$output_apk" "$input_apk" -d "GmsCore support"; then
                zip -d "$output_apk" 'lib/*' >> "$LOGFILE" 2>&1 || true
                success "${T_MODULE_NAME[$i]} patched successfully with resolved version ${T_VERSION[$i]}"
                continue
            fi
        fi

        error "Failed to patch ${T_MODULE_NAME[$i]}"
        exit 1
    done
}

create_noroot_apks() {
    status "Creating NoRoot APK variants..."
    local pids=() labels=()
    for i in "${!T_PACKAGE[@]}"; do
        (
            zip -d "${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}/base.apk" 'lib/x86/*' 'lib/x86_64/*' >> "$LOGFILE" 2>&1 || true
            patch_apk_with_args \
                "$CURDIR/${T_NAME[$i]}-noroot.apk" \
                "${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}/base.apk" \
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
rm -f "$LOGFILE"
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
patch_main_apks
prepare_release_meta
create_release_if_needed
create_module_zips
create_noroot_apks
generate_update_json_files
upload_release_assets_if_needed
