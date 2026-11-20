#!/system/bin/sh
#
# ThermalCore - offline mock-sysfs test suite
#
# Builds a fake /sys + /proc tree, points ThermalCore at it through
# THERMALCORE_SYSROOT, and exercises detection, profiles, backup/restore,
# guard mitigation + recovery, custom profile and JSON output.
#
# The real kernel state of the device is never touched.
#
# Usage (as root):  sh tests/mock_test.sh
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0

set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MOCK="${MOCK:-/data/local/tmp/tc_mock}"
DATA="${DATA:-/data/local/tmp/tc_test_data}"
TC="$REPO/bin/thermalcore"
PY="${PY:-/data/data/com.termux/files/usr/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"
command -v "$PY" >/dev/null 2>&1 || PY=""

PASS=0
FAIL=0
CASE=""

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
eq()   { [ "$2" = "$3" ] && ok "$1 = $2" || bad "$1: got '$2' want '$3'"; }
has()  { case "$2" in *"$3"*) ok "$1 contains '$3'" ;; *) bad "$1 missing '$3' (got: $2)" ;; esac; }
section() { printf '\n== %s ==\n' "$1"; }

wf() { mkdir -p "${1%/*}" 2>/dev/null; printf '%s\n' "$2" > "$1"; }

rf() { cat "$1" 2>/dev/null | tr -d '\r' | head -n 1; }

# make a path non-writable by replacing the file with a directory
break_path() { rm -f "$1" 2>/dev/null; mkdir -p "$1" 2>/dev/null; }
fix_path()   { rmdir "$1" 2>/dev/null; wf "$1" "$2"; }

build_mock() {
  rm -rf "$MOCK" "$DATA"
  mkdir -p "$DATA"

  # --- cpufreq: 2 clusters -------------------------------------------------
  _c0="$MOCK/sys/devices/system/cpu/cpufreq/policy0"
  wf "$_c0/scaling_governor" sugov_ext
  wf "$_c0/scaling_available_governors" "sugov_ext performance powersave"
  wf "$_c0/scaling_available_frequencies" "300000 500000 700000 900000 1100000 1300000 1500000 1700000 1900000 2000000"
  wf "$_c0/cpuinfo_min_freq" 300000
  wf "$_c0/cpuinfo_max_freq" 2000000
  wf "$_c0/scaling_min_freq" 300000
  wf "$_c0/scaling_max_freq" 2000000
  wf "$_c0/scaling_cur_freq" 800000
  wf "$_c0/related_cpus" "0 1 2 3"
  wf "$_c0/sugov_ext/up_rate_limit_us" 500
  wf "$_c0/sugov_ext/down_rate_limit_us" 1000

  _c4="$MOCK/sys/devices/system/cpu/cpufreq/policy4"
  wf "$_c4/scaling_governor" sugov_ext
  wf "$_c4/scaling_available_governors" "sugov_ext performance powersave"
  wf "$_c4/scaling_available_frequencies" "400000 600000 800000 1000000 1200000 1400000 1600000 1800000 2000000 2200000 2400000"
  wf "$_c4/cpuinfo_min_freq" 400000
  wf "$_c4/cpuinfo_max_freq" 2400000
  wf "$_c4/scaling_min_freq" 400000
  wf "$_c4/scaling_max_freq" 2400000
  wf "$_c4/scaling_cur_freq" 800000
  wf "$_c4/related_cpus" "4 5 6 7"
  wf "$_c4/sugov_ext/up_rate_limit_us" 500
  wf "$_c4/sugov_ext/down_rate_limit_us" 1000

  # --- GPU: mali devfreq ---------------------------------------------------
  _g="$MOCK/sys/class/devfreq/13000000.mali"
  wf "$_g/name" "13000000.mali"
  wf "$_g/governor" dummy
  wf "$_g/available_governors" "dummy simple_ondemand performance powersave userspace"
  wf "$_g/available_frequencies" "800000000 700000000 600000000 500000000 400000000 300000000 200000000"
  wf "$_g/min_freq" 200000000
  wf "$_g/max_freq" 800000000
  wf "$_g/cur_freq" 400000000

  # --- thermal zones -------------------------------------------------------
  wf "$MOCK/sys/class/thermal/thermal_zone0/type" cpu
  wf "$MOCK/sys/class/thermal/thermal_zone0/temp" 45000
  wf "$MOCK/sys/class/thermal/thermal_zone1/type" battery
  wf "$MOCK/sys/class/thermal/thermal_zone1/temp" 380
  wf "$MOCK/sys/class/thermal/thermal_zone2/type" gpuss
  wf "$MOCK/sys/class/thermal/thermal_zone2/temp" -274000

  # --- battery -------------------------------------------------------------
  _b="$MOCK/sys/class/power_supply/battery"
  wf "$_b/temp" 380
  wf "$_b/status" Discharging
  wf "$_b/capacity" 77
  wf "$_b/current_now" -450000
  wf "$_b/voltage_now" 4200000
  wf "$_b/health" Good

  # --- storage -------------------------------------------------------------
  _s="$MOCK/sys/block/sda/queue"
  wf "$_s/scheduler" "[mq-deadline] kyber bfq"
  wf "$_s/read_ahead_kb" 128
  _s2="$MOCK/sys/block/mmcblk0/queue"
  wf "$_s2/scheduler" "none mq-deadline"
  wf "$_s2/read_ahead_kb" 128

  # --- vm ------------------------------------------------------------------
  wf "$MOCK/proc/sys/vm/swappiness" 100
  wf "$MOCK/proc/sys/vm/vfs_cache_pressure" 80
  wf "$MOCK/proc/sys/vm/dirty_ratio" 20
  wf "$MOCK/proc/sys/vm/dirty_background_ratio" 5
  wf "$MOCK/proc/sys/vm/compaction_proactiveness" 0
  wf "$MOCK/proc/sys/vm/watermark_boost_factor" 100000

  # --- procfs --------------------------------------------------------------
  wf "$MOCK/proc/stat" "cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0"
  wf "$MOCK/proc/uptime" "12345.67 98765.43"
  wf "$MOCK/proc/loadavg" "0.50 0.40 0.30 1/100 1234"
  wf "$MOCK/proc/meminfo" "MemTotal:        7594800 kB
MemFree:         1000000 kB
MemAvailable:    4000000 kB"
  wf "$MOCK/proc/cpuinfo" "Hardware\t: MT6878
processor\t: 0"

  mkdir -p "$MOCK/data/adb/ksu" 2>/dev/null
}

run_tc() { THERMALCORE_NO_DESC_SYNC=1 "$TC" "$@" 2>&1; }

# ---------------------------------------------------------------------------
section "build mock environment"
build_mock
ok "mock tree at $MOCK"
export THERMALCORE_SYSROOT="$MOCK"
export THERMALCORE_DATA="$DATA"
export THERMALCORE_MODDIR="$REPO"
$TC reset-config >/dev/null 2>&1
eq "default profile" "$($TC config get CURRENT_PROFILE)" balanced

# ---------------------------------------------------------------------------
section "detection"
DET="$($TC detect)"
printf '%s\n' "$DET" | grep -Eq 'cpu_cluster_count[[:space:]]+2' && ok "detect cpu clusters = 2" || bad "detect cpu clusters"
printf '%s\n' "$DET" | grep -Eq 'gpu_kind[[:space:]]+devfreq' && ok "detect gpu kind = devfreq" || bad "detect gpu kind"
printf '%s\n' "$DET" | grep -Eq 'gpu_name[[:space:]]+13000000\.mali' && ok "detect gpu name" || bad "detect gpu name"
$TC detect --json > "$DATA/detect.json" 2>/dev/null
if [ -n "$PY" ] && "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("gpu_kind")=="devfreq", d' "$DATA/detect.json"; then
  ok "detect --json valid"
else
  bad "detect --json invalid (PY=$PY)"
fi

# ---------------------------------------------------------------------------
section "status json"
$TC status --json > "$DATA/status.json" 2>/dev/null
if [ -n "$PY" ]; then
"$PY" - "$DATA/status.json" <<'PY' && ok "status --json values sane" || bad "status --json values wrong"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["battery"]["temp_c"] == 38.0, d["battery"]
assert d["device"]["root_manager"] in ("KernelSU", "Magisk", "APatch", "Unknown"), d
assert len(d["cpu"]["clusters"]) == 2, d["cpu"]
assert d["thermal_max_c"] == 45.0, d["thermal_max_c"]
assert d["thermal_max_type"] == "cpu", d["thermal_max_type"]
assert d["module"]["profile"] == "balanced", d["module"]
assert len(d["thermals"]) == 2, d["thermals"]
assert d["storage"][0]["dev"] in ("mmcblk0", "sda"), d["storage"]
assert d["vm"]["swappiness"] == 100, d["vm"]
assert d["gpu"]["governor"] == "dummy", d["gpu"]
PY
else
  bad "status --json skipped (no python3)"
fi

# ---------------------------------------------------------------------------
section "backup + balanced apply"
$TC backup base >/dev/null 2>&1
OUT="$(run_tc apply balanced)"; RC=$?
eq "apply balanced rc" "$RC" 0
has "balanced output" "$OUT" "applied: balanced"
eq "balanced cpu gov kept" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" sugov_ext
eq "balanced cpu max 95%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1900000
eq "balanced gpu gov kept" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" dummy
eq "balanced gpu max 90%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 700000000
eq "balanced watermark boost off" "$(rf "$MOCK/proc/sys/vm/watermark_boost_factor")" 0

# ---------------------------------------------------------------------------
section "performance apply"
OUT="$(run_tc apply performance)"; RC=$?
eq "apply performance rc" "$RC" 0
eq "perf cpu0 gov" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" performance
eq "perf cpu4 gov" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_governor")" performance
eq "perf gpu gov" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" performance
eq "perf gpu min floor 20%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/min_freq")" 300000000
eq "perf swappiness" "$(rf "$MOCK/proc/sys/vm/swappiness")" 30
eq "perf compaction" "$(rf "$MOCK/proc/sys/vm/compaction_proactiveness")" 10
eq "perf scheduler" "$(rf "$MOCK/sys/block/sda/queue/scheduler")" kyber
eq "perf read_ahead" "$(rf "$MOCK/sys/block/sda/queue/read_ahead_kb")" 512
eq "perf profile" "$($TC config get CURRENT_PROFILE)" performance

# ---------------------------------------------------------------------------
section "rollback on write failure"
break_path "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
OUT="$(run_tc apply battery_saver)"; RC=$?
eq "failed apply rc" "$RC" 1
has "rollback message" "$OUT" "previous state restored"
eq "rollback cpu0 gov" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" performance
eq "rollback cpu4 gov" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_governor")" performance
eq "rollback gpu gov" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" performance
eq "rollback gpu max" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 800000000
eq "rollback swappiness" "$(rf "$MOCK/proc/sys/vm/swappiness")" 30
eq "rollback profile pointer" "$($TC config get CURRENT_PROFILE)" performance
fix_path "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 2400000
$TC restore >/dev/null 2>&1 && ok "restore after fixing node" || bad "restore after fixing node"
eq "restored cpu4 max" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 2400000

# ---------------------------------------------------------------------------
section "battery saver apply + restore base"
OUT="$(run_tc apply battery_saver)"; RC=$?
eq "apply battery_saver rc" "$RC" 0
eq "saver cpu0 gov kept" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" sugov_ext
eq "saver cpu0 max 75%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1500000
eq "saver cpu4 max 75%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 1800000
eq "saver gpu gov smart" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" simple_ondemand
eq "saver gpu max 60%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 400000000
eq "saver swappiness" "$(rf "$MOCK/proc/sys/vm/swappiness")" 60
eq "saver vfs" "$(rf "$MOCK/proc/sys/vm/vfs_cache_pressure")" 50
eq "saver watermark boost off" "$(rf "$MOCK/proc/sys/vm/watermark_boost_factor")" 0
$TC restore base >/dev/null 2>&1 && ok "restore base" || bad "restore base"
eq "base cpu0 gov" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" sugov_ext
eq "base cpu0 max" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 2000000
eq "base cpu4 max" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 2400000
eq "base gpu gov" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" dummy
eq "base gpu max" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 800000000
eq "base gpu min" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/min_freq")" 200000000
eq "base swappiness" "$(rf "$MOCK/proc/sys/vm/swappiness")" 100
eq "base watermark boost" "$(rf "$MOCK/proc/sys/vm/watermark_boost_factor")" 100000
eq "base scheduler" "$(rf "$MOCK/sys/block/sda/queue/scheduler")" mq-deadline
eq "base read_ahead" "$(rf "$MOCK/sys/block/sda/queue/read_ahead_kb")" 128
eq "base profile pointer" "$($TC config get CURRENT_PROFILE)" balanced

# ---------------------------------------------------------------------------
section "smartherm apply: cool + efficient, no speed loss"
$TC profiles | grep -q 'smartherm' && ok "profiles lists smartherm" || bad "profiles lists smartherm"
OUT="$(run_tc apply smartherm)"; RC=$?
eq "apply smartherm rc" "$RC" 0
eq "smartherm cpu0 gov kept" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" sugov_ext
eq "smartherm cpu0 max 88%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1700000
eq "smartherm cpu4 max 88%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 2000000
eq "smartherm gpu gov kept" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/governor")" dummy
eq "smartherm gpu max 80%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 600000000
eq "smartherm swappiness untouched" "$(rf "$MOCK/proc/sys/vm/swappiness")" 100
eq "smartherm vfs caches kept" "$(rf "$MOCK/proc/sys/vm/vfs_cache_pressure")" 60
eq "smartherm compaction light" "$(rf "$MOCK/proc/sys/vm/compaction_proactiveness")" 10
eq "smartherm watermark boost off" "$(rf "$MOCK/proc/sys/vm/watermark_boost_factor")" 0
eq "smartherm profile" "$($TC config get CURRENT_PROFILE)" smartherm
$TC restore base >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "custom profile"
$TC custom setmany CPU_MAX_FREQ_PCT=50 GPU_MAX_FREQ_PCT=25 VM_SWAPPINESS=-1 >/dev/null 2>&1
OUT="$(run_tc apply custom)"; RC=$?
eq "apply custom rc" "$RC" 0
eq "custom cpu0 max 50%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 900000
eq "custom cpu4 max 50%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 1200000
eq "custom gpu max 25%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 200000000
eq "custom vm untouched" "$(rf "$MOCK/proc/sys/vm/swappiness")" 100
eq "custom profile" "$($TC config get CURRENT_PROFILE)" custom
$TC restore base >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "thermal guard: trigger, mitigate, recover"
THERMALCORE_NO_DESC_SYNC=1 "$TC" apply performance >/dev/null 2>&1
$TC config set THERMAL_GUARD_BATTERY_MAX_C 38 >/dev/null 2>&1
$TC config set THERMAL_GUARD_INTERVAL 10 >/dev/null 2>&1
THERMALCORE_NO_DESC_SYNC=1 "$TC" guard start >/dev/null 2>&1
sleep 2
eq "guard cpu0 capped 70%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1300000
eq "guard cpu4 capped 70%" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" 1600000
eq "guard gpu capped 60%" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 400000000
gst() { grep "^$1=" "$DATA/guard.state" 2>/dev/null | head -n 1 | cut -d= -f2; }
eq "guard triggered flag" "$(gst triggered)" 1

wf "$MOCK/sys/class/power_supply/battery/temp" 360
wf "$MOCK/sys/thermal/thermal_zone1/temp" 360
_i=0
while [ "$_i" -lt 20 ]; do
  [ "$(gst triggered)" = "0" ] && break
  sleep 1; _i=$((_i + 1))
done
eq "guard recovered flag" "$(gst triggered)" 0
eq "guard recovery re-applied profile" "$(rf "$MOCK/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 2000000
eq "guard recovery gpu max" "$(rf "$MOCK/sys/class/devfreq/13000000.mali/max_freq")" 800000000
$TC guard stop >/dev/null 2>&1 && ok "guard stopped" || bad "guard stop"

# ---------------------------------------------------------------------------
section "misc commands"
$TC log 5 >/dev/null 2>&1 && ok "log tail" || bad "log tail"
$TC backups >/dev/null 2>&1 && ok "backups list" || bad "backups list"
$TC profiles | grep -q '\* custom' || $TC profiles | grep -q '\* balanced' || $TC profiles | grep -q '\* performance' \
  && ok "profiles marks active" || bad "profiles output"
$TC doctor >/dev/null 2>&1; DR=$?
[ "$DR" -eq 0 ] && ok "doctor rc=0" || bad "doctor rc=$DR"

# ---------------------------------------------------------------------------
section "module.prop description shows active profile"
_dsync="$DATA/descsync"
rm -rf "$_dsync"
mkdir -p "$_dsync/bin" "$_dsync/lib" "$_dsync/profiles"
cp "$REPO/bin/thermalcore" "$_dsync/bin/"
cp "$REPO"/lib/*.sh "$_dsync/lib/"
cp "$REPO"/profiles/*.conf "$_dsync/profiles/"
cp "$REPO/module.prop" "$_dsync/"
cp "$REPO/module.prop" "$_dsync/module.prop.orig"
THERMALCORE_MODDIR="$_dsync" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" "$TC" apply gaming >/dev/null 2>&1
grep -q '🎮 Gaming' "$_dsync/module.prop" && ok "desc shows gaming" || bad "desc shows gaming"
THERMALCORE_MODDIR="$_dsync" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" "$TC" apply battery_saver >/dev/null 2>&1
grep -q '🔋 Battery Saver' "$_dsync/module.prop" && ok "desc shows battery saver" || bad "desc shows battery saver"
grep -q '^description=\[' "$_dsync/module.prop" && ok "desc keeps prefix format" || bad "desc keeps prefix format"
THERMALCORE_NO_DESC_SYNC=1 "$TC" config set CURRENT_PROFILE balanced >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "adaptive relief: RAM relief engage/revert + night lean"
_rl_data="$DATA/relief"
rm -rf "$_rl_data"
mkdir -p "$_rl_data"
# meminfo: total 4GB, available 8% (low)
wf "$MOCK/proc/meminfo" "MemTotal:        4000000 kB
MemFree:          300000 kB
MemAvailable:      320000 kB"
wf "$MOCK/sys/class/backlight/backlight/brightness" 120
wf "$MOCK/sys/class/backlight/backlight/max_brightness" 255
wf "$MOCK/proc/sys/vm/vfs_cache_pressure" 80
wf "$MOCK/proc/sys/vm/compaction_proactiveness" 20
wf "$MOCK/proc/sys/vm/watermark_boost_factor" 0

_rl_src() {
  THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$_rl_data" THERMALCORE_MODDIR="$REPO" \
  THERMALCORE_TEST_HOUR="$1" THERMALCORE_MODULES_DIR="$DATA/nomod" \
  sh -c ". $REPO/lib/core.sh; . $REPO/lib/detect.sh; . $REPO/lib/backup.sh; . $REPO/lib/profiles.sh; . $REPO/lib/status.sh; . $REPO/lib/relief.sh; relief_tick; cat \"\$THERMALCORE_DATA/relief.state\" 2>/dev/null; echo \"VM: \$(cat \"\$THERMALCORE_SYSROOT/proc/sys/vm/vfs_cache_pressure\")\"; echo \"COMP: \$(cat \"\$THERMALCORE_SYSROOT/proc/sys/vm/compaction_proactiveness\")\""
}
# tick 1: relief arms (not yet engaged — needs 2 consecutive low samples)
_rl_out="$(_rl_src 10)"
has "relief tick1 state" "$_rl_out" "mode=none"
# tick 2: engaged
_rl_out="$(_rl_src 10)"
has "relief tick2 engaged" "$_rl_out" "mode=relief"
has "relief vfs raised" "$_rl_out" "VM: 200"
has "relief compaction raised" "$_rl_out" "COMP: 50"
eq "relief watermark raised" "$(cat "$MOCK/proc/sys/vm/watermark_boost_factor" 2>/dev/null)" "100000"
# meminfo improves -> disengage + revert to balanced baseline
wf "$MOCK/proc/meminfo" "MemTotal:        4000000 kB
MemAvailable:     1400000 kB"
_rl_out="$(_rl_src 10)"
has "relief reverted state" "$_rl_out" "mode=none"
eq "relief vfs reverted" "$(cat "$MOCK/proc/sys/vm/vfs_cache_pressure" 2>/dev/null)" "80"

# night lean: screen off for 20+ samples, hour 02, in window 01-06
wf "$MOCK/sys/class/backlight/backlight/brightness" 0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do _rl_out="$(_rl_src 2)"; done
has "night engaged" "$_rl_out" "mode=night"
eq "night compaction parked" "$(cat "$MOCK/proc/sys/vm/compaction_proactiveness" 2>/dev/null)" "0"
eq "night vfs lean" "$(cat "$MOCK/proc/sys/vm/vfs_cache_pressure" 2>/dev/null)" "200"
# wake up (screen on) inside window -> night disengages
wf "$MOCK/sys/class/backlight/backlight/brightness" 200
_rl_out="$(_rl_src 2)"
has "night reverted on wake" "$_rl_out" "mode=none"
eq "night vfs reverted" "$(cat "$MOCK/proc/sys/vm/vfs_cache_pressure" 2>/dev/null)" "80"
# outside window even with screen off -> stays none
wf "$MOCK/sys/class/backlight/backlight/brightness" 0
_rl_out="$(_rl_src 15)"
has "night blocked outside window" "$_rl_out" "mode=none"

# both features disabled -> clean state + no writes
_rl_out="$(THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$_rl_data" THERMALCORE_MODDIR="$REPO" THERMALCORE_TEST_HOUR=2 THERMALCORE_MODULES_DIR="$DATA/nomod" sh -c ". $REPO/lib/core.sh; . $REPO/lib/detect.sh; . $REPO/lib/backup.sh; . $REPO/lib/profiles.sh; . $REPO/lib/status.sh; . $REPO/lib/relief.sh; THERMALCORE_NO_DESC_SYNC=1; export THERMALCORE_NO_DESC_SYNC; config_set ENABLE_RAM_RELIEF 0; config_set NIGHT_LEAN 0; relief_tick; cat \"\$THERMALCORE_DATA/relief.state\"; echo \"VFS: \$(cat \"\$THERMALCORE_SYSROOT/proc/sys/vm/vfs_cache_pressure\")\"")"
has "both disabled -> mode none" "$_rl_out" "mode=none"
has "both disabled -> vfs untouched by relief" "$_rl_out" "VFS: 80"

# relief status CLI parses
_tc_out="$(THERMALCORE_MODDIR="$REPO" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" THERMALCORE_NO_DESC_SYNC=1 sh "$TC" relief status 2>/dev/null)"
has "relief status output" "$_tc_out" "ram relief : enabled (low <= 15%)"
has "relief status mode line" "$_tc_out" "mode       :"

# ---------------------------------------------------------------------------
section "conflicts report + relief in status json"
mkdir -p "$DATA/mods/magnetar" "$DATA/mods/thermal-core"
wf "$DATA/mods/magnetar/module.prop" "id=magnetar
name=Magnetar Updater
description=Performance governor tuner"
wf "$DATA/mods/thermal-core/module.prop" "id=thermal-core
name=ThermalCore
description=Universal thermal & power core"
_json="$(THERMALCORE_MODDIR="$REPO" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" THERMALCORE_MODULES_DIR="$DATA/mods" THERMALCORE_NO_DESC_SYNC=1 sh -c ". $REPO/lib/core.sh; . $REPO/lib/detect.sh; . $REPO/lib/backup.sh; . $REPO/lib/profiles.sh; . $REPO/lib/status.sh; . $REPO/lib/relief.sh; status_json")"
printf '%s' "$_json" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
r=d['module'].get('relief',{})
assert r.get('enabled') is True, 'relief.enabled missing'
assert r.get('night') is True, 'relief.night missing'
assert 'mode' in r and 'mem_avail_pct' in r, 'relief fields missing'
assert isinstance(d.get('conflicts'), list), 'conflicts not list'
assert 'magnetar' in d['conflicts'], 'magnetar not detected'
assert 'thermal-core' not in d['conflicts'], 'self detected'
" && ok "status json: relief fields + conflict detection" || bad "status json: relief/conflicts"
# no conflicting modules -> empty array
mkdir -p "$DATA/mods2/innocent"
wf "$DATA/mods2/innocent/module.prop" "id=innocent
name=Innocent Module
description=Just fonts"
_json="$(THERMALCORE_MODDIR="$REPO" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" THERMALCORE_MODULES_DIR="$DATA/mods2" THERMALCORE_NO_DESC_SYNC=1 sh -c ". $REPO/lib/core.sh; . $REPO/lib/detect.sh; . $REPO/lib/backup.sh; . $REPO/lib/profiles.sh; . $REPO/lib/status.sh; . $REPO/lib/relief.sh; status_json")"
printf '%s' "$_json" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('conflicts') == [], 'expected empty conflicts, got %r' % (d.get('conflicts'),)
" && ok "status json: conflicts empty when clean" || bad "status json: conflicts should be empty"
# log export (mocked export dir)
_mkdir_export="$DATA/sdcard"
_tc_out="$(THERMALCORE_MODDIR="$REPO" THERMALCORE_SYSROOT="$MOCK" THERMALCORE_DATA="$DATA" THERMALCORE_EXPORT_DIR="$_mkdir_export" sh "$TC" log export 2>/dev/null)"
case "$_tc_out" in
  *"$_mkdir_export/thermalcore-log-"*) ok "log export path ($_mkdir_export)" ;;
  *) bad "log export failed: $_tc_out" ;;
esac
[ -f "$_tc_out" ] && ok "log export file exists" || bad "log export file missing"

printf '\n== summary ==\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
