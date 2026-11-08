#!/system/bin/sh
#
# ThermalCore - service.d cleanup hook (runs after uninstall on next boot)
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

for prop in persist.sys.rianixia.learning_enabled \
            persist.sys.rianixia.thermalcore-bigdata.path \
            persist.sys.rianixia.thermalcore-debug \
            persist.sys.rianixia.thermal-auditlogs \
            persist.sys.rianixia.thermal_path; do
  resetprop -p --delete "$prop" 2>/dev/null
done

# one-shot hook: remove ourselves once cleanup is done
rm -f "$0" 2>/dev/null
exit 0
