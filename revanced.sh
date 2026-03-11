#!/usr/bin/env bash
set -euo pipefail

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGFILE="$CURDIR/.yt_build.log"
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
MODULETEMPLATEPATH=$CURDIR/RevancedModule
MODULEBUILDROOT=$CURDIR/.module-build
YTMODULEPATH=$MODULEBUILDROOT/yt
YTMMODULEPATH=$MODULEBUILDROOT/ytm
DATE=$(date +%y%m%d)
DRAFT=false
IS_TEST=false
if [ "${1:-}" = "test" ]; then
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

source "$CURDIR/revanced-common.sh"

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
status "Fetching latest app versions..."
get_latestytversion
get_latestytmversion

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
