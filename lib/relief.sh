#
# ThermalCore - adaptive relief library: reversible RAM relief + night lean
#
# Inspired by community modules' adaptive RAM handling, redesigned to be
# multitasking-safe: kernel-cache trims only, fully reversible, never kills
# apps, never drops the page cache, never touches foreground memory.
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

THERMALCORE_RELIEF_PID="$THERMALCORE_DATA/relief.pid"
THERMALCORE_RELIEF_STATE="$THERMALCORE_DATA/relief.state"

# ---------------------------------------------------------------------------
# relief_state_get KEY [DEFAULT] / relief_state_set KEY VALUE
# ---------------------------------------------------------------------------
relief_state_get() {
  config_get "$1" "$THERMALCORE_RELIEF_STATE" 2>/dev/null || print -r -- "${2:-}"
}

relief_state_set() {
  config_set "$1" "$2" "$THERMALCORE_RELIEF_STATE"
}

# ---------------------------------------------------------------------------
# relief_meminfo -> sets _MT/_MA (kB). Returns 1 when unavailable.
# ---------------------------------------------------------------------------
relief_meminfo() {
  _MT=0; _MA=0
  _rm_file="$(spath /proc/meminfo)"
  [ -f "$_rm_file" ] || return 1
  while IFS= read -r _rm_line; do
    case "$_rm_line" in
      MemTotal:*)     _v="${_rm_line#*:}"; str_trim "$_v"; _ST="${_ST%% *}"; _MT="$_ST" ;;
      MemAvailable:*) _v="${_rm_line#*:}"; str_trim "$_v"; _ST="${_ST%% *}"; _MA="$_ST" ;;
    esac
  done < "$_rm_file"
  is_uint "$_MT" && [ "$_MT" -gt 0 ] && is_uint "$_MA" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# relief_screen -> sets _SCREEN: 1 on, 0 off, 255 unknown (never writes)
# ---------------------------------------------------------------------------
relief_screen() {
  _SCREEN=255
  _rs_sum=0; _rs_seen=0
  for _rs_b in "$THERMALCORE_SYSROOT"/sys/class/backlight/*/brightness; do
    [ -f "$_rs_b" ] || continue
    _rs_seen=1
    read_val "${_rs_b#"$THERMALCORE_SYSROOT"}"; _rs_v="$_RV"
    is_uint "$_rs_v" || _rs_v=0
    [ "$_rs_v" -gt 0 ] && _rs_sum=$((_rs_sum + _rs_v))
  done
  [ "$_rs_seen" = "1" ] || return 0
  [ "$_rs_sum" -gt 0 ] && _SCREEN=1 || _SCREEN=0
  return 0
}

# ---------------------------------------------------------------------------
# relief_hour -> prints current hour (00-23); test override via env
# ---------------------------------------------------------------------------
relief_hour() {
  if [ -n "${THERMALCORE_TEST_HOUR:-}" ]; then
    print -r -- "$THERMALCORE_TEST_HOUR"
    return 0
  fi
  date +%H 2>/dev/null || print -r -- "0"
}

# ---------------------------------------------------------------------------
# relief_in_night_window -> 0 when hour lies inside [START, END) (wraps at 24h)
# ---------------------------------------------------------------------------
relief_in_night_window() {
  _ns="$(config_get NIGHT_START_HOUR)"; is_uint "$_ns" || _ns=1
  _ne="$(config_get NIGHT_END_HOUR)";   is_uint "$_ne" || _ne=6
  [ "$_ns" -gt 23 ] && _ns=23
  [ "$_ne" -gt 23 ] && _ne=23
  [ "$_ns" = "$_ne" ] && return 1
  if [ "$_ns" -lt "$_ne" ]; then
    [ "$_rh" -ge "$_ns" ] && [ "$_rh" -lt "$_ne" ]
  else
    [ "$_rh" -ge "$_ns" ] || [ "$_rh" -lt "$_ne" ]
  fi
}

# ---------------------------------------------------------------------------
# VM actions (respect the user's VM tuning domain switch)
# ---------------------------------------------------------------------------
relief_vm_ok() { [ "$(config_get ENABLE_VM_TWEAKS)" != "0" ]; }

relief_apply_relief() {
  relief_vm_ok || return 1
  write_file /proc/sys/vm/vfs_cache_pressure "200"
  write_file /proc/sys/vm/compaction_proactiveness "50"
  write_file /proc/sys/vm/watermark_boost_factor "100000"
}

relief_apply_night() {
  relief_vm_ok || return 1
  write_file /proc/sys/vm/vfs_cache_pressure "200"
  write_file /proc/sys/vm/compaction_proactiveness "0"
  write_file /proc/sys/vm/watermark_boost_factor "0"
}

relief_revert() {
  relief_vm_ok || return 0
  apply_profile "$(current_profile)" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# relief_tick - one evaluation cycle (no sleeping; used by loop and tests)
#
#   night lean : screen off >= ~10 min inside the night window
#                -> vfs_cache_pressure 200, compaction 0, watermark 0
#   RAM relief : MemAvailable <= LOW% for 2+ ticks while screen is in use
#                -> vfs_cache_pressure 200, compaction 50, watermark 100000
#   otherwise  : restore the active profile's VM baseline
#
# Priority: night > relief (no extra kswapd churn while the device sleeps).
# ---------------------------------------------------------------------------
relief_tick() {
  _rr_en="$(config_get ENABLE_RAM_RELIEF)"; [ "${_rr_en:-1}" = "1" ] && _rr_en=1 || _rr_en=0
  _nl_en="$(config_get NIGHT_LEAN)";        [ "${_nl_en:-1}" = "1" ] && _nl_en=1 || _nl_en=0
  _mode="$(relief_state_get mode none)"
  case "$_mode" in relief|night|none) : ;; *) _mode=none ;; esac
  _low="$(relief_state_get low_samples 0)"; is_uint "$_low" || _low=0
  _sof="$(relief_state_get screen_off_samples 0)"; is_uint "$_sof" || _sof=0

  relief_screen
  case "$_SCREEN" in
    0) _sof=$((_sof + 1)) ;;
    1) _sof=0 ;;
    *) : ;;
  esac

  if [ "$_rr_en" = "0" ] && [ "$_nl_en" = "0" ]; then
    if [ "$_mode" != "none" ]; then
      relief_revert
      log "relief: features disabled via config, VM restored to '$(current_profile)' baseline"
    fi
    relief_state_set mode none
    relief_state_set low_samples 0
    relief_state_set screen_off_samples 0
    return 0
  fi

  _new_mode="none"
  _av_pct=""

  # --- night lean (screen definitely off, stable for ~10 min) ---
  if [ "$_nl_en" = "1" ] && [ "$_SCREEN" = "0" ] && [ "$_sof" -ge 20 ] && relief_vm_ok; then
    _rh="$(relief_hour)"
    case "$_rh" in 0?) _rh="${_rh#0}" ;; esac
    is_uint "$_rh" || _rh=0
    if relief_in_night_window; then
      _new_mode="night"
    fi
  fi

  # --- RAM relief (screen in use or unknown; never at night) ---
  if [ "$_new_mode" = "none" ] && [ "$_rr_en" = "1" ] && [ "$_SCREEN" != "0" ] && relief_vm_ok; then
    if relief_meminfo; then
      _av_pct=$(( _MA * 100 / _MT ))
      _lowp="$(config_get RAM_RELIEF_LOW_PCT)"; is_uint "$_lowp" || _lowp=15
      [ "$_lowp" -lt 5 ]  && _lowp=5
      [ "$_lowp" -gt 50 ] && _lowp=50
      if [ "$_av_pct" -le "$_lowp" ]; then
        _low=$((_low + 1))
      else
        _low=0
      fi
      if [ "$_low" -ge 2 ]; then
        _new_mode="relief"
      elif [ "$_mode" = "relief" ]; then
        _hisp=$((_lowp + 10)); [ "$_hisp" -gt 60 ] && _hisp=60
        [ "$_av_pct" -lt "$_hisp" ] && _new_mode="relief"
      fi
      relief_state_set mem_avail_pct "$_av_pct"
    fi
  fi

  case "$_new_mode" in
    relief)
      if [ "$_mode" != "relief" ]; then
        relief_apply_relief && log "relief: RAM relief engaged (mem_avail=${_av_pct:-?}%) — kernel-cache trim only, reversible"
      fi
      ;;
    night)
      if [ "$_mode" != "night" ]; then
        relief_apply_night && log "relief: night lean engaged — caches lean, compaction parked"
      fi
      ;;
    none)
      if [ "$_mode" != "none" ]; then
        relief_revert
        log "relief: reverted VM to '$(current_profile)' baseline (mem_avail=${_av_pct:-n/a}%)"
      fi
      ;;
  esac

  relief_state_set mode "$_new_mode"
  relief_state_set low_samples "$_low"
  relief_state_set screen_off_samples "$_sof"
  return 0
}

# ---------------------------------------------------------------------------
# relief_loop / relief_start / relief_stop (mirrors the thermal guard)
# ---------------------------------------------------------------------------
relief_loop() {
  init_dirs
  log "relief: watcher started (pid $$)"
  while :; do
    relief_tick
    _rr="$(config_get ENABLE_RAM_RELIEF)"; _rr="${_rr:-1}"
    _nl="$(config_get NIGHT_LEAN)";        _nl="${_nl:-1}"
    if [ "$_rr" = "0" ] && [ "$_nl" = "0" ]; then
      log "relief: both features disabled via config, watcher exiting"
      rm -f "$THERMALCORE_RELIEF_PID"
      return 0
    fi
    _int="$(config_get RAM_RELIEF_INTERVAL)"; is_uint "$_int" || _int=30
    [ "$_int" -lt 15 ] && _int=15
    sleep "$_int"
  done
}

relief_start() {
  init_dirs
  if [ -f "$THERMALCORE_RELIEF_PID" ]; then
    _old="$(cat "$THERMALCORE_RELIEF_PID" 2>/dev/null)"
    if is_uint "$_old" && kill -0 "$_old" 2>/dev/null; then
      printf 'relief already running (pid %s)\n' "$_old"; return 1
    fi
  fi
  relief_loop >/dev/null 2>&1 &
  _pid=$!
  printf '%s\n' "$_pid" > "$THERMALCORE_RELIEF_PID"
  chmod 0644 "$THERMALCORE_RELIEF_PID"
  printf 'relief started (pid %s)\n' "$_pid"
  return 0
}

relief_stop() {
  if [ -f "$THERMALCORE_RELIEF_PID" ]; then
    _pid="$(cat "$THERMALCORE_RELIEF_PID" 2>/dev/null)"
    if is_uint "$_pid" && kill -0 "$_pid" 2>/dev/null; then
      kill "$_pid" 2>/dev/null
      _i=0
      while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt 20 ]; do sleep 0.2; _i=$((_i + 1)); done
      kill -9 "$_pid" 2>/dev/null
      printf 'relief stopped (pid %s)\n' "$_pid"
    else
      printf 'relief not running (stale pidfile)\n'
    fi
    rm -f "$THERMALCORE_RELIEF_PID"
  else
    printf 'relief not running\n'
  fi
  return 0
}
