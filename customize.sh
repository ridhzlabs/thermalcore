#
# ThermalCore - Magisk/KernelSU/APatch installer (customize.sh)
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

SKIPUNZIP=1

# ---------------------------------------------------------------------------
# Extract payload
# ---------------------------------------------------------------------------
ui_print "- ThermalCore by ridhzxlabs — installing"

unzip -o "$ZIPFILE" post-fs-data.sh -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" service.sh -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" uninstall.sh -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" cleanup.sh -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" thermal-cored -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" module.prop -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" banner.jpg -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" 'bin/*' -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" 'lib/*' -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" 'profiles/*' -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" 'webroot/*' -d "$MODPATH" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
find "$MODPATH" -type d -exec chmod 0755 {} \;
find "$MODPATH" -type f -exec chmod 0644 {} \;
chmod 0755 "$MODPATH/thermal-cored" "$MODPATH/bin/thermalcore" \
           "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/uninstall.sh"

# ---------------------------------------------------------------------------
# Keep a pristine copy of module.prop (used for status/restore)
# ---------------------------------------------------------------------------
cp -f "$MODPATH/module.prop" "$MODPATH/module.prop.orig"
chmod 0644 "$MODPATH/module.prop.orig"

# ---------------------------------------------------------------------------
# Private data dir + one-time stock-state backup (safety net for uninstall)
# ---------------------------------------------------------------------------
mkdir -p /data/adb/thermal-core/backup /data/adb/thermal-core/logs
chmod 0755 /data/adb/thermal-core /data/adb/thermal-core/backup /data/adb/thermal-core/logs 2>/dev/null

if [ ! -f /data/adb/thermal-core/backup/install-initial/state ]; then
  . "$MODPATH/lib/core.sh"
  . "$MODPATH/lib/detect.sh"
  . "$MODPATH/lib/backup.sh"
  THERMALCORE_MODDIR="$MODPATH" backup_snapshot install-initial "pre-install" >/dev/null 2>&1 \
    && ui_print "- Stock sysfs state backed up (install-initial)" \
    || ui_print "! Warning: initial backup failed (module still safe to use)"
fi

# Seed default config + custom profile only when absent (keep user settings on upgrade)
if [ ! -f /data/adb/thermal-core/config.conf ]; then
  printf 'CURRENT_PROFILE=balanced\nENABLE_CPU_TWEAKS=1\nENABLE_GPU_TWEAKS=1\nENABLE_IO_TWEAKS=1\nENABLE_VM_TWEAKS=1\nENABLE_THERMAL_GUARD=1\nTHERMAL_GUARD_INTERVAL=30\nTHERMAL_GUARD_BATTERY_MAX_C=45\nTHERMAL_GUARD_RECOVER_C=42\nBACKUP_ON_APPLY=1\n' \
    > /data/adb/thermal-core/config.conf
  chmod 0644 /data/adb/thermal-core/config.conf
fi
if [ ! -f /data/adb/thermal-core/custom.conf ]; then
  cp -f "$MODPATH/profiles/custom_template.conf" /data/adb/thermal-core/custom.conf
  chmod 0644 /data/adb/thermal-core/custom.conf
fi

# ---------------------------------------------------------------------------
# service.d hook: strip persist props after uninstall
# ---------------------------------------------------------------------------
ui_print "- Install cleanup hook"
mkdir -p /data/adb/service.d
cp -f "$MODPATH/cleanup.sh" /data/adb/service.d/thermalcore_cleanup.sh
chmod 0755 /data/adb/service.d/thermalcore_cleanup.sh

# Keep daemon bigdata path writable
mkdir -p /data/adb/.config/thermal-core
chmod 0755 /data/adb/.config/thermal-core 2>/dev/null

chmod +x "$MODPATH"

ui_print "- ThermalCore installed."
ui_print "- WebUI: open this module in KernelSU / APatch / MMRL and tap WebUI."
