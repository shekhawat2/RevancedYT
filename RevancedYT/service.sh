#!/system/bin/sh
while [ "$(getprop sys.boot_completed | tr -d '\r')" != "1" ]; do sleep 1; done

base_path="/data/adb/modules/revanced/revanced.apk"
stock_path=$( pm path com.google.android.youtube | grep base | sed 's/package://g' )
chcon u:object_r:apk_data_file:s0 $base_path
mount -o bind $base_path $stock_path
