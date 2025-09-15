#!/usr/bin/env bash

CURDIR=$PWD
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
YTMODULEPATH=$CURDIR/RevancedYT
YTMMODULEPATH=$CURDIR/RevancedYTM
DATE=$(date +%y%m%d)
DRAFT=false
if [ x${1} == xtest ]; then DRAFT=true; fi

clone() {
    echo "Cleaning and Cloning $1"
    rm -rf $3
    URL=https://github.com/revanced
    git clone --depth=1 $URL/$1 -b $2 $CURDIR/$3 2>/dev/null
}

req() {
    wget -q -O "$2" --header="$WGET_HEADER" "$1"
}

get_latestytversion() {
    url="https://www.apkmirror.com/apk/google-inc/youtube/"
    YTVERSION=$(req "$url" - | grep "All version" -A200 | grep app_release | sed 's:.*/youtube-::g;s:-release/.*::g;s:-:.:g' | sort -r | head -1)
    echo "Latest Youtube Version: $YTVERSION"
}

get_latestytmversion() {
    url="https://www.apkmirror.com/apk/google-inc/youtube-music/"
    YTMVERSION=$(req "$url" - | grep "All version" -A200 | grep app_release | sed 's:.*/youtube-music-::g;s:-release/.*::g;s:-:.:g' | sort -r | head -1)
    echo "Latest YoutubeMusic Version: $YTMVERSION"
}

dl_yt() {
    rm -rf $2
    echo "Downloading YouTube $1"
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-${1//./-}-release/"
    url="$url$(req "$url" - | grep Variant -A50 | grep ">APK<" -A2 | grep android-apk-download | sed "s#.*-release/##g;s#/\#.*##g")"
    url="https://www.apkmirror.com$(req "$url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##p')"
    echo "URL: $url"
    req "$url" "$2"
    if [ ! -f $2 ]; then echo failed && exit 1; fi
}

dl_ytm() {
    rm -rf $2
    echo "Downloading YouTubeMusic $1"
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-music-${1//./-}-release/"
    url="$url$(req "$url" - | grep arm64 -A30 | grep '>APK<' -A20 | grep youtube-music | head -1 | sed "s#.*-release/##g;s#/\".*##g")"
    url="https://www.apkmirror.com$(req "$url" - | grep "downloadButton" | grep "forcebaseapk" | sed -n 's;.*href="\(.*key=[^"]*\)".*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | grep "please click" | sed 's#.*href="\(.*key=[^"]*\)">.*#\1#;s#amp;##p')"
    echo "URL: $url"
    req "$url" "$2"
    if [ ! -f $2 ]; then echo failed && exit 1; fi
}

clone_tools() {
    clone revanced-patches dev revanced-patches
    clone revanced-cli main revanced-cli
    PATCHESVER=$(grep version $CURDIR/revanced-patches/gradle.properties | tr -dc .0-9)
    CLIVER=$(grep version $CURDIR/revanced-cli/gradle.properties | tr -dc .0-9)
}

patch_tools() {
echo "Patching Tools"
PATCHFILE=$CURDIR/revanced-patches/extensions/shared/library/src/main/java/app/revanced/extension/shared/checks/CheckEnvironmentPatch.java
FIND_START="    public static void check(Activity context) {"
FIND_END="    }"
oldStr=`sed -n "/$FIND_START/,/^$FIND_END/p" $PATCHFILE`
newStr="    public static void check(Activity context) {
        Check.disableForever();
        return;
    }"
$CURDIR/repstr.py "$PATCHFILE" "$oldStr" "$newStr"
}

build_tools() {
    cd $CURDIR/revanced-patches && sh gradlew build >/dev/null
    cd $CURDIR/revanced-cli && sh gradlew build >/dev/null
    ls $CURDIR/revanced-patches/patches/build
    PATCHES=$(ls $CURDIR/revanced-patches/patches/build/libs/patches-$PATCHESVER.rvp)
    CLI=$(ls $CURDIR/revanced-cli/build/libs/revanced-cli-$CLIVER-all.jar)
    echo "$PATCHES"
    echo "$CLI"
}

# Generate message
generate_message() {
    echo "**RevancedYT-$DATE-$N**" >$CURDIR/changelog.md
    echo "" >>$CURDIR/changelog.md
    echo "**Tools:**" >>$CURDIR/changelog.md
    echo "revanced-patches: $PATCHESVER" >>$CURDIR/changelog.md
    echo "revanced-cli: $CLIVER" >>$CURDIR/changelog.md
    echo "" >>$CURDIR/changelog.md
    echo "$(cat $CURDIR/message)" >>$CURDIR/changelog.md
    sed -i 's/$/\\/g' ${CURDIR}/changelog.md
    MSG=$(sed 's/$/n/g' ${CURDIR}/changelog.md)
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
    url=https://api.github.com/repos/shekhawat2/RevancedYT/releases
    command="curl -s \
        -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H 'Authorization: token ${GITHUB_TOKEN}' \
        $url \
        -d '$(generate_release_data ${1})' | jq -r .upload_url | cut -d { -f'1'"
}

upload_release_file() {
    command="curl -s -o /dev/null -w '%{http_code}' \
        -H 'Authorization: token ${GITHUB_TOKEN}' \
        -H 'Content-Type: $(file -b --mime-type ${CURDIR}/${YTNAME}.zip)' \
        --data-binary @${1} \
        ${upload_url}?name=$(basename ${1})"

    http_code=$(eval $command)
    if [ $http_code == "201" ]; then
        echo "asset $(basename ${1}) uploaded"
    else
        echo "upload failed with code '$http_code'"
        exit 1
    fi
}

# Get latest version
get_latestytversion
get_latestytmversion

# Clone Tools
clone_tools

# Patch Tools
patch_tools

# Build Tools
build_tools

# Cleanup
find $CURDIR -type f -name "*.apk" -exec rm -rf {} \;
find $CURDIR -type f -name "*.zip" -exec rm -rf {} \;
rm -rf $YTMODULEPATH/youtube && mkdir -p $YTMODULEPATH/youtube
rm -rf $YTMMODULEPATH/youtube-music && mkdir -p $YTMMODULEPATH/youtube-music

# Fetch latest official supported YT versions
YTVERSION=$(java -jar $CLI list-patches -ipv -f com.google.android.youtube $PATCHES | \
    sed -n '/Video\ ads/,/^$/p' | sed -n '/Compatible\ versions:/,/^$/p' | tail -n +2 | sort -r | head -1 | sed 's/^[ \t]*//')

# Download Youtube
dl_yt $YTVERSION $YTMODULEPATH/youtube/base.apk

# Download Youtube Music
dl_ytm $YTMVERSION $CURDIR/$YTMVERSION.apk
if [ "$(unzip -l -q $CURDIR/$YTMVERSION.apk | grep apk)" ]; then
    unzip -j -q $CURDIR/$YTMVERSION.zip *.apk -d $YTMMODULEPATH/youtube-music || exit 1
    rm $CURDIR/$YTMVERSION.zip
else
    mv $CURDIR/$YTMVERSION.apk $YTMMODULEPATH/youtube-music/base.apk
fi

# Create Release
if [[ $GITHUB_TOKEN ]]; then
    for N in {1..9}; do
        YTNAME=RevancedYT_${YTVERSION}_${DATE}_v${N}
        YTMNAME=RevancedYTMusic_${YTMVERSION}_${DATE}_v${N}
        generate_message
        YTVERSIONCODE=${DATE}${N}
        YTMVERSIONCODE=${DATE}${N}
        create_release $N
        upload_url=$(eval $command)
        if (grep 'https' <<<$upload_url); then
            echo "created release ${YTNAME}"
            break
        else
            echo "Trying Again to create release"
            continue
        fi
    done
fi

# Patch Apk
java -jar $CLI patch --purge \
    -o $YTMODULEPATH/revanced.apk \
    --keystore=$CURDIR/revanced.keystore \
    --keystore-password=$KEYSTORE_PASSWORD \
    --keystore-entry-alias=shekhawat2 \
    -p $PATCHES \
    --force \
    -d "GmsCore support" \
    $YTMODULEPATH/youtube/base.apk || exit
zip -d $YTMODULEPATH/revanced.apk lib/*

java -jar $CLI patch --purge \
    -o $YTMMODULEPATH/revanced-music.apk \
    --keystore=$CURDIR/revanced.keystore \
    --keystore-password=$KEYSTORE_PASSWORD \
    --keystore-entry-alias=shekhawat2 \
    -p $PATCHES \
    --force \
    -d "GmsCore support" \
    $YTMMODULEPATH/youtube-music/base.apk || exit

# Create Module
echo "Creating ${YTNAME}.zip"
sed -i "/version=/s/=.*/=$YTVERSION/g" $YTMODULEPATH/module.prop
sed -i "/versionCode=/s/=.*/=$YTVERSIONCODE/g" $YTMODULEPATH/module.prop
cd $YTMODULEPATH && zip -qr9 $CURDIR/$YTNAME.zip META-INF module.prop customize.sh service.sh youtube revanced.apk

echo "Creating ${YTMNAME}.zip"
sed -i "/version=/s/=.*/=$YTMVERSION/g" $YTMMODULEPATH/module.prop
sed -i "/versionCode=/s/=.*/=$YTMVERSIONCODE/g" $YTMMODULEPATH/module.prop
cd $YTMMODULEPATH && zip -qr9 $CURDIR/$YTMNAME.zip META-INF module.prop customize.sh service.sh youtube-music revanced-music.apk

# NoRoot
zip -d $YTMODULEPATH/youtube/base.apk lib/x86/* lib/x86_64/*
java -jar $CLI patch --purge \
    -o $CURDIR/${YTNAME}-noroot.apk \
    --keystore=$CURDIR/revanced.keystore \
    --keystore-password=$KEYSTORE_PASSWORD \
    --keystore-entry-alias=shekhawat2 \
    -p $PATCHES \
    --force \
    -e "GmsCore support" \
    $YTMODULEPATH/youtube/base.apk || exit

java -jar $CLI patch --purge \
    -o $CURDIR/${YTMNAME}-noroot.apk \
    --keystore=$CURDIR/revanced.keystore \
    --keystore-password=$KEYSTORE_PASSWORD \
    --keystore-entry-alias=shekhawat2 \
    -p $PATCHES \
    --force \
    -e "GmsCore support" \
    $YTMMODULEPATH/youtube-music/base.apk || exit

# Generate updateJson
sed "/\"version\"/s/:\ .*/:\ \"$YTVERSION\",/g; \
    /\"versionCode\"/s/:\ .*/:\ $YTVERSIONCODE,/g; \
    /\"zipUrl\"/s/REVANCEDZIP/$YTNAME/g" $CURDIR/update.json >$CURDIR/ytupdate.json
sed "/\"version\"/s/:\ .*/:\ \"$YTMVERSION\",/g; \
    /\"versionCode\"/s/:\ .*/:\ $YTMVERSIONCODE,/g; \
    /\"zipUrl\"/s/REVANCEDZIP/$YTMNAME/g" $CURDIR/update.json >$CURDIR/ytmupdate.json

# Upload Github Release
echo $upload_url
if [[ $GITHUB_TOKEN ]]; then
    upload_release_file $CURDIR/$YTNAME.zip
    upload_release_file $CURDIR/$YTNAME-noroot.apk
    upload_release_file $CURDIR/$YTMNAME.zip
    upload_release_file $CURDIR/$YTMNAME-noroot.apk
    upload_release_file $CURDIR/ytupdate.json
    upload_release_file $CURDIR/ytmupdate.json
    upload_release_file $CURDIR/changelog.md
fi
