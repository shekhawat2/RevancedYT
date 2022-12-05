PACKAGE_NAME=com.google.android.apps.youtube.music

if [ "$BOOTMODE" != "true" ]; then
    abort "! Recovery install is not supported"
fi

# Uninstall Old YoutubeMusic
pm uninstall -k $PACKAGE_NAME > /dev/null | true
MAGISKTMP="$(magisk --path)" || MAGISKTMP=/sbin

if [ ! -d "$MAGISKTMP/.magisk/modules/magisk_proc_monitor" ]; then
    ui_print "! Please install Magisk Process monitor tool v1.1+"
    ui_print "  https://github.com/HuskyDG/magisk_proc_monitor"
    abort
fi

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
