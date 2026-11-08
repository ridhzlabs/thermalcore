#!/system/bin/sh
#
# ThermalCore - uninstall script
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

MODDIR="${0%/*}"
export THERMALCORE_MODDIR="$MODDIR"

# 1) stop our runtime pieces
if [ -f /data/adb/thermal-core/guard.pid ]; then
  _gp="$(cat /data/adb/thermal-core/guard.pid 2>/dev/null)"
  case "$_gp" in (''|*[!0-9]*) ;; (*) kill "$_gp" 2>/dev/null ;; esac
fi
for p in $(pidof thermal-cored); do
  kill -TERM "$p" 2>/dev/null
done
sleep 1
for p in $(pidof thermal-cored); do
  kill -9 "$p" 2>/dev/null
done

# 2) restore the user's original (pre-install) sysfs state when available
if [ -f /data/adb/thermal-core/backup/install-initial/state ]; then
  . "$MODDIR/lib/core.sh" 2>/dev/null
  . "$MODDIR/lib/detect.sh" 2>/dev/null
  . "$MODDIR/lib/backup.sh" 2>/dev/null
  backup_restore "install-initial" >/dev/null 2>&1
fi

# 3) restore pristine module.prop
if [ -f "$MODDIR/module.prop.orig" ]; then
  cp "$MODDIR/module.prop.orig" "$MODDIR/module.prop"
fi

# 4) delete persist props if resetprop is available right now (service.d
#    cleanup hook handles the rest on next boot as a fallback)
if command -v resetprop >/dev/null 2>&1; then
  for prop in persist.sys.rianixia.learning_enabled \
              persist.sys.rianixia.thermalcore-bigdata.path \
              persist.sys.rianixia.thermalcore-debug \
              persist.sys.rianixia.thermal-auditlogs \
              persist.sys.rianixia.thermal_path; do
    resetprop -p --delete "$prop" 2>/dev/null
  done
fi

# 5) remove module-private data (config, logs, backups) + daemon learning data
rm -rf /data/adb/thermal-core /data/adb/.config/thermal-core

exit 0
