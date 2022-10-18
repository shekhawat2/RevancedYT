#!/system/bin/sh
NAME=_NAME_
PACKAGE_NAME=_PACKAGE_NAME_

MAGISKTMP="$(magisk --path)" || MAGISKTMP=/sbin
MIRROR="$MAGISKTMP/.magisk/mirror"
while [ "$(getprop sys.boot_completed | tr -d '\r')" != "1" ]; do sleep 1; done

base_path="/data/adb/modules/$NAME/$NAME.apk"
stock_path=$( pm path $PACKAGE_NAME | grep base | sed 's/package://g' )
chcon u:object_r:apk_data_file:s0 $base_path
mount -o bind $MIRROR$base_path $stock_path
