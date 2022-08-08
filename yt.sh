#!/usr/bin/env bash

CURDIR=$PWD
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
MODULEPATH=$CURDIR/RevancedYT

clone() {
echo "Cleaning and Cloning $1"
rm -rf $3
URL=https://github.com/revanced
git clone --depth=1 $URL/$1 -b $2 $CURDIR/$3  2> /dev/null
}

req() {
    wget -q -O "$2" --header="$WGET_HEADER" "$1"
}

get_latestversion() {
    url="https://www.apkmirror.com/apk/google-inc/youtube/"
    VERSION=$(req "$url" - | grep "All version" -A200 | grep app_release | grep -i beta | head -1 | sed 's:.*/youtube-::g;s:-release/.*::g;s:-:.:g')
    echo "Latest Version: $VERSION"
}

dl_yt() {
    rm -rf $2
    echo "Downloading YouTube $1"
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-${1//./-}-release/"
    url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's/href="/@/g; s;.*APK</span>[^@]*@\([^#]*\).*;\1;p')"
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
cd $CURDIR/revanced-patcher && sh gradlew build > /dev/null
cd $CURDIR/revanced-patches && sh gradlew build > /dev/null
cd $CURDIR/revanced-integrations && sh gradlew build > /dev/null
cd $CURDIR/revanced-cli && sh gradlew build > /dev/null
PATCHER=`ls $CURDIR/revanced-patcher/build/libs/revanced-patcher-$PATCHERVER.jar`
PATCHES=`ls $CURDIR/revanced-patches/build/libs/revanced-patches-$PATCHESVER.jar`
INTEG=`ls $CURDIR/revanced-integrations/app/build/outputs/apk/release/app-release-unsigned.apk`
CLI=`ls $CURDIR/revanced-cli/build/libs/revanced-cli-$CLIVER-all.jar`
}

# Generate message
generate_message() {
echo "**$YTNAME**" > $CURDIR/changelog.md
echo "" >> $CURDIR/changelog.md
echo "**Tools:**" >> $CURDIR/changelog.md
echo "revanced-patcher: $PATCHERVER" >> $CURDIR/changelog.md
echo "revanced-patches: $PATCHESVER" >> $CURDIR/changelog.md
echo "revanced-integrations: $INTEGRATIONSVER" >> $CURDIR/changelog.md
echo "revanced-cli: $CLIVER" >> $CURDIR/changelog.md
echo "" >> $CURDIR/changelog.md
echo "$(cat $CURDIR/message)" >> $CURDIR/changelog.md
sed -i 's/$/\\/g' ${CURDIR}/changelog.md
MSG=$(sed 's/$/n/g' ${CURDIR}/changelog.md)
}

generate_release_data() {
cat <<EOF
{
"tag_name":"${VERSION}_v${1}",
"target_commitish":"master",
"name":"$YTNAME",
"body":"$MSG",
"draft":false,
"prerelease":false,
"generate_release_notes":false
}
EOF
}

create_release() {
command="curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H 'Authorization: token ${GITHUB_TOKEN}' \
    https://api.github.com/repos/shekhawat2/RevancedYT/releases \
    -d '$(generate_release_data ${1})'"
}

upload_release_file() {
curl -s -o latest.json \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    https://api.github.com/repos/shekhawat2/RevancedYT/releases/latest

url=`jq -r .upload_url latest.json | cut -d { -f'1'`
command="curl -s -o /dev/null -w '%{http_code}' \
    -H 'Authorization: token ${GITHUB_TOKEN}' \
    -H 'Content-Type: $(file -b --mime-type ${CURDIR}/${YTNAME}.zip)' \
    --data-binary @${1} \
    ${url}?name=$(basename ${1})"

http_code=`eval $command`
if [ $http_code == "201" ]; then
    echo "asset $(basename ${1}) uploaded"
else
    echo "upload failed with code '$http_code'"
    exit 1
fi
}

# Get latest version
get_latestversion

# Clone Tools
clone_tools

# Create Release
for N in {1..9}; do
    YTNAME=RevancedYT_${VERSION}_v${N}
    generate_message
    VERSIONCODE=$(sed "s/\.//g" <<< ${VERSION})${N}
    create_release $N
    http_code=`eval $command`
    if [ $http_code == "201" ]; then
        echo "created release ${YTNAME}"
        break
    elif [ $http_code == "422" ]; then
        echo "Trying Again to create release"
        continue
    fi
done

# Cleanup
rm -rf $CURDIR/${YTNAME}.zip
rm -rf $CURDIR/${YTNAME}-noroot.apk
rm -rf $MODULEPATH/youtube && mkdir -p $MODULEPATH/youtube
rm -rf $MODULEPATH/revanced.apk

# Download Youtube
dl_yt $VERSION $MODULEPATH/youtube/base.apk

# Build Tools
build_tools

# Patch Apk
java -jar $CLI \
    -a $MODULEPATH/youtube/base.apk \
    -o $MODULEPATH/revanced.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental \
    -e microg-support \
    -e premium-heading \
    -e custom-branding || exit

# NoRoot
java -jar $CLI \
    -a $MODULEPATH/youtube/base.apk \
    -o $CURDIR/${YTNAME}-noroot.apk \
    --keystore=$CURDIR/revanced.keystore \
    -b $PATCHES \
    -m $INTEG \
    --experimental \
    -e premium-heading \
    -e custom-branding || exit

# Create Module
echo "Creating ${YTNAME}.zip"
sed -i "/version=/s/=.*/=$VERSION/g" $MODULEPATH/module.prop
sed -i "/versionCode=/s/=.*/=$VERSIONCODE/g" $MODULEPATH/module.prop
cd $MODULEPATH && zip -qr9 $CURDIR/$YTNAME.zip *

# Generate Message
generate_message

# Generate updateJson
sed -i "/\"version\"/s/:\ .*/:\ \"$VERSION\",/g" $CURDIR/update.json
sed -i "/\"versionCode\"/s/:\ .*/:\ $VERSIONCODE,/g" $CURDIR/update.json
sed -i "/\"zipUrl\"/s/REVANCEDZIP/$YTNAME/g" $CURDIR/update.json

# Upload Github Release
if [[ $GITHUB_TOKEN ]]; then
    upload_release_file $CURDIR/$YTNAME.zip
    upload_release_file $CURDIR/$YTNAME-noroot.apk
    upload_release_file $CURDIR/update.json
    upload_release_file $CURDIR/changelog.md
fi
