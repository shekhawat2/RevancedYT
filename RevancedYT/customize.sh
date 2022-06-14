# Unmount Old ReVanced
stock_path=$( pm path com.google.android.youtube | grep base | sed 's/package://g' )
if [[ '$stock_path' ]] ; then umount -l $stock_path; fi

# Install Youtube
TPDIR=$MODPATH/youtube
SESSION=$(pm install-create -r | grep -oE '[0-9]+')
APKS="$(ls $TPDIR)"
for APK in $APKS; do
pm install-write $SESSION $APK $TPDIR/$APK
done
pm install-commit $SESSION
rm -rf $TPDIR

# Remove Old ReVanced
rm -rf /data/adb/revanced
rm -rf /data/adb/service.d/revanced.sh

# Mount for Now
base_path=$MODPATH/revanced.apk
stock_path=$( pm path com.google.android.youtube | grep base | sed 's/package://g' )
chcon u:object_r:apk_data_file:s0 $base_path
mount -o bind $base_path $stock_path
am force-stop com.google.android.youtube
