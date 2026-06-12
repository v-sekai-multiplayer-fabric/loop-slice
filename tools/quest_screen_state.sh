#!/usr/bin/env bash
ADB=~/Android/Sdk/platform-tools/adb
[ -n "$($ADB get-state 2>/dev/null | grep device)" ] || { echo "NO_DEVICE"; exit 2; }
wake=$($ADB shell dumpsys power 2>/dev/null | grep -oE 'mWakefulness=[A-Za-z]+' | head -1 | cut -d= -f2)
disp=$($ADB shell dumpsys display 2>/dev/null | grep -m1 -oE 'mState=[A-Z]+' | cut -d= -f2)
hb=$(timeout 2 $ADB logcat -s VrApi 2>/dev/null | grep -m1 -oE 'FPS=[0-9]+/[0-9]+')
focus=$($ADB logcat -d 2>/dev/null | grep -oE "immersiveApp now is: '[^']*'" | tail -1 | sed "s/.*is: //")
[ -n "$hb" ] && v=DISPLAYING || { [ "$disp" = "OFF" -o "$wake" = "Asleep" ] && v=SCREEN_OFF || v=ON_NOT_RENDERING; }
echo "$v  [wake=$wake display=$disp heartbeat=${hb:-none} focus=${focus:-none}]"
