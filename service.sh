#!/system/bin/sh
#
# ThermalCore - late_start service
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

MODDIR="${0%/*}"
export THERMALCORE_MODDIR="$MODDIR"

. "$MODDIR/lib/core.sh"
. "$MODDIR/lib/detect.sh"
. "$MODDIR/lib/backup.sh"
. "$MODDIR/lib/profiles.sh"
. "$MODDIR/lib/status.sh"

# Wait for boot to complete (max 5 minutes, then proceed anyway)
_waited=0
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
  _waited=$((_waited + 1))
  [ "$_waited" -ge 300 ] && break
done

mkdir -p /data/adb/thermal-core/backup /data/adb/thermal-core/logs

# Seed default config / custom profile if missing
init_default_config

# Fresh hardware detection (refresh cache once per boot)
detect_refresh >/dev/null 2>&1

# Re-apply the user's chosen profile (sysfs resets across reboots)
_profile="$(current_profile)"
log "service: applying profile '$_profile' after boot"
apply_profile "$_profile" >/dev/null 2>&1 || log "service: profile apply reported failures (see log)"

# Default daemon properties (kept for the ThermalCore AI engine)
if [ -z "$(getprop persist.sys.rianixia.learning_enabled)" ]; then
  setprop persist.sys.rianixia.learning_enabled "true"
fi
if [ -z "$(getprop persist.sys.rianixia.thermalcore-bigdata.path)" ]; then
  mkdir -p /data/adb/.config/thermal-core
  setprop persist.sys.rianixia.thermalcore-bigdata.path "/data/adb/.config/thermal-core"
fi

# Start ThermalCore AI daemon (existing engine, kept intact)
if ! pidof thermal-cored >/dev/null 2>&1; then
  ( "$MODDIR/thermal-cored" >/dev/null 2>&1 & )
  sleep 1
  if ! pidof thermal-cored >/dev/null 2>&1; then
    log "service: AI daemon did not stay alive on this ROM — profiles/guard/WebUI remain active"
  fi
fi

# Start thermal guard when enabled (lightweight: one sensor read per interval)
if [ "$(config_get ENABLE_THERMAL_GUARD)" != "0" ]; then
  guard_start >/dev/null 2>&1
fi

# Rewrite module.prop description with run state
module_prop_set_status

# If the module got disabled, restore pristine module.prop
if [ -f /data/adb/modules/thermal-core/disable ] && [ -f "$MODDIR/module.prop.orig" ]; then
  cp "$MODDIR/module.prop.orig" "$MODDIR/module.prop"
fi
exit 0
