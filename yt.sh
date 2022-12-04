#!/usr/bin/env bash

CURDIR=$PWD
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
YTMODULEPATH=$CURDIR/RevancedYT
YTMMODULEPATH=$CURDIR/RevancedYTM
DATE=$(date +%y%m%d)
BSDIFF=$CURDIR/bin/bsdiff
DRAFT=false
IS_PRERELEASE=true
if [ x${1} == xtest ]; then DRAFT=true; fi
if [ x${1} == xofficial ]; then IS_PRERELEASE=false; fi

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
    url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
    req "$url" "$2"
}

dl_ytm() {
    rm -rf $2
    echo "Downloading YouTubeMusic $1"
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-music-${1//./-}-release/"
    url="$url$(req "$url" - | grep arm64 -A30 | grep youtube-music | head -1 | sed "s#.*-release/##g;s#/\".*##g")"
    url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
    url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
    req "$url" "$2"
}

clone_tools() {
    clone revanced-patcher main revanced-patcher
    clone revanced-patches main revanced-patches
    clone revanced-cli main revanced-cli
    clone revanced-integrations main revanced-integrations
    PATCHERVER=$(grep version $CURDIR/revanced-patcher/gradle.properties | tr -dc .0-9)
    PATCHESVER=$(grep version $CURDIR/revanced-patches/gradle.properties | tr -dc .0-9)
    INTEGRATIONSVER=$(grep version $CURDIR/revanced-integrations/gradle.properties | tr -dc .0-9)
    CLIVER=$(grep version $CURDIR/revanced-cli/gradle.properties | tr -dc .0-9)
}

build_tools() {
    cd $CURDIR/revanced-patcher && sh gradlew build >/dev/null
    cd $CURDIR/revanced-patches && sh gradlew build >/dev/null
    cd $CURDIR/revanced-integrations && sh gradlew build >/dev/null
    cd $CURDIR/revanced-cli && sh gradlew build >/dev/null
    PATCHER=$(ls $CURDIR/revanced-patcher/build/libs/revanced-patcher-$PATCHERVER.jar)
    PATCHES=$(ls $CURDIR/revanced-patches/build/libs/revanced-patches-$PATCHESVER.jar)
    INTEG=$(ls $CURDIR/revanced-integrations/app/build/outputs/apk/release/app-release-unsigned.apk)
    CLI=$(ls $CURDIR/revanced-cli/build/libs/revanced-cli-$CLIVER-all.jar)
}

# Generate message
generate_message() {
    echo "**RevancedYT-$DATE-$N**" >$CURDIR/changelog.md
    echo "" >>$CURDIR/changelog.md
    echo "**Tools:**" >>$CURDIR/changelog.md
    echo "revanced-patcher: $PATCHERVER" >>$CURDIR/changelog.md
    echo "revanced-patches: $PATCHESVER" >>$CURDIR/changelog.md
    echo "revanced-integrations: $INTEGRATIONSVER" >>$CURDIR/changelog.md
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
"prerelease":${IS_PRERELEASE},
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

# Fetch latest official supported YT versions
if [ $IS_PRERELEASE = false ]; then
    curl -X 'GET' \
      'https://releases.rvcd.win/patches' \
      -H 'accept: application/json' \
      -o revanced-patches.json
    YTVERSION=$(jq -r '.[] | select(.name == "video-ads") | .compatiblePackages[] | select(.name == "com.google.android.youtube") | .versions[-1]' revanced-patches.json)
    YTMVERSION=$(jq -r '.[] | select(.name == "music-video-ads") | .compatiblePackages[] | select(.name == "com.google.android.apps.youtube.music") | .versions[-1]' revanced-patches.json)
    rm -rf revanced-patches.json
fi

# Clone Tools
clone_tools

# Cleanup
find $CURDIR -type f -name *.apk -exec rm -rf {} \;
find $CURDIR -type f -name *.zip -exec rm -rf {} \;
rm -rf $YTMODULEPATH/youtube && mkdir -p $YTMODULEPATH/youtube
rm -rf $YTMMODULEPATH/youtube-music && mkdir -p $YTMMODULEPATH/youtube-music

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

# Build Tools
build_tools

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
        echo $upload_url
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
java -jar $CLI \
    -a $YTMODULEPATH/youtube/base.apk \
    -o $YTMODULEPATH/revanced.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental \
    -e microg-support \
    -e hide-autoplay-button \
    -e custom-branding || exit

java -jar $CLI \
    -a $YTMMODULEPATH/youtube-music/base.apk \
    -o $YTMMODULEPATH/revanced-music.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental \
    -e music-microg-support || exit

# NoRoot
java -jar $CLI \
    -a $YTMODULEPATH/youtube/base.apk \
    -o $CURDIR/${YTNAME}-noroot.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental \
    -e hide-autoplay-button \
    -e custom-branding || exit

java -jar $CLI \
    -a $YTMMODULEPATH/youtube-music/base.apk \
    -o $CURDIR/${YTMNAME}-noroot.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental || exit

# Create YT Patch
$BSDIFF $YTMODULEPATH/youtube/base.apk $YTMODULEPATH/revanced.apk $YTMODULEPATH/diff.patch
rm $YTMODULEPATH/revanced.apk
# Create YTM Patch
$BSDIFF $YTMMODULEPATH/youtube-music/base.apk $YTMMODULEPATH/revanced-music.apk $YTMMODULEPATH/diff.patch
rm $YTMMODULEPATH/revanced-music.apk

# Create Module
echo "Creating ${YTNAME}.zip"
sed -i "/version=/s/=.*/=$YTVERSION/g" $YTMODULEPATH/module.prop
sed -i "/versionCode=/s/=.*/=$YTVERSIONCODE/g" $YTMODULEPATH/module.prop
cd $YTMODULEPATH && zip -qr9 $CURDIR/$YTNAME.zip *

echo "Creating ${YTMNAME}.zip"
sed -i "/version=/s/=.*/=$YTMVERSION/g" $YTMMODULEPATH/module.prop
sed -i "/versionCode=/s/=.*/=$YTMVERSIONCODE/g" $YTMMODULEPATH/module.prop
cd $YTMMODULEPATH && zip -qr9 $CURDIR/$YTMNAME.zip *

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
