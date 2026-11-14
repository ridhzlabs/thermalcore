#
# ThermalCore - status collection (JSON for WebUI) + thermal guard
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

# shellcheck shell=sh

# ---------------------------------------------------------------------------
# cpu_usage_pct - instantaneous CPU usage from /proc/stat deltas (-1 if unknown)
# ---------------------------------------------------------------------------
cpu_usage_pct() {
  _stat_line=""
  [ -f "$THERMALCORE_SYSROOT/proc/stat" ] && IFS= read -r _stat_line < "$THERMALCORE_SYSROOT/proc/stat"
  case "$_stat_line" in
    "cpu "*) ;;
    *) print -r -- '-1'; return 1 ;;
  esac
  _total=0; _idle=0; _i=0
  for _v in $_stat_line; do
    case "$_v" in (cpu) continue ;; esac
    is_uint "$_v" || continue
    _total=$(( _total + _v ))
    if [ "$_i" = "3" ] || [ "$_i" = "4" ]; then
      _idle=$(( _idle + _v ))
    fi
    _i=$(( _i + 1 ))
  done
  _now=0
  [ -f "$THERMALCORE_SYSROOT/proc/uptime" ] && IFS= read -r _now < "$THERMALCORE_SYSROOT/proc/uptime"
  _now="${_now%%.*}"
  is_uint "$_now" || _now=0
  _prev_ts=""; _prev_total=""; _prev_idle=""
  if [ -f "$THERMALCORE_CPU_STAT_CACHE" ]; then
    { IFS= read -r _prev_ts; IFS= read -r _prev_total; IFS= read -r _prev_idle; } < "$THERMALCORE_CPU_STAT_CACHE" 2>/dev/null
  fi
  { print -r -- "$_now"; print -r -- "$_total"; print -r -- "$_idle"; } > "$THERMALCORE_CPU_STAT_CACHE" 2>/dev/null
  if is_uint "$_prev_ts" && is_uint "$_prev_total" && is_uint "$_prev_idle"; then
    _age=$(( _now - _prev_ts ))
    if [ "$_age" -ge 0 ] && [ "$_age" -le 60 ]; then
      _dt=$(( _total - _prev_total )); _di=$(( _idle - _prev_idle ))
      if [ "$_dt" -gt 0 ] && [ "$_dt" -lt 100000000 ]; then
        _pct10=$(( (_dt - _di) * 1000 / _dt ))
        print -r -- "$(( _pct10 / 10 )).$(( _pct10 % 10 ))"
        return 0
      fi
    fi
  fi
  print -r -- '-1'
}

# ---------------------------------------------------------------------------
# temp_plausible RAW_CENTI - 0 when within a sane sensor range
# ---------------------------------------------------------------------------
temp_plausible() {
  _tp_t="$(temp_tenths "$1")" || return 1
  [ "$_tp_t" -gt -500 ] && [ "$_tp_t" -lt 1100 ]
}

# ---------------------------------------------------------------------------
# _zones_json - emit JSON array of plausible thermal zones
# ---------------------------------------------------------------------------
_zones_json() {
  _z_first=1
  _z_max_t=-9999; _z_max_type=""
  print -nr -- '['
  for _z in "$THERMALCORE_SYSROOT/sys/class/thermal"/thermal_zone*; do
    [ -d "$_z" ] || continue
    _z_idx="${_z##*thermal_zone}"
    case "$_z_idx" in (*[!0-9]*) continue ;; esac
    _z_raw=""
    IFS= read -r _z_raw < "$_z/temp" 2>/dev/null
    is_int "$_z_raw" || continue
    case "$_z_raw" in
      -*) _z_abs="${_z_raw#-}"; _z_neg=1 ;;
      *)  _z_abs="$_z_raw"; _z_neg=0 ;;
    esac
    if [ "$_z_abs" -ge 1000 ]; then
      _z_t=$(( (_z_abs + 50) / 100 ))
    elif [ "$_z_abs" -ge 100 ]; then
      _z_t="$_z_abs"
    else
      _z_t=$(( _z_abs * 10 ))
    fi
    [ "$_z_neg" = 1 ] && _z_t=$(( -_z_t ))
    { [ "$_z_t" -gt -500 ] && [ "$_z_t" -lt 1100 ]; } || continue
    _z_type=""
    IFS= read -r _z_type < "$_z/type" 2>/dev/null
    [ -n "$_z_type" ] || _z_type="zone${_z_idx}"
    if [ "$_z_t" -lt 0 ]; then
      _z_a=$(( -_z_t )); _z_sign="-"
    else
      _z_a="$_z_t"; _z_sign=""
    fi
    _z_ctext="${_z_sign}$(( _z_a / 10 )).$(( _z_a % 10 ))"
    [ "$_z_first" = 1 ] && _z_first=0 || print -nr -- ','
    case "$_z_type" in
      *\\*|*\"*|*"$THERMALCORE_TAB"*)
        _z_type="$(print -nr -- "$_z_type" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    esac
    _z_json="{\"zone\":${_z_idx},\"type\":\"${_z_type}\",\"temp_c\":${_z_ctext}}"
    print -nr -- "$_z_json"
    [ "$_z_t" -gt "$_z_max_t" ] && { _z_max_t="$_z_t"; _z_max_type="$_z_type"; }
  done
  print -nr -- ']'
  if [ "$_z_max_t" = "-9999" ]; then
    print -r -- "-999	n/a" > "$THERMALCORE_DATA/.zones_max.$$" 2>/dev/null
  else
    if [ "$_z_max_t" -lt 0 ]; then
      _z_ma=$(( -_z_max_t )); _z_ms="-"
    else
      _z_ma="$_z_max_t"; _z_ms=""
    fi
    print -r -- "${_z_ms}$(( _z_ma / 10 )).$(( _z_ma % 10 ))	$_z_max_type" > "$THERMALCORE_DATA/.zones_max.$$" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# _clusters_json - CPU cluster array
# ---------------------------------------------------------------------------
_clusters_json() {
  _first=1
  print -nr -- '['
  for _p in "$THERMALCORE_SYSROOT/sys/devices/system/cpu/cpufreq"/policy*; do
    [ -d "$_p" ] || continue
    _base="${_p##*/}"; _pol="${_base#policy}"
    case "$_pol" in (*[!0-9]*) continue ;; esac
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_governor"; _gov="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_cur_freq"; _cur="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq"; _smin="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq"; _smax="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_max_freq"; _cpuinfo_max="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/related_cpus"; _related="$_RV"
    freq_pct_val "${_cur:-0}" "${_cpuinfo_max:-0}"; _freqpct="$_FPCT"
    _jpol="$_pol"; _jrel="${_related:-}"; _jgov="${_gov:-unknown}"
    case "$_jpol$_jrel$_jgov" in
      *\\*|*\"*|*"$THERMALCORE_TAB"*)
        _jpol="$(json_escape "$_jpol")"; _jrel="$(json_escape "$_jrel")"; _jgov="$(json_escape "$_jgov")" ;;
    esac
    [ "$_first" = 1 ] && _first=0 || print -nr -- ','
    _c_json="{\"policy\":\"$_jpol\",\"related\":\"$_jrel\",\"governor\":\"$_jgov\",\"cur_khz\":${_cur:-0},\"min_khz\":${_smin:-0},\"max_khz\":${_smax:-0},\"cap_khz\":${_cpuinfo_max:-0},\"freq_pct\":${_freqpct:-0}}"
    print -nr -- "$_c_json"
  done
  print -nr -- ']'
}

# ---------------------------------------------------------------------------
# _storage_json - storage array
# ---------------------------------------------------------------------------
_storage_json() {
  _first=1
  print -nr -- '['
  for _s in $(storage_devs); do
    read_val "/sys/block/$_s/queue/scheduler"; _raw="$_RV"
    case "$_raw" in
      *"["*"]"*) _sel="${_raw##*\[}"; _sel="${_sel%%\]*}" ;;
      *" "*) _sel="${_raw%% *}" ;;
      *) _sel="$_raw" ;;
    esac
    read_val "/sys/block/$_s/queue/read_ahead_kb"; _ra="$_RV"
    [ "$_first" = 1 ] && _first=0 || print -nr -- ','
    _s_json="{\"dev\":\"$_s\",\"scheduler\":\"${_sel:-?}\",\"read_ahead_kb\":${_ra:-0}}"
    print -nr -- "$_s_json"
  done
  print -nr -- ']'
}

# ---------------------------------------------------------------------------
# _vm_json
# ---------------------------------------------------------------------------
_vm_json() {
  read_val /proc/sys/vm/swappiness; _swp="$_RV"
  read_val /proc/sys/vm/vfs_cache_pressure; _vcp="$_RV"
  read_val /proc/sys/vm/dirty_ratio; _dr="$_RV"
  read_val /proc/sys/vm/dirty_background_ratio; _dbr="$_RV"
  read_val /proc/sys/vm/compaction_proactiveness; _cp="$_RV"
  print -nr -- "{\"swappiness\":${_swp:-0},\"vfs_cache_pressure\":${_vcp:-0},\"dirty_ratio\":${_dr:-0},\"dirty_background_ratio\":${_dbr:-0},\"compaction_proactiveness\":${_cp:-0}}"
}

# ---------------------------------------------------------------------------
# _gpu_json
# ---------------------------------------------------------------------------
_gpu_json() {
  _gp="$(_gpu_paths 2>/dev/null)" || { print -nr -- '{"name":"","governor":"","cur_hz":0,"min_hz":0,"max_hz":0,"freq_pct":0}'; return 0; }
  _kind="${_gp%%	*}"; _dir="${_gp#*	}"
  if [ "$_kind" = "devfreq" ]; then
    read_val "${_dir}/name"; _name="$_RV"; [ -z "$_name" ] && _name="${_dir##*/}"
    read_val "${_dir}/governor"; _gov="$_RV"
    read_val "${_dir}/cur_freq"; _cur="$_RV"
    [ -z "$_cur" ] && { read_val "${_dir}/target_freq"; _cur="$_RV"; }
    read_val "${_dir}/min_freq"; _min="$_RV"
    read_val "${_dir}/max_freq"; _max="$_RV"
    _absmax=""
    read_val "${_dir}/available_frequencies"; _avail="$_RV"
    for _f in $_avail; do
      is_uint "$_f" || continue
      if [ -z "$_absmax" ] || num_gt "$_f" "$_absmax"; then _absmax="$_f"; fi
    done
    [ -z "$_absmax" ] && _absmax="$_max"
    freq_pct_val "${_cur:-0}" "${_absmax:-0}"; _pct="$_FPCT"
    _g_json="{\"name\":\"${_name}\",\"governor\":\"${_gov:-unknown}\",\"cur_hz\":${_cur:-0},\"min_hz\":${_min:-0},\"max_hz\":${_max:-0},\"freq_pct\":${_pct:-0}}"
    print -nr -- "$_g_json"
  else
    read_val "${_dir}/gpuclk"; _cur="$_RV"
    read_val "${_dir}/min_gpuclk"; _min="$_RV"
    read_val "${_dir}/max_gpuclk"; _max="$_RV"
    _g_json="{\"name\":\"${_dir##*/}\",\"governor\":\"\",\"cur_hz\":${_cur:-0},\"min_hz\":${_min:-0},\"max_hz\":${_max:-0},\"freq_pct\":0}"
    print -nr -- "$_g_json"
  fi
}

# ---------------------------------------------------------------------------
# guard_state_file - path helper
# ---------------------------------------------------------------------------
guard_write_state() {
  init_dirs
  cat > "$THERMALCORE_GUARD_STATE.tmp" <<EOF
triggered=$1
last_check=$(now_ts)
battery_c=$2
reason=$3
EOF
  mv "$THERMALCORE_GUARD_STATE.tmp" "$THERMALCORE_GUARD_STATE"
  chmod 0644 "$THERMALCORE_GUARD_STATE"
}

guard_triggered() {
  [ "$(config_get triggered "$THERMALCORE_GUARD_STATE" 2>/dev/null)" = "1" ]
}

battery_temp_c() {
  read_val /sys/class/power_supply/battery/temp; _raw="$_RV"
  if [ -n "$_raw" ] && is_int "$_raw"; then
    normalize_temp "$_raw"; return 0
  fi
  # fallback: battery-like thermal zone
  for _z in "$THERMALCORE_SYSROOT/sys/class/thermal"/thermal_zone*; do
    [ -d "$_z" ] || continue
    read_val "${_z#${THERMALCORE_SYSROOT}}/type"; _t="$_RV"
    case "$_t" in
      *battery*|*Battery*|*BATTERY*)
        read_val "${_z#${THERMALCORE_SYSROOT}}/temp"; _raw="$_RV"
        if is_int "$_raw" && temp_plausible "$_raw"; then
          normalize_temp "$_raw"; return 0
        fi ;;
    esac
  done
  print -r -- '0.0'
  return 1
}

# ---------------------------------------------------------------------------
# guard_mitigate - emergency cap when overheating (cpufreq only, reversible)
# ---------------------------------------------------------------------------
guard_mitigate() {
  _reason="$1"
  log "guard: MITIGATE ($_reason) — capping CPU to 70%, GPU to 60%"
  for _p in "$(spath /sys/devices/system/cpu/cpufreq)"/policy*; do
    [ -d "$_p" ] || continue
    _base="${_p##*/}"
    _cmin="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_min_freq")"
    _cmax="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_max_freq")"
    is_uint "$_cmax" || continue
    _target="$(pct_value "$_cmax" 70)"
    _snap="$(pick_freq "/sys/devices/system/cpu/cpufreq/$_base/scaling_available_frequencies" "$_target")"
    is_uint "$_snap" || _snap="$_target"
    _cur_min="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq")"
    is_uint "$_cur_min" && [ "$_snap" -lt "$_cur_min" ] && write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq" "${_cmin:-0}"
    write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq" "$_snap"
  done
  _gp="$(_gpu_paths 2>/dev/null)" && {
    _kind="${_gp%%	*}"; _dir="${_gp#*	}"
    if [ "$_kind" = "devfreq" ]; then
      _absmax="$(cat "$(spath "${_dir}/available_frequencies")" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
      [ -n "$_absmax" ] && {
        _target="$(pct_value "$_absmax" 60)"
        _snap="$(pick_freq "${_dir}/available_frequencies" "$_target")"
        is_uint "$_snap" || _snap="$_target"
        write_file "${_dir}/max_freq" "$_snap"
      }
    fi
  }
}

# ---------------------------------------------------------------------------
# guard_loop - persistent watchdog (started by service.sh when enabled)
# ---------------------------------------------------------------------------
guard_loop() {
  init_dirs
  log "guard: started (pid $$)"
  while :; do
    _en="$(config_get ENABLE_THERMAL_GUARD)"
    [ "$_en" = "0" ] && { log "guard: disabled via config, exiting"; rm -f "$THERMALCORE_GUARD_PID"; return 0; }
    _int="$(config_get THERMAL_GUARD_INTERVAL)"; is_uint "$_int" || _int=30
    [ "$_int" -lt 10 ] && _int=10
    _max_c="$(config_get THERMAL_GUARD_BATTERY_MAX_C)"; is_uint "$_max_c" || _max_c=45
    _rec_c="$(config_get THERMAL_GUARD_RECOVER_C)"; is_uint "$_rec_c" || _rec_c=42
    _bat="$(battery_temp_c)"
    _triggered="$(config_get triggered "$THERMALCORE_GUARD_STATE" 2>/dev/null)"

    if awk -v b="$_bat" -v m="$_max_c" 'BEGIN{ exit !(b >= m) }'; then
      if [ "$_triggered" != "1" ]; then
        guard_mitigate "battery ${_bat}C >= ${_max_c}C"
        guard_write_state 1 "$_bat" "battery>=${_max_c}C"
      fi
    elif awk -v b="$_bat" -v r="$_rec_c" 'BEGIN{ exit !(b <= r) }'; then
      if [ "$_triggered" = "1" ]; then
        log "guard: recovered (battery ${_bat}C <= ${_rec_c}C), re-applying '$(current_profile)'"
        _note=""
        apply_profile "$(current_profile)" >/dev/null 2>&1
        guard_write_state 0 "$_bat" "recovered"
      else
        guard_write_state 0 "$_bat" "ok"
      fi
    else
      guard_write_state "${_triggered:-0}" "$_bat" "holding"
    fi
    sleep "$_int"
  done
}

guard_start() {
  init_dirs
  if [ -f "$THERMALCORE_GUARD_PID" ]; then
    _old="$(cat "$THERMALCORE_GUARD_PID" 2>/dev/null)"
    if is_uint "$_old" && kill -0 "$_old" 2>/dev/null; then
      printf 'guard already running (pid %s)\n' "$_old"; return 1
    fi
  fi
  guard_loop >/dev/null 2>&1 &
  _pid=$!
  printf '%s\n' "$_pid" > "$THERMALCORE_GUARD_PID"
  chmod 0644 "$THERMALCORE_GUARD_PID"
  printf 'guard started (pid %s)\n' "$_pid"
  return 0
}

guard_stop() {
  if [ -f "$THERMALCORE_GUARD_PID" ]; then
    _pid="$(cat "$THERMALCORE_GUARD_PID" 2>/dev/null)"
    if is_uint "$_pid" && kill -0 "$_pid" 2>/dev/null; then
      kill "$_pid" 2>/dev/null
      _i=0
      while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt 20 ]; do sleep 0.2; _i=$((_i + 1)); done
      kill -9 "$_pid" 2>/dev/null
      printf 'guard stopped (pid %s)\n' "$_pid"
    else
      printf 'guard not running (stale pidfile)\n'
    fi
    rm -f "$THERMALCORE_GUARD_PID"
  else
    printf 'guard not running\n'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# status_json - full status document
# ---------------------------------------------------------------------------
status_json() {
  init_default_config
  _modver=""
  if [ -f "$THERMALCORE_MODDIR/module.prop" ]; then
    while IFS='=' read -r _mk _mv; do
      [ "$_mk" = "version" ] && { _modver="$_mv"; break; }
    done < "$THERMALCORE_MODDIR/module.prop"
  fi
  _dp="$(pidof thermal-cored 2>/dev/null)"; _dp="${_dp%% *}"
  [ -z "$_dp" ] && _dp="$(ps -A 2>/dev/null | grep -v grep | grep thermal-cored | awk 'NR==1{print $2}')"
  [ -n "$_dp" ] && _dalive=true || _dalive=false
  _learning="$(prop_get persist.sys.rianixia.learning_enabled unknown)"
  _debug="$(prop_get persist.sys.rianixia.thermalcore-debug unknown)"
  _uptime_s=0; _up_raw=""
  [ -f "$THERMALCORE_SYSROOT/proc/uptime" ] && IFS= read -r _up_raw < "$THERMALCORE_SYSROOT/proc/uptime"
  case "$_up_raw" in
    *.*) _uptime_s="${_up_raw%%.*}" ;;
    *)   _uptime_s="$_up_raw" ;;
  esac
  is_uint "$_uptime_s" || _uptime_s=0
  _cf_guard=""; _cf_gint=""; _cf_gmax=""; _cf_tcpu=""; _cf_tgpu=""; _cf_tio=""; _cf_tvm=""
  if [ -f "$THERMALCORE_STATE_FILE" ]; then
    while IFS= read -r _cl; do
      case "$_cl" in
        ENABLE_THERMAL_GUARD=*)        _cf_guard="${_cl#*=}" ;;
        THERMAL_GUARD_INTERVAL=*)      _cf_gint="${_cl#*=}" ;;
        THERMAL_GUARD_BATTERY_MAX_C=*) _cf_gmax="${_cl#*=}" ;;
        ENABLE_CPU_TWEAKS=*)           _cf_tcpu="${_cl#*=}" ;;
        ENABLE_GPU_TWEAKS=*)           _cf_tgpu="${_cl#*=}" ;;
        ENABLE_IO_TWEAKS=*)            _cf_tio="${_cl#*=}" ;;
        ENABLE_VM_TWEAKS=*)            _cf_tvm="${_cl#*=}" ;;
      esac
    done < "$THERMALCORE_STATE_FILE"
  fi
  [ "$_cf_guard" = "0" ] && _guard_bool=false || _guard_bool=true
  _guard_trig=""; _guard_last=""
  if [ -f "$THERMALCORE_GUARD_STATE" ]; then
    while IFS= read -r _gl; do
      case "$_gl" in
        triggered=*)  _guard_trig="${_gl#*=}" ;;
        last_check=*) _guard_last="${_gl#*=}" ;;
      esac
    done < "$THERMALCORE_GUARD_STATE"
  fi
  [ "$_guard_trig" = "1" ] && _guard_tbool=true || _guard_tbool=false
  is_uint "$_guard_last" || _guard_last=0
  _guard_int="$_cf_gint"; is_uint "$_guard_int" || _guard_int=30
  _guard_max="$_cf_gmax"; is_uint "$_guard_max" || _guard_max=45
  _last_backup="$(backup_latest)"
  [ "$_cf_tcpu" = "0" ] && _t_cpu_b=false || _t_cpu_b=true
  [ "$_cf_tgpu" = "0" ] && _t_gpu_b=false || _t_gpu_b=true
  [ "$_cf_tio" = "0" ] && _t_io_b=false || _t_io_b=true
  [ "$_cf_tvm" = "0" ] && _t_vm_b=false || _t_vm_b=true

  _zones="$(_zones_json)"
  read -r ZONES_MAX_C ZONES_MAX_TYPE < "$THERMALCORE_DATA/.zones_max.$$" 2>/dev/null
  rm -f "$THERMALCORE_DATA/.zones_max.$$"
  case "$ZONES_MAX_C" in ''|*[!0-9.-]*) ZONES_MAX_C=0; ZONES_MAX_TYPE=n/a ;; esac
  [ "$ZONES_MAX_C" = "-999" ] && { ZONES_MAX_C=0; ZONES_MAX_TYPE=n/a; }
  _clusters="$(_clusters_json)"
  _storage="$(_storage_json)"
  _gpu="$(_gpu_json)"
  _vm="$(_vm_json)"
  _mem_total=0; _mem_avail=0
  if [ -f "$THERMALCORE_SYSROOT/proc/meminfo" ]; then
    while read -r _mk _mv _mu; do
      case "$_mk" in
        MemTotal:) _mem_total="$_mv" ;;
        MemAvailable:) _mem_avail="$_mv" ;;
      esac
    done < "$THERMALCORE_SYSROOT/proc/meminfo"
  fi
  is_uint "$_mem_total" || _mem_total=0
  is_uint "$_mem_avail" || _mem_avail=0
  _btemp="$(battery_temp_c)"
  read_val /sys/class/power_supply/battery/status; _bstatus="$_RV"
  read_val /sys/class/power_supply/battery/capacity; _bcap="$_RV"; is_uint "$_bcap" || _bcap=0
  read_val /sys/class/power_supply/battery/current_now; _bcur="$_RV"; is_int "$_bcur" || _bcur=0
  read_val /sys/class/power_supply/battery/voltage_now; _bvolt="$_RV"; is_int "$_bvolt" || _bvolt=0
  read_val /sys/class/power_supply/battery/health; _bhealth="$_RV"
  _cpu_usage="$(cpu_usage_pct)"

  [ -f "$THERMALCORE_DETECT_CACHE" ] || detect_refresh >/dev/null 2>&1
  _chipset="unknown"; _platform="unknown"; _device="unknown"; _model="unknown"
  _android="unknown"; _kernel="unknown"; _rootmgr="Unknown"; _sdk=0
  if [ -f "$THERMALCORE_DETECT_CACHE" ]; then
    while IFS='=' read -r _dk _dv; do
      case "$_dk" in
        chipset) _chipset="$_dv" ;;
        platform) _platform="$_dv" ;;
        device) _device="$_dv" ;;
        product_model) _model="$_dv" ;;
        android_release) _android="$_dv" ;;
        kernel) _kernel="$_dv" ;;
        root_manager) _rootmgr="$_dv" ;;
        sdk_int) _sdk="$_dv" ;;
      esac
    done < "$THERMALCORE_DETECT_CACHE"
  fi
  is_uint "$_sdk" || _sdk=0

  json_escape_val "${_modver:-2.3.0}"; _jv_modver="$_JE"
  json_escape_val "$_learning"; _jv_learning="$_JE"
  json_escape_val "$_debug"; _jv_debug="$_JE"
  json_escape_val "${_last_backup:-none}"; _jv_backup="$_JE"
  json_escape_val "${_model:-unknown}"; _jv_model="$_JE"
  json_escape_val "${_device:-unknown}"; _jv_device="$_JE"
  json_escape_val "${_chipset:-unknown}"; _jv_chipset="$_JE"
  json_escape_val "${_platform:-unknown}"; _jv_platform="$_JE"
  json_escape_val "${_android:-unknown}"; _jv_android="$_JE"
  json_escape_val "${_kernel:-unknown}"; _jv_kernel="$_JE"
  json_escape_val "${_rootmgr:-Unknown}"; _jv_rootmgr="$_JE"
  json_escape_val "${_bstatus:-unknown}"; _jv_bstatus="$_JE"
  json_escape_val "${_bhealth:-unknown}"; _jv_bhealth="$_JE"
  json_escape_val "${ZONES_MAX_TYPE:-n/a}"; _jv_max_type="$_JE"

  cat <<EOF
{
  "module": {
    "id": "thermal-core",
    "version": "${_jv_modver}",
    "profile": "$(current_profile)",
    "uptime_s": ${_uptime_s},
    "daemon": { "pid": ${_dp:-0}, "alive": ${_dalive},
      "learning": "${_jv_learning}", "debug": "${_jv_debug}" },
    "guard": { "enabled": ${_guard_bool}, "triggered": ${_guard_tbool},
      "battery_max_c": ${_guard_max}, "interval_s": ${_guard_int}, "last_check": ${_guard_last} },
    "toggles": { "cpu": ${_t_cpu_b}, "gpu": ${_t_gpu_b}, "io": ${_t_io_b}, "vm": ${_t_vm_b} },
    "latest_backup": "${_jv_backup}"
  },
  "device": {
    "model": "${_jv_model}",
    "device": "${_jv_device}",
    "chipset": "${_jv_chipset}",
    "platform": "${_jv_platform}",
    "android": "${_jv_android}",
    "sdk": ${_sdk:-0},
    "kernel": "${_jv_kernel}",
    "root_manager": "${_jv_rootmgr}",
    "mem_total_mb": $(( ${_mem_total:-0} / 1024 )),
    "mem_avail_mb": $(( ${_mem_avail:-0} / 1024 ))
  },
  "battery": {
    "temp_c": ${_btemp},
    "status": "${_jv_bstatus}",
    "capacity": ${_bcap:-0},
    "current_ua": ${_bcur},
    "voltage_uv": ${_bvolt},
    "health": "${_jv_bhealth}"
  },
  "cpu": {
    "usage_pct": ${_cpu_usage},
    "clusters": ${_clusters}
  },
  "gpu": ${_gpu},
  "thermals": ${_zones},
  "thermal_max_c": ${ZONES_MAX_C},
  "thermal_max_type": "${_jv_max_type}",
  "storage": ${_storage},
  "vm": ${_vm},
  "timestamp": $(now_ts)
}
EOF
}

# ---------------------------------------------------------------------------
# module_prop_set_status - rewrite description line with run state
# ---------------------------------------------------------------------------
module_prop_set_status() {
  [ -n "$THERMALCORE_NO_DESC_SYNC" ] && return 1
  _mp="$THERMALCORE_MODDIR/module.prop"
  [ -f "$_mp" ] || return 1
  # only a real install keeps the pristine module.prop.orig copy from customize.sh
  [ -f "$THERMALCORE_MODDIR/module.prop.orig" ] || return 1
  _mp_orig_desc="Universal thermal & power core by ridhzxlabs — AI engine, adaptive profiles, live WebUI, thermal guard, auto-rollback."
  _mp_prof="$(config_get CURRENT_PROFILE 2>/dev/null)"
  case "$_mp_prof" in
    battery_saver) _mp_state='🔋 Battery Saver · CPU ≤75% · GPU ≤60%' ;;
    performance)   _mp_state='🚀 Performance · full clocks · low latency' ;;
    gaming)        _mp_state='🎮 Gaming · GPU floor · sustained caps' ;;
    custom)        _mp_state='🛠️ Custom · tuned from the WebUI' ;;
    *)             _mp_state='✅ Balanced · CPU ≤95% · GPU ≤90%' ;;
  esac
  _mp_pid="$(pidof thermal-cored 2>/dev/null | awk '{print $1}')"
  if [ -n "$_mp_pid" ]; then
    _mp_state="$_mp_state · running"
  else
    _mp_state="$_mp_state · daemon off"
  fi
  # escape sed replacement delimiters & ampersands
  _mp_desc="[$_mp_state] $_mp_orig_desc"
  _mp_desc="$(printf '%s' "$_mp_desc" | sed -e 's/[&\\/]/\\&/g')"
  sed -i "s/^description=.*/description=${_mp_desc}/" "$_mp" 2>/dev/null
}
