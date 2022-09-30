PACKAGE_NAME=com.google.android.apps.youtube.music

# Unmount Old ReVanced
stock_path=$( pm path $PACKAGE_NAME | grep base | sed 's/package://g' )
if [[ '$stock_path' ]] ; then umount -l $stock_path; fi

# Uninstall Old YoutubeMusic
pm uninstall -k $PACKAGE_NAME > /dev/null | true

# Install YoutubeMusic
ui_print "Installing Stock Youtube Music..."
SESSION=$(pm install-create -r | grep -oE '[0-9]+')
APKS="$(ls $MODPATH/youtube-music)"
for APK in $APKS; do
pm install-write $SESSION $APK $MODPATH/youtube-music/$APK > /dev/null
done
pm install-commit $SESSION

# Merge Patch
ui_print "Patching Stock Youtube Music..."
BSPATCH=$MODPATH/tools/bspatch
chmod +x $BSPATCH
$BSPATCH $MODPATH/youtube-music/base.apk $MODPATH/revanced-music.apk $MODPATH/diff.patch
rm -rf $MODPATH/youtube-music $MODPATH/tools $MODPATH/diff.patch

# Mount for Now
base_path=$MODPATH/revanced-music.apk
stock_path=$( pm path $PACKAGE_NAME | grep base | sed 's/package://g' )
chcon u:object_r:apk_data_file:s0 $base_path
mount -o bind $base_path $stock_path
am force-stop $PACKAGE_NAME
