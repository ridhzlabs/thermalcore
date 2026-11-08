#!/system/bin/sh
#
# ThermalCore - post-fs-data (early boot)
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

MODDIR="${0%/*}"
MODPROP="$MODDIR/module.prop"
MODPROP_ORIG="$MODDIR/module.prop.orig"

# Revert runtime-written module.prop (restores pristine file each boot)
if [ -f "$MODPROP_ORIG" ] && [ -f "$MODPROP" ]; then
  cp "$MODPROP_ORIG" "$MODPROP"
fi

# Clean stale guard pidfile (guard is (re)started by service.sh)
[ -f /data/adb/thermal-core/guard.pid ] && rm -f /data/adb/thermal-core/guard.pid

# When module is disabled, drop the original prop back in place
if [ -f /data/adb/modules/thermal-core/disable ] && [ -f "$MODPROP_ORIG" ]; then
  cp "$MODPROP_ORIG" "$MODPROP"
fi
exit 0
