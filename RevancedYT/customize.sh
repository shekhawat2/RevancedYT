PACKAGE_NAME=com.google.android.youtube

if [ "$BOOTMODE" != "true" ]; then
    abort "! Recovery install is not supported"
fi

MAGISKTMP="$(magisk --path)" || MAGISKTMP=/sbin

if [ ! -d "$MAGISKTMP/.magisk/modules/magisk_proc_monitor" ]; then
    ui_print "! Please install Magisk Process monitor tool v1.1+"
    ui_print "  https://github.com/HuskyDG/magisk_proc_monitor"
    abort
fi

# Install Youtube
ui_print "Installing Stock Youtube..."
SESSION=$(pm install-create -r | grep -oE '[0-9]+')
APKS="$(ls $MODPATH/youtube)"
for APK in $APKS; do
pm install-write $SESSION $APK $MODPATH/youtube/$APK > /dev/null
done
pm install-commit $SESSION

# Merge Patch
ui_print "Patching Stock Youtube..."
BSPATCH=$MODPATH/tools/bspatch
chmod +x $BSPATCH
$BSPATCH $MODPATH/youtube/base.apk $MODPATH/revanced.apk $MODPATH/diff.patch
rm -rf $MODPATH/youtube $MODPATH/tools $MODPATH/diff.patch
