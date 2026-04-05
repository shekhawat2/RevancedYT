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
    local REPO_NAME="$1"
    local BRANCH="$2"
    local TARGET_DIR="$3"
    local PRIMARY_URL="https://github.com/revanced"
    local FALLBACK_URL="https://gitlab.com/ReVanced"

    log "Cloning $REPO_NAME (branch: $BRANCH) into $TARGET_DIR"

    attempt_git_op() {
        local BASE_URL=$1
        if [ -d "$CURDIR/$TARGET_DIR/.git" ]; then
            git -C "$CURDIR/$TARGET_DIR" reset --hard HEAD >> "$LOGFILE" 2>&1 && \
            git -C "$CURDIR/$TARGET_DIR" clean -fd >> "$LOGFILE" 2>&1 && \
            git -C "$CURDIR/$TARGET_DIR" fetch --depth=1 "$BASE_URL/$REPO_NAME" "$BRANCH" >> "$LOGFILE" 2>&1 && \
            git -C "$CURDIR/$TARGET_DIR" checkout -B "$BRANCH" FETCH_HEAD >> "$LOGFILE" 2>&1 && \
            git -C "$CURDIR/$TARGET_DIR" reset --hard FETCH_HEAD >> "$LOGFILE" 2>&1
        else
            git clone --depth=1 "$BASE_URL/$REPO_NAME" -b "$BRANCH" "$CURDIR/$TARGET_DIR" >> "$LOGFILE" 2>&1
        fi
    }

    # Try GitHub first
    if attempt_git_op "$PRIMARY_URL"; then
        success "Action completed for $REPO_NAME using GitHub"
    else
        log "GitHub failed for $REPO_NAME, attempting GitLab fallback..."
        # Try GitLab fallback
        if attempt_git_op "$FALLBACK_URL"; then
            success "Action completed for $REPO_NAME using GitLab"
        else
            error "Failed to sync $REPO_NAME from both GitHub and GitLab"
            exit 1
        fi
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

# find_apkmirror_release_url PACKAGE VERSION
# Searches APKMirror using last segment of package name + version.
# e.g. com.google.android.youtube 20.14.43 -> searches "youtube+20.14.43"
find_apkmirror_release_url() {
    local package=$1
    local version=$2
    local ver_dashed="${version//./-}"
    local app_name search_html release_url

    # Use only the last dot-segment so no dots appear in the query (avoids WAF 403)
    app_name="${package##*.}"

    search_html=$(req "${APKMIRROR_BASE_URL}/?s=${app_name}+${version}&post_type=app_release&searchtype=apk" - 2>/dev/null || true)
    release_url=$(printf '%s' "$search_html" \
        | grep -o 'href="/apk/[^"]*-'"${ver_dashed}"'-release/"' \
        | grep -v '#' \
        | sed 's/href="//;s/"$//' | head -1)
    [ -n "$release_url" ] && printf '%s%s' "$APKMIRROR_BASE_URL" "$release_url"
}

download_apkmirror_apk() {
    local app_name=$1
    local package=$2
    local version=$3
    local out_path=$4
    local release_url release_html
    local variant_path dl_key_path
    local url final_path extra_path

    rm -rf "$out_path"
    log "Downloading ${app_name} ${version} (package: ${package})..."

    release_url=$(find_apkmirror_release_url "$package" "$version")
    if [ -z "$release_url" ]; then
        error "Failed to find APKMirror release page for ${package} ${version}"
        return 1
    fi
    [[ "$release_url" != http* ]] && release_url="${APKMIRROR_BASE_URL}${release_url}"

    release_html=$(req "$release_url" - 2>/dev/null || true)

    variant_path=$(printf '%s' "$release_html" | grep arm64 -A30 | grep '>APK<' -A20 | grep android-apk-download | head -1 | sed 's#.*-release/##g;s#/".*##g')
    if [ -z "$variant_path" ]; then
        variant_path=$(printf '%s' "$release_html" | grep Variant -A50 | grep '>APK<' -A2 | grep android-apk-download | head -1 | sed 's#.*-release/##g;s#/".*##g')
    fi
    [ -z "$variant_path" ] && { error "Failed to find APK variant for ${app_name} ${version}"; return 1; }

    url="${release_url}${variant_path}"
    dl_key_path=$(req "$url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p' | head -1 | sed 's/&amp;/\&/g')
    [ -z "$dl_key_path" ] && { error "Failed to extract download key for ${app_name} ${version}"; return 1; }

    url="${APKMIRROR_BASE_URL}${dl_key_path}"
    final_path=$(req "$url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##g' | head -1)
    if [ -z "$final_path" ]; then
        final_path=$(req "$url" - | grep -o 'id="download-link"[^>]*href="[^"]*"' | sed 's#.*href="##;s/"$//;s/&amp;/\&/g' | head -1)
    fi
    [ -z "$final_path" ] && { error "Failed to extract final download URL for ${app_name} ${version}"; return 1; }

    url="${APKMIRROR_BASE_URL}${final_path}"

    log "${app_name} download URL: $url"
    req "$url" "$out_path" >> "$LOGFILE" 2>&1 || { error "Failed to download ${app_name} APK"; return 1; }
    if [ ! -s "$out_path" ]; then
        error "${app_name} APK download failed or empty"
        return 1
    fi
    if head -n 1 "$out_path" | grep -qi '<!doctype\|<html'; then
        extra_path=$(grep -o 'id="download-link"[^>]*href="[^"]*"' "$out_path" | sed 's#.*href="##;s/"$//;s/&amp;/\&/g' | head -1)
        if [ -n "$extra_path" ]; then
            log "${app_name} requires extra download hop"
            req "${APKMIRROR_BASE_URL}${extra_path}" "$out_path" >> "$LOGFILE" 2>&1 || { error "Failed extra-hop download for ${app_name}"; return 1; }
        fi
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
    local package=${T_PACKAGE[$i]}
    local app_name=${T_DISPLAY_NAME[$i]}

    download_apkmirror_apk \
        "$app_name" \
        "$package" \
        "$version" \
        "$out_path" || exit 1
}

download_target_base_apk() {
    local i=$1
    local version=$2
    local dest="$CURDIR/.module-build/${T_APK_DIR[$i]}-download.apk"
    local apk_dir="${T_MODULE_PATH[$i]}/${T_APK_DIR[$i]}"

    status "Downloading ${T_MODULE_NAME[$i]} APK"
    dl_target_apk "$i" "$version" "$dest"

    if unzip -l -q "$dest" | grep -q apk; then
        log "Extracting ${T_MODULE_NAME[$i]} APK from bundle..."
        unzip -j -q "$dest" '*.apk' -d "$apk_dir" || { error "Failed to extract ${T_MODULE_NAME[$i]} APK"; exit 1; }
        rm -f "$dest"
    else
        mv "$dest" "$apk_dir/base.apk"
    fi
}

version_is_higher() {
    local a=$1
    local b=$2
    [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
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
    clone revanced-patches dev revanced-patches &
    patches_clone_pid=$!
    clone revanced-cli dev revanced-cli &
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
# Arrays T_PACKAGE, T_APK_DIR, T_MODULE_ID, T_MODULE_NAME,
# T_MODULE_DESC, T_UPDATE_JSON, T_UNINSTALL_FIRST, T_MODULE_PATH,
# T_VERSION, T_VERSIONCODE, T_NAME must be defined in revanced.sh.
set_target_vars() {
    local i=$1
    PACKAGE_NAME=${T_PACKAGE[$i]}
    APK_DIR_NAME=${T_APK_DIR[$i]}
    MODULE_ID=${T_MODULE_ID[$i]}
    MODULE_APK_NAME=${MODULE_ID}.apk
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
    echo "**${RELEASE_TITLE_BASE}-${RELEASE_SERIES}-v${N}**" >"$CURDIR/changelog.md"
    echo "" >>"$CURDIR/changelog.md"
    echo "**Tools:**" >>"$CURDIR/changelog.md"
    echo "revanced-patches: $PATCHESVER" >>"$CURDIR/changelog.md"
    echo "revanced-cli: $CLIVER" >>"$CURDIR/changelog.md"
    echo "" >>"$CURDIR/changelog.md"
    cat >>"$CURDIR/changelog.md" <<'EOF'
**Root Build:**
 • Flash in Magisk.
 • No reboot is required after installation.
 • Disable YouTube auto-updates in the Play Store.

**No-root Build:**
 • Requires **ReVanced MicroG**.
 • Download it from [HERE](https://github.com/ReVanced/GmsCore/releases/latest).
EOF
    sed -i 's/$/\\/g' "$CURDIR/changelog.md"
}

generate_release_data() {
    jq -n \
        --arg tag_name "${RELEASE_SERIES}_v${1}" \
        --arg target_commitish "master" \
        --arg name "${RELEASE_TITLE_BASE}-${RELEASE_SERIES}-v${1}" \
        --rawfile body "$CURDIR/changelog.md" \
        --argjson draft "$DRAFT" \
        '{
            tag_name: $tag_name,
            target_commitish: $target_commitish,
            name: $name,
            body: $body,
            draft: $draft,
            prerelease: false,
            generate_release_notes: false
        }'
}

RELEASE_CREATE_HTTP_CODE=

create_release() {
    local release_num=$1
    local url=https://api.github.com/repos/shekhawat2/RevancedYT/releases
    local response_file response_body upload_url message

    response_file=$(mktemp)
    RELEASE_CREATE_HTTP_CODE=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$url" \
        -d "$(generate_release_data ${release_num})")
    response_body=$(cat "$response_file")
    rm -f "$response_file"

    if [ "$RELEASE_CREATE_HTTP_CODE" != "201" ]; then
        message=$(printf '%s' "$response_body" | jq -r '.message // empty')
        if [ -n "$message" ]; then
            error "GitHub release creation failed with HTTP $RELEASE_CREATE_HTTP_CODE: $message"
        else
            error "GitHub release creation failed with HTTP $RELEASE_CREATE_HTTP_CODE"
        fi
        printf '%s\n' "$response_body" >> "$LOGFILE"
        return 1
    fi

    upload_url=$(printf '%s' "$response_body" | jq -r '.upload_url // empty' | cut -d '{' -f1)
    if [ -z "$upload_url" ]; then
        error "GitHub release creation succeeded but upload_url was missing from the response"
        printf '%s\n' "$response_body" >> "$LOGFILE"
        return 1
    fi

    printf '%s\n' "$upload_url"
}

extract_release_id_from_upload_url() {
    local upload_api_url=$1
    printf '%s' "$upload_api_url" | sed -n 's#.*/releases/\([0-9][0-9]*\)/assets.*#\1#p'
}

delete_release_asset_by_name() {
    local release_id=$1
    local asset_name=$2
    local list_url="https://api.github.com/repos/shekhawat2/RevancedYT/releases/${release_id}/assets?per_page=100"
    local list_file delete_code
    local asset_ids=()

    list_file=$(mktemp)
    if ! curl -sS -o "$list_file" -H 'Accept: application/vnd.github+json' -H "Authorization: token ${GITHUB_TOKEN}" "$list_url"; then
        rm -f "$list_file"
        warn "Failed to query release assets before retrying upload for ${asset_name}"
        return 1
    fi

    mapfile -t asset_ids < <(jq -r --arg name "$asset_name" '.[] | select(.name == $name) | .id' "$list_file" 2>/dev/null || true)
    rm -f "$list_file"

    if [ "${#asset_ids[@]}" -eq 0 ]; then
        return 0
    fi

    for asset_id in "${asset_ids[@]}"; do
        [ -z "$asset_id" ] && continue
        delete_code=$(curl -sS -o /dev/null -w '%{http_code}' \
            -X DELETE \
            -H 'Accept: application/vnd.github+json' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/shekhawat2/RevancedYT/releases/assets/${asset_id}")
        if [ "$delete_code" = "204" ]; then
            log "Deleted existing asset ${asset_name} (id: ${asset_id}) before retry"
        else
            warn "Failed to delete existing asset ${asset_name} (id: ${asset_id}), HTTP ${delete_code}"
            return 1
        fi
    done
}

upload_release_file() {
    asset_path=$1
    if [ ! -f "$asset_path" ]; then
        error "asset $(basename "$asset_path") does not exist"
        exit 1
    fi

    local asset_name content_type http_code curl_status
    local release_id retry max_retries
    asset_name=$(basename "$asset_path")
    content_type=$(file -b --mime-type "$asset_path")
    release_id=$(extract_release_id_from_upload_url "$upload_url")
    max_retries=3

    for retry in $(seq 1 "$max_retries"); do
        log "Uploading ${asset_name} (attempt ${retry}/${max_retries})..."

        set +e
        http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Content-Type: ${content_type}" \
            --data-binary @"$asset_path" \
            "${upload_url}?name=${asset_name}")
        curl_status=$?
        set -e

        if [ "$curl_status" -eq 0 ] && [ "$http_code" = "201" ]; then
            success "Uploaded ${asset_name}"
            return 0
        fi

        warn "Upload attempt ${retry}/${max_retries} failed for ${asset_name} (curl=${curl_status}, http=${http_code})"

        if [ -n "$release_id" ]; then
            delete_release_asset_by_name "$release_id" "$asset_name" || true
        else
            warn "Could not parse release id from upload URL; skipping duplicate-asset cleanup for ${asset_name}"
        fi
    done

    error "Upload of ${asset_name} failed after ${max_retries} attempts"
    exit 1
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
        local resolved_ver fallback_ver ver
        resolved_ver=$(java -jar "$CLI" list-patches \
            -p "$PATCHES" \
            -b \
            --filter-package-name="$pkg" \
            --packages \
            --versions 2>>"$LOGFILE" | \
            awk '
                /Compatible versions:/ { in_block=1; next }
                in_block && /^[[:space:]]*$/ { in_block=0 }
                in_block {
                    gsub(/^[[:space:]]+/, "", $0)
                    if ($0 ~ /^[0-9]+(\.[0-9]+)+$/) print
                }
            ' | sort -uV | tail -1)

        T_RESOLVED_VERSION[$i]="$resolved_ver"
        T_FALLBACK_PREFERRED[$i]="false"
        fallback_ver=${T_FALLBACK_VERSION[$i]:-}
        ver=$resolved_ver

        if [ -n "$fallback_ver" ]; then
            if [ -z "$resolved_ver" ]; then
                ver=$fallback_ver
            elif version_is_higher "$fallback_ver" "$resolved_ver"; then
                ver=$fallback_ver
                T_FALLBACK_PREFERRED[$i]="true"
                warn "Preferring fallback ${fallback_ver} over resolved ${resolved_ver} for ${T_MODULE_NAME[$i]}"
            fi
        fi

        if [ -z "$ver" ]; then
            error "Failed to resolve compatible version for ${T_MODULE_NAME[$i]} (${pkg})"
            exit 1
        fi

        if [ -z "${T_RESOLVED_VERSION[$i]}" ]; then
            T_RESOLVED_VERSION[$i]="$ver"
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
        T_NAME[$i]="${T_LABEL[$i]}_${T_VERSION[$i]}_${RELEASE_SERIES}_v${N}"
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
                T_NAME[$i]="${T_LABEL[$i]}_${T_VERSION[$i]}_${RELEASE_SERIES}_v${N}"
                T_VERSIONCODE[$i]="${DATE}${N}"
            done
            generate_message
            if upload_url=$(create_release "$N"); then
                success "Created release ${T_NAME[0]}"
                break
            fi

            if [ "$RELEASE_CREATE_HTTP_CODE" = "401" ] || [ "$RELEASE_CREATE_HTTP_CODE" = "403" ]; then
                error "Release creation is not authorized. Ensure the workflow grants contents: write to GITHUB_TOKEN."
                exit 1
            fi

            if [ "$N" -eq 9 ]; then
                error "Failed to create GitHub release after 9 attempts"
                exit 1
            fi

            status "Retrying release creation (attempt $((N + 1))/9)..."
        done
    else
        warn "GITHUB_TOKEN is not set. Skipping release creation/upload."
    fi
}

patch_apk_with_args() {
    local output_apk=$1
    local input_apk=$2
    shift 2

    local patch_output failure_lines patch_status monitor_status
    local -a pipeline_status
    local monitor_index
    patch_output=$(mktemp)

    java -jar "$CLI" patch --purge \
        -o "$output_apk" \
        --keystore="$CURDIR/revanced.keystore" \
        --keystore-password="$KEYSTORE_PASSWORD" \
        --keystore-entry-alias=shekhawat2 \
        -p "$PATCHES" \
        -b \
        --force \
        "$@" \
        "$input_apk" 2>&1 | tee "$patch_output" | tee -a "$LOGFILE" | awk '
            BEGIN { IGNORECASE=1; found=0 }
            /failed to apply|patch .* failed|(^|[^[:alpha:]])error([^[:alpha:]]|$)|exception|incompatible|abort|could not|not found/ {
                print
                fflush()
                found=1
            }
            END { exit(found ? 42 : 0) }
        '

    pipeline_status=("${PIPESTATUS[@]}")
    patch_status=${pipeline_status[0]:-1}
    monitor_index=$((${#pipeline_status[@]} - 1))
    monitor_status=${pipeline_status[$monitor_index]:-1}

    if [ "$patch_status" -eq 0 ] && [ "$monitor_status" -eq 0 ]; then
        rm -f "$patch_output"
        return 0
    fi

    error "Patching failed for $(basename "$input_apk"). Showing relevant patch errors:"

    failure_lines=$(grep -Ei 'failed to apply|patch .* failed|\berror\b|\bexception\b|incompatible|abort|could not|not found' "$patch_output" | tail -n 60 || true)

    if [ -n "$failure_lines" ]; then
        printf '%s\n' "$failure_lines" | tee -a "$LOGFILE"
    else
        warn "No explicit failed patch lines detected; showing the last 80 lines of patch output."
        tail -n 80 "$patch_output" | tee -a "$LOGFILE"
    fi

    rm -f "$patch_output"
    return 1
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
                "${T_APK_DIR[$i]}" "${T_MODULE_ID[$i]}.apk" >> "$LOGFILE" 2>&1
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
    local release_base_url
    release_base_url="https://github.com/shekhawat2/RevancedYT/releases/latest/download"

    for i in "${!T_PACKAGE[@]}"; do
        jq -n \
            --arg version "${T_VERSION[$i]}" \
            --arg zip_url "${release_base_url}/${T_NAME[$i]}.zip" \
            --arg changelog "${release_base_url}/changelog.md" \
            --argjson version_code "${T_VERSIONCODE[$i]}" \
            '{
                versionCode: $version_code,
                version: $version,
                zipUrl: $zip_url,
                changelog: $changelog
            }' >"$CURDIR/${T_UPDATE_FILE[$i]}"
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

prune_old_releases_and_tags() {
    local repo=${RELEASE_REPO:-shekhawat2/RevancedYT}
    local prune_days=${PRUNE_DAYS:-90}
    local dry_run=${PRUNE_DRY_RUN:-false}
    local cutoff_epoch cutoff_utc
    local list_file page resp count
    local candidates deleted_releases release_delete_fail deleted_tags tag_delete_fail
    local rid tag rcode tcode
    local remaining page_remaining

    if ! [[ "$prune_days" =~ ^[0-9]+$ ]] || [ "$prune_days" -le 0 ]; then
        error "PRUNE_DAYS must be a positive integer (got: ${prune_days})"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "Missing required tool: jq"
        return 1
    fi

    if [ -z "${GITHUB_TOKEN:-}" ]; then
        error "GITHUB_TOKEN is required for release/tag pruning"
        return 1
    fi

    cutoff_epoch=$(date -u -d "${prune_days} days ago" +%s)
    cutoff_utc=$(date -u -d "@${cutoff_epoch}" '+%Y-%m-%dT%H:%M:%SZ')

    status "Pruning releases older than ${prune_days} days with assets from ${repo} (cutoff: ${cutoff_utc})"
    if [ "$dry_run" = "true" ]; then
        warn "PRUNE_DRY_RUN=true set; no release/tag will be deleted"
    fi

    list_file=$(mktemp)

    # Snapshot candidates first to avoid pagination shifts while deleting.
    page=1
    while :; do
        resp=$(curl -sS \
            -H 'Accept: application/vnd.github+json' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}")

        count=$(printf '%s' "$resp" | jq 'length')
        [ "$count" -eq 0 ] && break

        printf '%s' "$resp" | jq -r --argjson c "$cutoff_epoch" '
            .[]
            | select((.assets | length) > 0)
            | select(((.published_at // .created_at) | fromdateiso8601) < $c)
            | [.id, .tag_name] | @tsv
        ' >> "$list_file"

        page=$((page + 1))
    done

    candidates=$(wc -l < "$list_file" | tr -d ' ')
    if [ "$candidates" -eq 0 ]; then
        success "No releases older than ${prune_days} days with assets were found"
        rm -f "$list_file"
        return 0
    fi

    deleted_releases=0
    release_delete_fail=0
    deleted_tags=0
    tag_delete_fail=0

    while IFS=$'\t' read -r rid tag; do
        [ -z "$rid" ] && continue

        if [ "$dry_run" = "true" ]; then
            log "[DRY RUN] Would delete release id=${rid} and tag=${tag}"
            continue
        fi

        rcode=$(curl -sS -o /dev/null -w '%{http_code}' \
            -X DELETE \
            -H 'Accept: application/vnd.github+json' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${repo}/releases/${rid}")

        if [ "$rcode" = "204" ]; then
            deleted_releases=$((deleted_releases + 1))
        elif [ "$rcode" != "404" ]; then
            warn "Failed deleting release ${rid} (HTTP ${rcode})"
            release_delete_fail=$((release_delete_fail + 1))
        fi

        if [ -n "${tag:-}" ] && [ "$tag" != "null" ]; then
            tcode=$(curl -sS -o /dev/null -w '%{http_code}' \
                -X DELETE \
                -H 'Accept: application/vnd.github+json' \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                "https://api.github.com/repos/${repo}/git/refs/tags/${tag}")

            if [ "$tcode" = "204" ]; then
                deleted_tags=$((deleted_tags + 1))
            elif [ "$tcode" != "404" ] && [ "$tcode" != "422" ]; then
                warn "Failed deleting tag ${tag} (HTTP ${tcode})"
                tag_delete_fail=$((tag_delete_fail + 1))
            fi
        fi
    done < "$list_file"

    if [ "$dry_run" = "true" ]; then
        success "Dry-run complete. Candidates: ${candidates}"
        rm -f "$list_file"
        return 0
    fi

    remaining=0
    page=1
    while :; do
        resp=$(curl -sS \
            -H 'Accept: application/vnd.github+json' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}")

        count=$(printf '%s' "$resp" | jq 'length')
        [ "$count" -eq 0 ] && break

        page_remaining=$(printf '%s' "$resp" | jq --argjson c "$cutoff_epoch" '
            [.[]
            | select((.assets | length) > 0)
            | select(((.published_at // .created_at) | fromdateiso8601) < $c)
            ] | length
        ')
        remaining=$((remaining + page_remaining))
        page=$((page + 1))
    done

    status "Prune summary: candidates=${candidates}, deleted_releases=${deleted_releases}, deleted_tags=${deleted_tags}, release_delete_fail=${release_delete_fail}, tag_delete_fail=${tag_delete_fail}, remaining_old_with_assets=${remaining}"

    rm -f "$list_file"

    if [ "$remaining" -gt 0 ]; then
        warn "Pruning incomplete: ${remaining} old release(s) with assets still remain"
        return 1
    fi

    success "Pruning complete. No releases older than ${prune_days} days with assets remain"
}