log() { echo "[$(date +'%H:%M:%S')] $*" >> "$LOGFILE"; }
status() { echo "==> $*" | tee -a "$LOGFILE"; }
warn() { echo "⚠️  $*" | tee -a "$LOGFILE"; }
error() { echo "❌ ERROR: $*" | tee -a "$LOGFILE"; }
success() { echo "✅ $*" | tee -a "$LOGFILE"; }

cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Script failed with exit code $exit_code. Cleaning up..."
        if [ -f "$LOGFILE" ]; then
            echo "----- Last 120 lines of build log ($LOGFILE) -----"
            tail -n 120 "$LOGFILE" || true
            echo "----- End of build log -----"
        fi
        rm -rf "$MODULEBUILDROOT" 2>/dev/null || true
    fi
    log "Logfile saved at: $LOGFILE"
    exit $exit_code
}

wait_for_jobs() {
    local failed=0
    local job_name pid job_status

    while [ "$#" -gt 0 ]; do
        job_name=$1
        pid=$2
        shift 2

        job_status=0
        wait "$pid" || job_status=$?
        if [ $job_status -ne 0 ]; then
            error "$job_name failed"
            failed=1
        fi
    done

    if [ $failed -ne 0 ]; then
        exit 1
    fi
}

init_auth_env() {
    log "Initializing GitHub authentication..."
    if [ -z "${ORG_GRADLE_PROJECT_githubPackagesUsername:-}" ]; then
        ORG_GRADLE_PROJECT_githubPackagesUsername=${GITHUB_ACTOR:-$USER}
    fi

    if [ -z "${ORG_GRADLE_PROJECT_githubPackagesPassword:-}" ]; then
        ORG_GRADLE_PROJECT_githubPackagesPassword=${GITHUB_TOKEN:-}
    fi

    export ORG_GRADLE_PROJECT_githubPackagesUsername
    export ORG_GRADLE_PROJECT_githubPackagesPassword

    if [ -z "${ORG_GRADLE_PROJECT_githubPackagesUsername:-}" ] || [ -z "${ORG_GRADLE_PROJECT_githubPackagesPassword:-}" ]; then
        error "Missing GitHub Packages credentials."
        error "Set GITHUB_TOKEN (and optionally GITHUB_ACTOR), or set"
        error "ORG_GRADLE_PROJECT_githubPackagesUsername and ORG_GRADLE_PROJECT_githubPackagesPassword explicitly."
        exit 1
    fi
    success "GitHub authentication configured"
}

init_java_env() {
    log "Detecting Java environment..."
    if [ -z "${JAVA_HOME:-}" ]; then
        JAVAC_PATH=$(command -v javac 2>/dev/null || true)
        if [ -n "$JAVAC_PATH" ]; then
            JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$JAVAC_PATH")")")
            export JAVA_HOME
            log "Detected JAVA_HOME: $JAVA_HOME"
        fi
    fi

    if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/javac" ]; then
        error "Missing Java JDK. Install JDK 17 and ensure JAVA_HOME points to it."
        exit 1
    fi
    success "Java environment verified"
}

init_keystore_env() {
    if [ ! -f "$CURDIR/revanced.keystore" ]; then
        error "Missing keystore file at $CURDIR/revanced.keystore"
        exit 1
    fi

    if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
        error "Missing KEYSTORE_PASSWORD. Export it in your shell or define it in your environment before running the build."
        exit 1
    fi

    success "Keystore configuration verified"
}

init_runtime_deps() {
    local deps="git wget curl unzip zip file java"
    local missing=""

    if [ "$SKIP_UPLOAD" != "true" ]; then
        deps="$deps jq"
    fi

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing="$missing $dep"
        fi
    done

    if [ -n "$missing" ]; then
        error "Missing required tools:$missing"
        error "Install them, then retry. Example (Debian/Ubuntu): sudo apt install -y$missing"
        exit 1
    fi

    success "Runtime dependencies verified"
}

clone() {
    log "Cloning $1 (branch: $2) into $3"
    URL=https://github.com/revanced
    if [ -d "$CURDIR/$3/.git" ]; then
        git -C "$CURDIR/$3" fetch --depth=1 origin "$2" >> "$LOGFILE" 2>&1 || { error "Failed to fetch $1"; exit 1; }
        git -C "$CURDIR/$3" checkout -q "$2" >> "$LOGFILE" 2>&1 || { error "Failed to checkout $1:$2"; exit 1; }
        git -C "$CURDIR/$3" reset --hard "origin/$2" >> "$LOGFILE" 2>&1 || { error "Failed to reset $1 to origin/$2"; exit 1; }
        success "Updated $1"
    else
        git clone --depth=1 "$URL/$1" -b "$2" "$CURDIR/$3" >> "$LOGFILE" 2>&1 || { error "Failed to clone $1"; exit 1; }
        success "Cloned $1"
    fi
}

req() {
    wget -q -O "$2" --header="$WGET_HEADER" "$1"
}

get_latestytversion() {
    log "Fetching latest YouTube version from APKMirror..."
    url="https://www.apkmirror.com/apk/google-inc/youtube/"
    YTVERSION=$(req "$url" - | grep "All version" -A200 | grep app_release | sed 's:.*/youtube-::g;s:-release/.*::g;s:-:.:g' | sort -r | head -1) || { error "Failed to fetch YouTube version"; exit 1; }
    success "Latest YouTube version: $YTVERSION"
}

get_latestytmversion() {
    log "Fetching latest YouTube Music version from APKMirror..."
    url="https://www.apkmirror.com/apk/google-inc/youtube-music/"
    YTMVERSION=$(req "$url" - | grep "All version" -A200 | grep app_release | sed 's:.*/youtube-music-::g;s:-release/.*::g;s:-:.:g' | sort -r | head -1) || { error "Failed to fetch YouTube Music version"; exit 1; }
    success "Latest YouTube Music version: $YTMVERSION"
}

dl_yt() {
    rm -rf "$2"
    log "Downloading YouTube version $1..."
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-${1//./-}-release/"
    url="$url$(req "$url" - | grep Variant -A50 | grep ">APK<" -A2 | grep android-apk-download | sed "s#.*-release/##g;s#/\#.*##g")"
    url="https://www.apkmirror.com$(req "$url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##p')"
    log "YouTube download URL: $url"
    req "$url" "$2" >> "$LOGFILE" 2>&1 || { error "Failed to download YouTube APK"; exit 1; }
    if [ ! -f "$2" ]; then error "YouTube APK download failed or empty"; exit 1; fi
    success "Downloaded YouTube APK to $2"
}

dl_ytm() {
    rm -rf "$2"
    log "Downloading YouTube Music version $1..."
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-music-${1//./-}-release/"
    url="$url$(req "$url" - | grep arm64 -A30 | grep '>APK<' -A20 | grep youtube-music | head -1 | sed "s#.*-release/##g;s#/\".*##g")"
    url="https://www.apkmirror.com$(req "$url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##p')"
    log "YouTube Music download URL: $url"
    req "$url" "$2" >> "$LOGFILE" 2>&1 || { error "Failed to download YouTube Music APK"; exit 1; }
    if [ ! -f "$2" ]; then error "YouTube Music APK download failed or empty"; exit 1; fi
    success "Downloaded YouTube Music APK to $2"
}

clone_tools() {
    status "Preparing ReVanced tools..."
    clone revanced-patches main revanced-patches &
    patches_clone_pid=$!
    clone revanced-cli main revanced-cli &
    cli_clone_pid=$!
    wait_for_jobs "Updating revanced-patches" "$patches_clone_pid" "Updating revanced-cli" "$cli_clone_pid"
    PATCHESVER=$(grep version "$CURDIR/revanced-patches/gradle.properties" | cut -d = -f 2 | sed 's/^[[:space:]]*//g')
    CLIVER=$(grep version "$CURDIR/revanced-cli/gradle.properties" | cut -d = -f 2 | sed 's/^[[:space:]]*//g')
    log "ReVanced Patches version: $PATCHESVER"
    log "ReVanced CLI version: $CLIVER"
}

patch_tools() {
    status "Patching ReVanced tools..."
    PATCHFILE=$CURDIR/revanced-patches/extensions/shared/library/src/main/java/app/revanced/extension/shared/checks/CheckEnvironmentPatch.java
    FIND_START="    public static void check(Activity context) {"
    FIND_END="    }"
    oldStr=$(sed -n "/$FIND_START/,/^$FIND_END/p" "$PATCHFILE")
    newStr="    public static void check(Activity context) {
        Check.disableForever();
        return;
    }"
    "$CURDIR/repstr.py" "$PATCHFILE" "$oldStr" "$newStr" || { error "Failed to patch tools"; exit 1; }
    success "Tools patched successfully"
}

build_tools() {
    local gradle_args=( -Dorg.gradle.java.home="$JAVA_HOME" build --no-daemon --parallel --build-cache )
    if [ "$FAST_BUILD" = "true" ]; then
        gradle_args+=( -x lint )
    fi

    status "Building ReVanced Patches. This can take a while..."
    cd "$CURDIR/revanced-patches" && ./gradlew "${gradle_args[@]}" >> "$LOGFILE" 2>&1 || { error "Failed to build ReVanced Patches"; exit 1; }
    status "Building ReVanced CLI..."
    cd "$CURDIR/revanced-cli" && ./gradlew "${gradle_args[@]}" >> "$LOGFILE" 2>&1 || { error "Failed to build ReVanced CLI"; exit 1; }

    PATCHES=$(ls "$CURDIR/revanced-patches/patches/build/libs/patches-$PATCHESVER.rvp")
    CLI=$(ls "$CURDIR/revanced-cli/build/libs/revanced-cli-$CLIVER-all.jar")

    if [ ! -f "$PATCHES" ] || [ ! -f "$CLI" ]; then
        error "Failed to build required ReVanced tool artifacts."
        error "PATCHES=$PATCHES"
        error "CLI=$CLI"
        exit 1
    fi

    success "ReVanced Patches: $PATCHES"
    success "ReVanced CLI: $CLI"
}

set_target_vars() {
    TARGET=$1
    if [ "$TARGET" = "yt" ]; then
        PACKAGE_NAME=com.google.android.youtube
        APK_DIR_NAME=youtube
        MODULE_APK_NAME=revanced.apk
        MODULE_ID=revanced
        MODULE_NAME="YouTube Revanced"
        MODULE_DESC="RevancedYT Module by @Shekhawat2"
        MODULE_UPDATE_JSON="https://github.com/shekhawat2/RevancedYT/releases/latest/download/ytupdate.json"
        UNINSTALL_FIRST=false
    else
        PACKAGE_NAME=com.google.android.apps.youtube.music
        APK_DIR_NAME=youtube-music
        MODULE_APK_NAME=revanced-music.apk
        MODULE_ID=revanced-music
        MODULE_NAME="YouTubeMusic Revanced"
        MODULE_DESC="RevancedYTMusic Module by @Shekhawat2"
        MODULE_UPDATE_JSON="https://github.com/shekhawat2/RevancedYT/releases/latest/download/ytmupdate.json"
        UNINSTALL_FIRST=true
    fi
}

init_module_workspace() {
    MODULEPATH=$1
    rm -rf "$MODULEPATH"
    mkdir -p "$MODULEPATH"
    cp -r "$MODULETEMPLATEPATH/META-INF" "$MODULEPATH/META-INF"
}

generate_module_prop() {
    MODULEPATH=$1
    TARGET=$2
    VERSION=$3
    VERSIONCODE=$4

    set_target_vars "$TARGET"

    cat >"$MODULEPATH/module.prop" <<EOF
id=$MODULE_ID
name=$MODULE_NAME
version=$VERSION
versionCode=$VERSIONCODE
author=Shekhawat2
description=$MODULE_DESC
updateJson=$MODULE_UPDATE_JSON
EOF
}

generate_module_scripts() {
    MODULEPATH=$1
    TARGET=$2
    set_target_vars "$TARGET"

    cat >"$MODULEPATH/customize.sh" <<EOF
PACKAGE_NAME=$PACKAGE_NAME
UNINSTALL_FIRST=$UNINSTALL_FIRST

# Unmount old ReVanced bind mount if present.
stock_path=\$( pm path \$PACKAGE_NAME | grep base | sed 's/package://g' | head -n 1 )
if [ -n "\$stock_path" ]; then
    umount -l "\$stock_path"
fi

if [ "\$UNINSTALL_FIRST" = "true" ]; then
    pm uninstall -k \$PACKAGE_NAME > /dev/null 2>&1 || true
fi

TPDIR=\$MODPATH/$APK_DIR_NAME
SESSION=\$(pm install-create -r | grep -oE '[0-9]+')
APKS="\$(ls \$TPDIR)"
for APK in \$APKS; do
    pm install-write \$SESSION \$APK \$TPDIR/\$APK
done
pm install-commit \$SESSION
rm -rf \$TPDIR

# Mount patched APK immediately after install.
base_path=\$MODPATH/$MODULE_APK_NAME
stock_path=\$( pm path \$PACKAGE_NAME | grep base | sed 's/package://g' | head -n 1 )
chcon u:object_r:apk_data_file:s0 \$base_path
mount -o bind \$base_path \$stock_path
am force-stop \$PACKAGE_NAME
EOF

    cat >"$MODULEPATH/service.sh" <<EOF
#!/system/bin/sh
PACKAGE_NAME=$PACKAGE_NAME

while [ "\$(getprop sys.boot_completed | tr -d '\\r')" != "1" ]; do sleep 1; done

base_path="/data/adb/modules/$MODULE_ID/$MODULE_APK_NAME"
stock_path=\$( pm path \$PACKAGE_NAME | grep base | sed 's/package://g' | head -n 1 )
chcon u:object_r:apk_data_file:s0 \$base_path
mount -o bind \$base_path \$stock_path
EOF

    chmod 755 "$MODULEPATH/customize.sh" "$MODULEPATH/service.sh"
}

generate_message() {
    echo "**RevancedYT-$DATE-$N**" >"$CURDIR/changelog.md"
    echo "" >>"$CURDIR/changelog.md"
    echo "**Tools:**" >>"$CURDIR/changelog.md"
    echo "revanced-patches: $PATCHESVER" >>"$CURDIR/changelog.md"
    echo "revanced-cli: $CLIVER" >>"$CURDIR/changelog.md"
    echo "" >>"$CURDIR/changelog.md"
    echo "$(cat "$CURDIR/message")" >>"$CURDIR/changelog.md"
    sed -i 's/$/\\/g' "$CURDIR/changelog.md"
    MSG=$(sed 's/$/n/g' "$CURDIR/changelog.md")
}

generate_release_data() {
    cat <<EOF
{
"tag_name":"${DATE}_v${1}",
"target_commitish":"master",
"name":"RevancedYT-${DATE}-v${1}",
"body":"$MSG",
"draft":${DRAFT},
"prerelease":false,
"generate_release_notes":false
}
EOF
}

create_release() {
    local release_num=$1
    local url=https://api.github.com/repos/shekhawat2/RevancedYT/releases
    curl -s \
        -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$url" \
        -d "$(generate_release_data ${release_num})" | jq -r .upload_url | cut -d '{' -f1
}

upload_release_file() {
    asset_path=$1
    if [ ! -f "$asset_path" ]; then
        error "asset $(basename "$asset_path") does not exist"
        exit 1
    fi

    log "Uploading $(basename "$asset_path")..."
    content_type=$(file -b --mime-type "$asset_path")
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: ${content_type}" \
        --data-binary @"$asset_path" \
        "${upload_url}?name=$(basename "$asset_path")")

    if [ "$http_code" = "201" ]; then
        success "Uploaded $(basename "$asset_path")"
    else
        error "Upload of $(basename "$asset_path") failed with HTTP code $http_code"
        exit 1
    fi
}

prepare_workspace() {
    status "Cleaning old artifacts and preparing module workspace..."
    find "$CURDIR" -type f -name "*.apk" -exec rm -rf {} \; 2>/dev/null || true
    find "$CURDIR" -type f -name "*.zip" -exec rm -rf {} \; 2>/dev/null || true
    rm -rf "$MODULEBUILDROOT"
    mkdir -p "$MODULEBUILDROOT"
    init_module_workspace "$YTMODULEPATH"
    init_module_workspace "$YTMMODULEPATH"
    mkdir -p "$YTMODULEPATH/youtube"
    mkdir -p "$YTMMODULEPATH/youtube-music"
    success "Workspace initialized"
}

resolve_supported_versions() {
    status "Resolving compatible YouTube version from patches..."
    YTVERSION=$(java -jar "$CLI" list-patches -ipv -f com.google.android.youtube "$PATCHES" 2>>"$LOGFILE" | \
        sed -n '/Video\ ads/,/^$/p' | sed -n '/Compatible\ versions:/,/^$/p' | tail -n +2 | sort -r | head -1 | sed 's/^[ \t]*//')
    success "Using YouTube version: $YTVERSION"

    YTMVERSION="8.46.53"
    success "Using YouTube Music version: $YTMVERSION"
}

download_base_apks() {
    status "Downloading base APKs..."
    log "Using YouTube Music version: $YTMVERSION"

    dl_yt "$YTVERSION" "$YTMODULEPATH/youtube/base.apk" &
    yt_download_pid=$!
    dl_ytm "$YTMVERSION" "$CURDIR/$YTMVERSION.apk" &
    ytm_download_pid=$!
    wait_for_jobs "Downloading YouTube APK" "$yt_download_pid" "Downloading YouTube Music APK" "$ytm_download_pid"

    if [ "$(unzip -l -q "$CURDIR/$YTMVERSION.apk" | grep apk)" ]; then
        log "Extracting YouTube Music APK from bundle..."
        unzip -j -q "$CURDIR/$YTMVERSION.apk" *.apk -d "$YTMMODULEPATH/youtube-music" || { error "Failed to extract YouTube Music APK"; exit 1; }
        rm -f "$CURDIR/$YTMVERSION.apk"
    else
        mv "$CURDIR/$YTMVERSION.apk" "$YTMMODULEPATH/youtube-music/base.apk"
    fi
    success "Downloaded APKs successfully"
}

prepare_release_meta() {
    N=1
    YTNAME=RevancedYT_${YTVERSION}_${DATE}_v${N}
    YTMNAME=RevancedYTMusic_${YTMVERSION}_${DATE}_v${N}
    YTVERSIONCODE=${DATE}${N}
    YTMVERSIONCODE=${DATE}${N}
}

create_release_if_needed() {
    if [ "$SKIP_UPLOAD" = "true" ]; then
        log "Skipping GitHub release creation/upload (SKIP_UPLOAD=true)"
    elif [[ ${GITHUB_TOKEN:-} ]]; then
        status "Creating GitHub release..."
        for N in {1..9}; do
            YTNAME=RevancedYT_${YTVERSION}_${DATE}_v${N}
            YTMNAME=RevancedYTMusic_${YTMVERSION}_${DATE}_v${N}
            generate_message
            YTVERSIONCODE=${DATE}${N}
            YTMVERSIONCODE=${DATE}${N}
            upload_url=$(create_release "$N")
            if (grep 'https' <<<"$upload_url"); then
                success "Created release ${YTNAME}"
                break
            else
                status "Retrying release creation (attempt $N/9)..."
                continue
            fi
        done
    else
        warn "GITHUB_TOKEN is not set. Skipping release creation/upload."
    fi
}

patch_main_apks() {
    status "Patching YouTube and YouTube Music in parallel. This is one of the longest steps..."
    (
        java -jar "$CLI" patch --purge \
            -o "$YTMODULEPATH/revanced.apk" \
            --keystore="$CURDIR/revanced.keystore" \
            --keystore-password="$KEYSTORE_PASSWORD" \
            --keystore-entry-alias=shekhawat2 \
            -p "$PATCHES" \
            --force \
            -d "GmsCore support" \
            "$YTMODULEPATH/youtube/base.apk" >> "$LOGFILE" 2>&1
        zip -d "$YTMODULEPATH/revanced.apk" lib/* >> "$LOGFILE" 2>&1 || true
    ) &
    yt_patch_pid=$!

    (
        java -jar "$CLI" patch --purge \
            -o "$YTMMODULEPATH/revanced-music.apk" \
            --keystore="$CURDIR/revanced.keystore" \
            --keystore-password="$KEYSTORE_PASSWORD" \
            --keystore-entry-alias=shekhawat2 \
            -p "$PATCHES" \
            --force \
            -d "GmsCore support" \
            "$YTMMODULEPATH/youtube-music/base.apk" >> "$LOGFILE" 2>&1
    ) &
    ytm_patch_pid=$!

    wait_for_jobs "Patching YouTube" "$yt_patch_pid" "Patching YouTube Music" "$ytm_patch_pid"
    success "YouTube patched successfully"
    success "YouTube Music patched successfully"
}

create_module_zips() {
    status "Creating module ZIPs..."
    (
        generate_module_scripts "$YTMODULEPATH" yt
        generate_module_prop "$YTMODULEPATH" yt "$YTVERSION" "$YTVERSIONCODE"
        cd "$YTMODULEPATH" && zip -qr9 "$CURDIR/$YTNAME.zip" META-INF module.prop customize.sh service.sh youtube revanced.apk >> "$LOGFILE" 2>&1
    ) &
    yt_module_pid=$!

    (
        generate_module_scripts "$YTMMODULEPATH" ytm
        generate_module_prop "$YTMMODULEPATH" ytm "$YTMVERSION" "$YTMVERSIONCODE"
        cd "$YTMMODULEPATH" && zip -qr9 "$CURDIR/$YTMNAME.zip" META-INF module.prop customize.sh service.sh youtube-music revanced-music.apk >> "$LOGFILE" 2>&1
    ) &
    ytm_module_pid=$!

    wait_for_jobs "Creating YouTube module ZIP" "$yt_module_pid" "Creating YouTube Music module ZIP" "$ytm_module_pid"
    success "Created $YTNAME.zip"
    success "Created $YTMNAME.zip"
}

create_noroot_apks() {
    status "Creating NoRoot APK variants..."
    (
        zip -d "$YTMODULEPATH/youtube/base.apk" lib/x86/* lib/x86_64/* >> "$LOGFILE" 2>&1 || true
        java -jar "$CLI" patch --purge \
            -o "$CURDIR/${YTNAME}-noroot.apk" \
            --keystore="$CURDIR/revanced.keystore" \
            --keystore-password="$KEYSTORE_PASSWORD" \
            --keystore-entry-alias=shekhawat2 \
            -p "$PATCHES" \
            --force \
            -e "GmsCore support" \
            "$YTMODULEPATH/youtube/base.apk" >> "$LOGFILE" 2>&1
    ) &
    yt_noroot_pid=$!

    (
        java -jar "$CLI" patch --purge \
            -o "$CURDIR/${YTMNAME}-noroot.apk" \
            --keystore="$CURDIR/revanced.keystore" \
            --keystore-password="$KEYSTORE_PASSWORD" \
            --keystore-entry-alias=shekhawat2 \
            -p "$PATCHES" \
            --force \
            -e "GmsCore support" \
            "$YTMMODULEPATH/youtube-music/base.apk" >> "$LOGFILE" 2>&1
    ) &
    ytm_noroot_pid=$!

    wait_for_jobs "Creating YouTube NoRoot APK" "$yt_noroot_pid" "Creating YouTube Music NoRoot APK" "$ytm_noroot_pid"
    success "Created ${YTNAME}-noroot.apk"
    success "Created ${YTMNAME}-noroot.apk"
}

generate_update_json_files() {
    status "Generating update JSON files..."
    sed "/\"version\"/s/: .*/: \"$YTVERSION\",/g; \
        /\"versionCode\"/s/: .*/: $YTVERSIONCODE,/g; \
        /\"zipUrl\"/s/REVANCEDZIP/$YTNAME/g" "$CURDIR/update.json" >"$CURDIR/ytupdate.json"
    sed "/\"version\"/s/: .*/: \"$YTMVERSION\",/g; \
        /\"versionCode\"/s/: .*/: $YTMVERSIONCODE,/g; \
        /\"zipUrl\"/s/REVANCEDZIP/$YTMNAME/g" "$CURDIR/update.json" >"$CURDIR/ytmupdate.json"
    success "Update JSON files generated"
}

upload_release_assets_if_needed() {
    if [ "$SKIP_UPLOAD" = "true" ]; then
        log "Skipping GitHub release upload (SKIP_UPLOAD=true)"
    elif [[ ${GITHUB_TOKEN:-} ]]; then
        log "Release upload URL: $upload_url"
        status "Uploading release assets..."
        upload_release_file "$CURDIR/$YTNAME.zip"
        upload_release_file "$CURDIR/$YTNAME-noroot.apk"
        upload_release_file "$CURDIR/$YTMNAME.zip"
        upload_release_file "$CURDIR/$YTMNAME-noroot.apk"
        upload_release_file "$CURDIR/ytupdate.json"
        upload_release_file "$CURDIR/ytmupdate.json"
        upload_release_file "$CURDIR/changelog.md"
        success "All files uploaded successfully!"
    else
        warn "GITHUB_TOKEN is not set. Skipping release upload."
    fi
}