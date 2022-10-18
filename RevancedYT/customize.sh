NAME=_NAME_
PACKAGE_NAME=_PACKAGE_NAME_

# Unmount Old ReVanced
stock_path=$( pm path $PACKAGE_NAME | grep base | sed 's/package://g' )
if [[ '$stock_path' ]] ; then umount -l $stock_path; fi

# Uninstall Old $NAME
pm uninstall -k $PACKAGE_NAME > /dev/null | true

# Install $NAME
ui_print "Installing Stock $NAME..."
SESSION=$(pm install-create -r | grep -oE '[0-9]+')
APKS="$(ls $MODPATH/$NAME)"
for APK in $APKS; do
pm install-write $SESSION $APK $MODPATH/$NAME/$APK > /dev/null
done
pm install-commit $SESSION

# Merge Patch
ui_print "Patching Stock $NAME..."
BSPATCH=$MODPATH/tools/bspatch
chmod +x $BSPATCH
$BSPATCH $MODPATH/$NAME/base.apk $MODPATH/$NAME.apk $MODPATH/diff.patch
rm -rf $MODPATH/$NAME $MODPATH/tools $MODPATH/diff.patch

# Mount for Now
base_path=$MODPATH/$NAME.apk
stock_path=$( pm path $PACKAGE_NAME | grep base | sed 's/package://g' )
chcon u:object_r:apk_data_file:s0 $base_path
mount -o bind $base_path $stock_path
am force-stop $PACKAGE_NAME
