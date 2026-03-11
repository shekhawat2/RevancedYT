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
    local url=$1
    local out=$2
    local attempt
    local cookie_header=""

    if [ -n "${APKMIRROR_COOKIE:-}" ]; then
        cookie_header="--header=Cookie: ${APKMIRROR_COOKIE}"
    fi

    for attempt in 1 2 3; do
        if wget -q -O "$out" --header="$WGET_HEADER" $cookie_header "$url"; then
            return 0
        fi
        sleep "$attempt"
    done
    return 1
}

resolve_apkmirror_download_url_from_search() {
    local package_name=$1
    local app_slug=$2
    local version=$3
    local version_dash search_url search_html
    local release_path release_url release_html
    local variant_path variant_url
    local dl_key_url final_url

    version_dash=${version//./-}

    search_url="${APKMIRROR_BASE_URL}/?post_type=app_release&searchtype=apk&s=${package_name//./+}+${version}"
    search_html=$(req "$search_url" - 2>/dev/null || true)

    release_path=$(printf '%s' "$search_html" | grep -oE "/apk/google-inc/${app_slug}/${app_slug}-${version_dash}-release/" | head -1)

    if [ -z "$release_path" ]; then
        search_url="${APKMIRROR_BASE_URL}/?post_type=app_release&searchtype=apk&s=${app_slug//-/%20}+${version}"
        search_html=$(req "$search_url" - 2>/dev/null || true)
        release_path=$(printf '%s' "$search_html" | grep -oE "/apk/google-inc/${app_slug}/${app_slug}-${version_dash}-release/" | head -1)
    fi

    if [ -z "$release_path" ]; then
        release_path="/apk/google-inc/${app_slug}/${app_slug}-${version_dash}-release/"
    fi

    release_url="${APKMIRROR_BASE_URL}${release_path}"
    release_html=$(req "$release_url" - 2>/dev/null || true)

    variant_path=$(printf '%s' "$release_html" | grep arm64 -A30 | grep '>APK<' -A20 | grep "${app_slug}" | head -1 | sed "s#.*-release/##g;s#/[\"#].*##g")
    if [ -z "$variant_path" ]; then
        variant_path=$(printf '%s' "$release_html" | grep Variant -A50 | grep '>APK<' -A2 | grep android-apk-download | head -1 | sed "s#.*-release/##g;s#/[\"#].*##g")
    fi
    [ -z "$variant_path" ] && return 1

    variant_url="${release_url}${variant_path}"
    dl_key_url="${APKMIRROR_BASE_URL}$(req "$variant_url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p')"
    [ -z "$dl_key_url" ] && return 1

    final_url="${APKMIRROR_BASE_URL}$(req "$dl_key_url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##g')"
    [ -z "$final_url" ] && return 1

    printf '%s' "$final_url"
}

download_apkmirror_apk() {
    local app_name=$1
    local package_name=$2
    local app_slug=$3
    local version=$4
    local out_path=$5
    local url

    rm -rf "$out_path"
    log "Downloading ${app_name} version ${version}..."

    url=$(resolve_apkmirror_download_url_from_search "$package_name" "$app_slug" "$version") || {
        error "Failed to resolve APKMirror download URL for ${app_name} (${package_name}) ${version}"
        return 1
    }

    log "${app_name} download URL: $url"
    req "$url" "$out_path" >> "$LOGFILE" 2>&1 || { error "Failed to download ${app_name} APK"; return 1; }
    if [ ! -s "$out_path" ]; then
        error "${app_name} APK download failed or empty"
        return 1
    fi
    if head -n 1 "$out_path" | grep -qi '<!doctype\|<html'; then
        error "${app_name} download resolved to HTML page, not APK"
        return 1
    fi
    success "Downloaded ${app_name} APK to $out_path"
}

dl_target_apk() {
    local i=$1
    local version=$2
    local out_path=$3
    local app_slug=${T_APK_DIR[$i]}
    local app_name=${T_DISPLAY_NAME[$i]}
    local package_name=${T_PACKAGE[$i]}

    download_apkmirror_apk \
        "$app_name" \
        "$package_name" \
        "$app_slug" \
        "$version" \
        "$out_path" || exit 1
}

# download_targets_parallel <versions_array_name> <output_paths_array_name> [job_label_prefix]
download_targets_parallel() {
    local versions_name=$1
    local out_paths_name=$2
    local job_label_prefix=${3:-Downloading}
    local -n versions_ref=$versions_name
    local -n out_paths_ref=$out_paths_name

    for i in "${!versions_ref[@]}"; do
        status "${job_label_prefix} ${T_MODULE_NAME[$i]:-target-$i} APK"
        dl_target_apk "$i" "${versions_ref[$i]}" "${out_paths_ref[$i]}"
    done
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
    local patches_gradle_args=( -Dorg.gradle.java.home="$JAVA_HOME" build --parallel --build-cache )
    local cli_gradle_args=( -Dorg.gradle.java.home="$JAVA_HOME" build --parallel --build-cache )
    if [ "$FAST_BUILD" = "true" ]; then
        # revanced-cli does not define a lint task; only skip lint for revanced-patches.
        patches_gradle_args+=( -x lint )
    fi

    status "Building ReVanced Patches. This can take a while..."
    cd "$CURDIR/revanced-patches" && ./gradlew "${patches_gradle_args[@]}" >> "$LOGFILE" 2>&1 || { error "Failed to build ReVanced Patches"; exit 1; }
    status "Building ReVanced CLI..."
    cd "$CURDIR/revanced-cli" && ./gradlew "${cli_gradle_args[@]}" >> "$LOGFILE" 2>&1 || { error "Failed to build ReVanced CLI"; exit 1; }

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

# Sets per-target vars from indexed arrays for target index $1.
# Arrays T_PACKAGE, T_APK_DIR, T_MODULE_APK, T_MODULE_ID, T_MODULE_NAME,
# T_MODULE_DESC, T_UPDATE_JSON, T_UNINSTALL_FIRST, T_MODULE_PATH,
# T_VERSION, T_VERSIONCODE, T_NAME must be defined in revanced.sh.
set_target_vars() {
    local i=$1
    PACKAGE_NAME=${T_PACKAGE[$i]}
    APK_DIR_NAME=${T_APK_DIR[$i]}
    MODULE_APK_NAME=${T_MODULE_APK[$i]}
    MODULE_ID=${T_MODULE_ID[$i]}
    MODULE_NAME=${T_MODULE_NAME[$i]}
    MODULE_DESC=${T_MODULE_DESC[$i]}
    MODULE_UPDATE_JSON=${T_UPDATE_JSON[$i]}
    UNINSTALL_FIRST=${T_UNINSTALL_FIRST[$i]}
    MODULEPATH=${T_MODULE_PATH[$i]}
}

init_module_workspace() {
    local path=$1
    rm -rf "$path"
    mkdir -p "$path"
    cp -r "$MODULETEMPLATEPATH/META-INF" "$path/META-INF"
}

generate_module_prop() {
    local i=$1
    set_target_vars "$i"

    cat >"$MODULEPATH/module.prop" <<EOF
id=$MODULE_ID
name=$MODULE_NAME
version=${T_VERSION[$i]}
versionCode=${T_VERSIONCODE[$i]}
author=Shekhawat2
description=$MODULE_DESC
updateJson=$MODULE_UPDATE_JSON
EOF
}

generate_module_scripts() {
    local i=$1
    set_target_vars "$i"

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
    for i in "${!T_PACKAGE[@]}"; do
        init_module_workspace "${T_MODULE_PATH[$i]}"
        mkdir -p "${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}"
    done
    success "Workspace initialized"
}

resolve_supported_versions() {
    status "Resolving compatible app versions from patches..."
    for i in "${!T_PACKAGE[@]}"; do
        local pkg=${T_PACKAGE[$i]}
        local ver
        ver=$(java -jar "$CLI" list-patches -ipv -f "$pkg" "$PATCHES" 2>>"$LOGFILE" | \
            awk '
                /Compatible versions:/ { in_block=1; next }
                in_block && /^[[:space:]]*$/ { in_block=0 }
                in_block {
                    gsub(/^[[:space:]]+/, "", $0)
                    if ($0 ~ /^[0-9]+(\.[0-9]+)+$/) print
                }
            ' | sort -r | head -1)
        if [ -z "$ver" ] && [ -n "${T_FALLBACK_VERSION[$i]:-}" ]; then
            ver=${T_FALLBACK_VERSION[$i]}
        fi
        if [ -z "$ver" ]; then
            error "Failed to resolve compatible version for ${T_MODULE_NAME[$i]} (${pkg})"
            exit 1
        fi
        T_VERSION[$i]=$ver
        success "Using ${T_MODULE_NAME[$i]} version: $ver"
    done
}

download_base_apks() {
    status "Downloading base APKs..."
    local versions=() download_paths=()
    for i in "${!T_PACKAGE[@]}"; do
        versions[$i]=${T_VERSION[$i]}
        download_paths[$i]="$CURDIR/.module-build/${T_APK_DIR[$i]}-download.apk"
    done

    download_targets_parallel versions download_paths "Downloading"

    for i in "${!T_PACKAGE[@]}"; do
        local dest=${download_paths[$i]}
        local apk_dir="${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}"
        if unzip -l -q "$dest" | grep -q apk; then
            log "Extracting ${T_MODULE_NAME[$i]} APK from bundle..."
            unzip -j -q "$dest" '*.apk' -d "$apk_dir" || { error "Failed to extract ${T_MODULE_NAME[$i]} APK"; exit 1; }
            rm -f "$dest"
        else
            mv "$dest" "$apk_dir/base.apk"
        fi
    done
    success "Downloaded APKs successfully"
}

prepare_release_meta() {
    N=1
    for i in "${!T_PACKAGE[@]}"; do
        T_NAME[$i]="${T_LABEL[$i]}_${T_VERSION[$i]}_${DATE}_v${N}"
        T_VERSIONCODE[$i]="${DATE}${N}"
    done
}

create_release_if_needed() {
    if [ "$SKIP_UPLOAD" = "true" ]; then
        log "Skipping GitHub release creation/upload (SKIP_UPLOAD=true)"
    elif [[ ${GITHUB_TOKEN:-} ]]; then
        status "Creating GitHub release..."
        for N in {1..9}; do
            for i in "${!T_PACKAGE[@]}"; do
                T_NAME[$i]="${T_LABEL[$i]}_${T_VERSION[$i]}_${DATE}_v${N}"
                T_VERSIONCODE[$i]="${DATE}${N}"
            done
            generate_message
            upload_url=$(create_release "$N")
            if (grep 'https' <<<"$upload_url"); then
                success "Created release ${T_NAME[0]}"
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

patch_apk_with_args() {
    local output_apk=$1
    local input_apk=$2
    shift 2

    java -jar "$CLI" patch --purge \
        -o "$output_apk" \
        --keystore="$CURDIR/revanced.keystore" \
        --keystore-password="$KEYSTORE_PASSWORD" \
        --keystore-entry-alias=shekhawat2 \
        -p "$PATCHES" \
        --force \
        "$@" \
        "$input_apk" >> "$LOGFILE" 2>&1
}

create_module_zips() {
    status "Creating module ZIPs..."
    local pids=() labels=()
    for i in "${!T_PACKAGE[@]}"; do
        (
            generate_module_scripts "$i"
            generate_module_prop "$i"
            local mp=${T_MODULE_PATH[$i]}
            cd "$mp" && zip -qr9 "$CURDIR/${T_NAME[$i]}.zip" \
                META-INF module.prop customize.sh service.sh \
                "${T_APK_DIR[$i]}" "${T_MODULE_APK[$i]}" >> "$LOGFILE" 2>&1
        ) &
        pids+=("$!"); labels+=("Creating ${T_MODULE_NAME[$i]} module ZIP")
    done
    local job_args=()
    for j in "${!pids[@]}"; do job_args+=("${labels[$j]}" "${pids[$j]}"); done
    wait_for_jobs "${job_args[@]}"
    for i in "${!T_PACKAGE[@]}"; do
        success "Created ${T_NAME[$i]}.zip"
    done
}

generate_update_json_files() {
    status "Generating update JSON files..."
    for i in "${!T_PACKAGE[@]}"; do
        sed "/\"version\"/s/: .*/: \"${T_VERSION[$i]}\",/g; \
            /\"versionCode\"/s/: .*/: ${T_VERSIONCODE[$i]},/g; \
            /\"zipUrl\"/s/REVANCEDZIP/${T_NAME[$i]}/g" \
            "$CURDIR/update.json" >"$CURDIR/${T_UPDATE_FILE[$i]}"
    done
    success "Update JSON files generated"
}

upload_release_assets_if_needed() {
    if [ "$SKIP_UPLOAD" = "true" ]; then
        log "Skipping GitHub release upload (SKIP_UPLOAD=true)"
    elif [[ ${GITHUB_TOKEN:-} ]]; then
        log "Release upload URL: $upload_url"
        status "Uploading release assets..."
        for i in "${!T_PACKAGE[@]}"; do
            upload_release_file "$CURDIR/${T_NAME[$i]}.zip"
            upload_release_file "$CURDIR/${T_NAME[$i]}-noroot.apk"
            upload_release_file "$CURDIR/${T_UPDATE_FILE[$i]}"
        done
        upload_release_file "$CURDIR/changelog.md"
        success "All files uploaded successfully!"
    else
        warn "GITHUB_TOKEN is not set. Skipping release upload."
    fi
}