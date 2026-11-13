#
# ThermalCore - profile engine: load / validate / apply / rollback
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

# shellcheck shell=sh

APPLY_FAIL=0   # critical failures (rollback trigger)
APPLY_WARN=0   # non-critical failures (logged, no rollback)
APPLY_NOTE=""  # human readable notes for CLI/WebUI

_note() { APPLY_NOTE="${APPLY_NOTE}$1
"; }

# ---------------------------------------------------------------------------
# init_default_config - create config.conf / custom.conf with sane defaults
# ---------------------------------------------------------------------------
init_default_config() {
  init_dirs
  if [ ! -f "$THERMALCORE_STATE_FILE" ]; then
    cat > "$THERMALCORE_STATE_FILE" <<'EOF'
CURRENT_PROFILE=balanced
ENABLE_CPU_TWEAKS=1
ENABLE_GPU_TWEAKS=1
ENABLE_IO_TWEAKS=1
ENABLE_VM_TWEAKS=1
ENABLE_THERMAL_GUARD=1
THERMAL_GUARD_INTERVAL=30
THERMAL_GUARD_BATTERY_MAX_C=45
THERMAL_GUARD_RECOVER_C=42
BACKUP_ON_APPLY=1
EOF
    chmod 0644 "$THERMALCORE_STATE_FILE"
    log "init_default_config: created config.conf"
  fi
  if [ ! -f "$THERMALCORE_CUSTOM_CONF" ]; then
    reset_custom_conf "quiet"
  fi
}

reset_custom_conf() {
  init_dirs
  cat > "$THERMALCORE_CUSTOM_CONF" <<'EOF'
# ThermalCore - Custom profile (edited via WebUI or manually)
# -1 (or keep) = leave the current kernel value untouched
CPU_GOVERNOR=schedutil
CPU_MAX_FREQ_PCT=100
CPU_MIN_FREQ_PCT=-1
GPU_GOVERNOR=simple_ondemand
GPU_MAX_FREQ_PCT=100
GPU_MIN_FREQ_PCT=-1
IO_SCHEDULER=auto
IO_READ_AHEAD_KB=256
VM_SWAPPINESS=-1
VM_VFS_CACHE_PRESSURE=-1
VM_DIRTY_RATIO=-1
VM_DIRTY_BACKGROUND_RATIO=-1
VM_COMPACTION_PROACTIVENESS=-1
VM_WATERMARK_BOOST_FACTOR=-1
SUGOV_UP_RATE_LIMIT_US=-1
SUGOV_DOWN_RATE_LIMIT_US=-1
EOF
  chmod 0644 "$THERMALCORE_CUSTOM_CONF"
  [ "$1" = "quiet" ] || log "reset_custom_conf: custom.conf reset to defaults"
}

# ---------------------------------------------------------------------------
# profile_file NAME - resolve conf path for a profile name
# ---------------------------------------------------------------------------
profile_file() {
  case "$1" in
    battery_saver|balanced|performance|gaming)
      print -r -- "$THERMALCORE_MODDIR/profiles/$1.conf" ;;
    custom)
      print -r -- "$THERMALCORE_CUSTOM_CONF" ;;
    *)
      return 1 ;;
  esac
}

profile_exists() {
  [ -f "$(profile_file "$1")" ]
}

# ---------------------------------------------------------------------------
# load_profile FILE - parse KEY=VALUE into P_* globals (values never evaluated)
# ---------------------------------------------------------------------------
load_profile() {
  P_CPU_GOVERNOR=keep; P_CPU_MAX_FREQ_PCT=-1; P_CPU_MIN_FREQ_PCT=-1
  P_GPU_GOVERNOR=keep; P_GPU_MAX_FREQ_PCT=-1; P_GPU_MIN_FREQ_PCT=-1
  P_IO_SCHEDULER=auto; P_IO_READ_AHEAD_KB=-1
  P_VM_SWAPPINESS=-1; P_VM_VFS_CACHE_PRESSURE=-1
  P_VM_DIRTY_RATIO=-1; P_VM_DIRTY_BACKGROUND_RATIO=-1; P_VM_COMPACTION_PROACTIVENESS=-1
  P_VM_WATERMARK_BOOST_FACTOR=-1
  P_SUGOV_UP_RATE_LIMIT_US=-1; P_SUGOV_DOWN_RATE_LIMIT_US=-1

  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    # strip CR and leading/trailing spaces (builtin only)
    str_trim "$_k"; _k="$_ST"
    str_trim "$_v"; _v="$_ST"
    case "$_k" in
      ''|'#'*) continue ;;
      CPU_GOVERNOR) P_CPU_GOVERNOR="$_v" ;;
      CPU_MAX_FREQ_PCT) P_CPU_MAX_FREQ_PCT="$_v" ;;
      CPU_MIN_FREQ_PCT) P_CPU_MIN_FREQ_PCT="$_v" ;;
      GPU_GOVERNOR) P_GPU_GOVERNOR="$_v" ;;
      GPU_MAX_FREQ_PCT) P_GPU_MAX_FREQ_PCT="$_v" ;;
      GPU_MIN_FREQ_PCT) P_GPU_MIN_FREQ_PCT="$_v" ;;
      IO_SCHEDULER) P_IO_SCHEDULER="$_v" ;;
      IO_READ_AHEAD_KB) P_IO_READ_AHEAD_KB="$_v" ;;
      VM_SWAPPINESS) P_VM_SWAPPINESS="$_v" ;;
      VM_VFS_CACHE_PRESSURE) P_VM_VFS_CACHE_PRESSURE="$_v" ;;
      VM_DIRTY_RATIO) P_VM_DIRTY_RATIO="$_v" ;;
      VM_DIRTY_BACKGROUND_RATIO) P_VM_DIRTY_BACKGROUND_RATIO="$_v" ;;
      VM_COMPACTION_PROACTIVENESS) P_VM_COMPACTION_PROACTIVENESS="$_v" ;;
      VM_WATERMARK_BOOST_FACTOR) P_VM_WATERMARK_BOOST_FACTOR="$_v" ;;
      SUGOV_UP_RATE_LIMIT_US) P_SUGOV_UP_RATE_LIMIT_US="$_v" ;;
      SUGOV_DOWN_RATE_LIMIT_US) P_SUGOV_DOWN_RATE_LIMIT_US="$_v" ;;
      *) ;; # unknown keys ignored (forward compatible)
    esac
  done < "$1"
}

# is_keep V -> 0 when value means "leave untouched"
is_keep() {
  case "$1" in
    ''|-1|[Kk][Ee][Ee][Pp]|[Aa][Uu][Tt][Oo]|[Dd][Ee][Ff][Aa][Uu][Ll][Tt]) return 0 ;;
    *) return 1 ;;
  esac
}

# pct_or_keep V MIN MAX -> prints clamped int or "-1"
pct_or_keep() {
  _pv="$1"
  is_keep "$_pv" && { print -r -- '-1'; return 0; }
  clamp_int "$_pv" "$2" "$3"
}

# enable_flag KEY -> 0 if enabled (default 1)
enable_flag() {
  _efv="$(config_get "$1" 2>/dev/null)"
  [ "$_efv" = "0" ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# _governor_chain WANT -> space separated fallback chain for the want
# ---------------------------------------------------------------------------
_governor_chain() {
  case "$1" in
    schedutil)     print -r -- 'schedutil sugov_ext walt interactive ondemand conservative' ;;
    sugov_ext)     print -r -- 'sugov_ext schedutil walt interactive ondemand conservative' ;;
    powersave)     print -r -- 'powersave conservative schedutil sugov_ext ondemand' ;;
    performance)   print -r -- 'performance schedutil sugov_ext walt interactive' ;;
    simple_ondemand) print -r -- 'simple_ondemand msm-adreno-tz msm_adreno_tz userspace powersave performance' ;;
    simple_msm_adreno_tz|msm-adreno-tz) print -r -- 'msm-adreno-tz msm_adreno_tz simple_ondemand userspace powersave performance' ;;
    userspace)     print -r -- 'userspace simple_ondemand powersave performance' ;;
    *)             print -r -- "$1" ;;
  esac
}

# pick_gov_from_file WANT AVAIL_STRING -> prints usable governor or fails
_pick_gov() {
  _pg_want="$1"; _pg_avail="$2"
  _pg_set=0
  for _pg_cand in $(_governor_chain "$_pg_want"); do
    _pg_set=$((_pg_set + 1))
    case " $_pg_avail " in
      *" $_pg_cand "*) print -r -- "$_pg_cand"; return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# apply_cpu - CPU governors + frequency caps (critical)
# ---------------------------------------------------------------------------
apply_cpu() {
  if ! enable_flag ENABLE_CPU_TWEAKS; then
    _note "cpu: skipped (disabled)"
    return 0
  fi
  for _p in "$(spath /sys/devices/system/cpu/cpufreq)"/policy*; do
    [ -d "$_p" ] || continue
    _base="${_p##*/}"
    _gov_avail="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_available_governors")"
    _cur_min="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq")"
    _cur_max="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq")"
    _ci_min="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_min_freq")"
    _ci_max="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_max_freq")"
    _avail_file="/sys/devices/system/cpu/cpufreq/$_base/scaling_available_frequencies"

    # --- governor
    if ! is_keep "$P_CPU_GOVERNOR"; then
      _want_gov="$P_CPU_GOVERNOR"
      _skip_gov=0
      if [ "$_want_gov" = "smart" ]; then
        _cur_gov="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_governor")"
        case " $_cur_gov " in
          " sugov_ext "|" schedutil "|" walt "|" waltplus "|" schedplus "|" sched "|" interactive "|" ondemand "|" conservative ")
            _note "cpu[$_base]: kept vendor governor $_cur_gov"; _skip_gov=1 ;;
          *)
            _want_gov="schedutil" ;;
        esac
      fi
      if [ "$_skip_gov" = "0" ]; then
        if _new_gov="$(_pick_gov "$_want_gov" "$_gov_avail")"; then
          if write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_governor" "$_new_gov"; then
            _note "cpu[$_base]: governor -> $_new_gov"
          else
            APPLY_FAIL=$((APPLY_FAIL + 1)); _note "cpu[$_base]: FAIL governor write ($_new_gov)"
          fi
        else
          APPLY_WARN=$((APPLY_WARN + 1)); _note "cpu[$_base]: governor '$_want_gov' unavailable, kept current"
        fi
      fi
    fi

    # --- max frequency cap (percent of cpuinfo_max)
    _max_pct="$(pct_or_keep "$P_CPU_MAX_FREQ_PCT" 20 100)"
    if [ "$_max_pct" != "-1" ] && is_uint "$_ci_max"; then
      _target="$(pct_value "$_ci_max" "$_max_pct")"
      _snap="$(pick_freq "$_avail_file" "$_target")"
      is_uint "$_snap" || _snap="$_target"
      [ "$_snap" -lt "${_ci_min:-0}" ] && _snap="$_ci_min"
      # never lower max below current min: drop min first
      if is_uint "$_cur_min" && [ "$_snap" -lt "$_cur_min" ]; then
        write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq" "${_ci_min:-0}" \
          && _note "cpu[$_base]: min lowered to ${_ci_min:-0} kHz (ordering)"
      fi
      if write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq" "$_snap"; then
        _note "cpu[$_base]: max -> $_snap kHz (${_max_pct}%)"
      else
        APPLY_FAIL=$((APPLY_FAIL + 1)); _note "cpu[$_base]: FAIL max_freq write ($_snap)"
      fi
    fi

    # --- min frequency floor (0..100 percent of the min..max span)
    _min_pct="$(pct_or_keep "$P_CPU_MIN_FREQ_PCT" 0 100)"
    if [ "$_min_pct" != "-1" ] && is_uint "$_ci_max" && is_uint "$_ci_min"; then
      _span=$(( _ci_max - _ci_min ))
      _target=$(( _ci_min + $(pct_value "$_span" "$_min_pct") ))
      _snap="$(pick_freq "$_avail_file" "$_target")"
      is_uint "$_snap" || _snap="$_target"
      _hard_max="$(read_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq")"
      is_uint "$_hard_max" && [ "$_snap" -gt "$_hard_max" ] && _snap="$_hard_max"
      if write_file "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq" "$_snap"; then
        _note "cpu[$_base]: min -> $_snap kHz"
      else
        APPLY_WARN=$((APPLY_WARN + 1)); _note "cpu[$_base]: WARN min_freq write ($_snap)"
      fi
    fi

    # --- schedutil-family rate limits (optional, only when dir exists)
    _tdir=""
    for _t in sugov_ext schedutil; do
      [ -d "$_p/$_t" ] && { _tdir="$_t"; break; }
    done
    if [ -n "$_tdir" ]; then
      if ! is_keep "$P_SUGOV_UP_RATE_LIMIT_US"; then
        _cl="$(clamp_int "$P_SUGOV_UP_RATE_LIMIT_US" 10 10000)"
        if write_file "/sys/devices/system/cpu/cpufreq/$_base/$_tdir/up_rate_limit_us" "$_cl"; then
          _note "cpu[$_base]: $_tdir/up_rate_limit_us -> $_cl us"
        else
          APPLY_WARN=$((APPLY_WARN + 1))
        fi
      fi
      if ! is_keep "$P_SUGOV_DOWN_RATE_LIMIT_US"; then
        _cl="$(clamp_int "$P_SUGOV_DOWN_RATE_LIMIT_US" 10 10000)"
        if write_file "/sys/devices/system/cpu/cpufreq/$_base/$_tdir/down_rate_limit_us" "$_cl"; then
          _note "cpu[$_base]: $_tdir/down_rate_limit_us -> $_cl us"
        else
          APPLY_WARN=$((APPLY_WARN + 1))
        fi
      fi
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# _gpu_paths - prints NODECLASS<TAB>DIR for the detected GPU (cached detect)
# ---------------------------------------------------------------------------
_gpu_paths() {
  if [ -d "$THERMALCORE_SYSROOT/sys/class/kgsl/kgsl-3d0/devfreq" ]; then
    print -r -- "devfreq	/sys/class/kgsl/kgsl-3d0/devfreq"; return 0
  fi
  if [ -d "$THERMALCORE_SYSROOT/sys/class/kgsl/kgsl-3d0" ]; then
    print -r -- "kgsl_legacy	/sys/class/kgsl/kgsl-3d0"; return 0
  fi
  for _g in "$THERMALCORE_SYSROOT/sys/class/devfreq"/*; do
    [ -d "$_g" ] || continue
    _n="${_g##*/}"
    read_val "/sys/class/devfreq/$_n/name"; _rn="$_RV"
    case "$_n $_rn" in
      *[A-Z]*)
        _n="$(print -nr -- "$_n" | tr 'A-Z' 'a-z')"
        _rn="$(print -nr -- "$_rn" | tr 'A-Z' 'a-z')" ;;
    esac
    case "$_n $_rn" in
      *dvfsrc*|*memory*|*bandwidth*|*bw*|*bus*|*cache*|*cci*) continue ;;
      *mali*|*kgsl*|*gpu*|*g3d*|*adreno*|*xclipse*|*tensor*|*exynos*|*3d*)
        print -r -- "devfreq	/sys/class/devfreq/$_n"; return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# apply_gpu - GPU governor + frequency caps (critical)
# ---------------------------------------------------------------------------
apply_gpu() {
  if ! enable_flag ENABLE_GPU_TWEAKS; then
    _note "gpu: skipped (disabled)"
    return 0
  fi
  _gp="$(_gpu_paths)" || { _note "gpu: no GPU node found, skipped"; return 0; }
  _kind="${_gp%%	*}"; _dir="${_gp#*	}"

  if [ "$_kind" = "devfreq" ]; then
    _gov_avail="$(read_file "${_dir}/available_governors")"
    _gmax_abs="$(read_file "${_dir}/available_frequencies" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
    [ -z "$_gmax_abs" ] && _gmax_abs="$(read_file "${_dir}/max_freq")"
    _gmin_abs="$(read_file "${_dir}/available_frequencies" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -n 1)"
    [ -z "$_gmin_abs" ] && _gmin_abs="$(read_file "${_dir}/min_freq")"
    _avail_file="${_dir}/available_frequencies"

    # governor
    if ! is_keep "$P_GPU_GOVERNOR"; then
      _want_gov="$P_GPU_GOVERNOR"
      if [ "$_want_gov" = "smart" ]; then
        _cur_gov="$(read_file "${_dir}/governor")"
        case " $_cur_gov " in
          " simple_ondemand "|" devfreq_simple_ondemand "|" msm-adreno-tz "|" msm_adreno_tz "|" dummy "|" userspace ")
            _note "gpu: kept vendor governor $_cur_gov"; _want_gov="" ;;
          *)
            _want_gov="simple_ondemand" ;;
        esac
      fi
      if [ -n "$_want_gov" ] && _new_gov="$(_pick_gov "$_want_gov" "$_gov_avail")"; then
        if write_file "${_dir}/governor" "$_new_gov"; then
          _note "gpu: governor -> $_new_gov"
        else
          APPLY_FAIL=$((APPLY_FAIL + 1)); _note "gpu: FAIL governor write ($_new_gov)"
        fi
      else
        [ -n "$_want_gov" ] && { APPLY_WARN=$((APPLY_WARN + 1)); _note "gpu: governor '$_want_gov' unavailable, kept current"; }
      fi
    fi

    # max cap (percent of absolute max)
    _max_pct="$(pct_or_keep "$P_GPU_MAX_FREQ_PCT" 20 100)"
    if [ "$_max_pct" != "-1" ] && is_uint "$_gmax_abs"; then
      _target="$(pct_value "$_gmax_abs" "$_max_pct")"
      _snap="$(pick_freq "$_avail_file" "$_target")"
      is_uint "$_snap" || _snap="$_target"
      if write_file "${_dir}/max_freq" "$_snap"; then
        _note "gpu: max -> $_snap Hz (${_max_pct}%)"
      else
        APPLY_FAIL=$((APPLY_FAIL + 1)); _note "gpu: FAIL max_freq write ($_snap)"
      fi
    fi

    # min floor
    _min_pct="$(pct_or_keep "$P_GPU_MIN_FREQ_PCT" 0 100)"
    if [ "$_min_pct" != "-1" ] && is_uint "$_gmin_abs" && is_uint "$_gmax_abs"; then
      _span=$(( _gmax_abs - _gmin_abs ))
      _target=$(( _gmin_abs + $(pct_value "$_span" "$_min_pct") ))
      _snap="$(pick_freq "$_avail_file" "$_target")"
      is_uint "$_snap" || _snap="$_target"
      _hard_max="$(read_file "${_dir}/max_freq")"
      is_uint "$_hard_max" && [ "$_snap" -gt "$_hard_max" ] && _snap="$_hard_max"
      if write_file "${_dir}/min_freq" "$_snap"; then
        _note "gpu: min -> $_snap Hz"
      else
        APPLY_WARN=$((APPLY_WARN + 1)); _note "gpu: WARN min_freq write ($_snap)"
      fi
    fi
    return 0
  fi

  if [ "$_kind" = "kgsl_legacy" ]; then
    _gci_min="$(read_file "${_dir}/min_gpuclk")"
    _gci_max="$(read_file "${_dir}/max_gpuclk")"
    _max_pct="$(pct_or_keep "$P_GPU_MAX_FREQ_PCT" 20 100)"
    if [ "$_max_pct" != "-1" ] && is_uint "$_gci_max"; then
      _target="$(pct_value "$_gci_max" "$_max_pct")"
      write_file "${_dir}/max_gpuclk" "$_target" \
        && _note "gpu: max_gpuclk -> $_target Hz" \
        || { APPLY_FAIL=$((APPLY_FAIL + 1)); _note "gpu: FAIL max_gpuclk write"; }
    fi
    if ! is_keep "$P_GPU_GOVERNOR"; then
      _note "gpu: legacy kgsl node, governor not managed"
    fi
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# apply_io - storage scheduler + readahead (non-critical)
# ---------------------------------------------------------------------------
apply_io() {
  if ! enable_flag ENABLE_IO_TWEAKS; then
    _note "io: skipped (disabled)"
    return 0
  fi
  for _s in $(storage_devs); do
    _q="/sys/block/$_s/queue"
    # scheduler
    if ! is_keep "$P_IO_SCHEDULER"; then
      _avail_raw="$(cat "$(spath "$_q/scheduler")" 2>/dev/null)"
      _avail="$(print -nr -- "$_avail_raw" | sed -e 's/\[//g' -e 's/\]//g')"
      _want="$(print -nr -- "$P_IO_SCHEDULER" | tr 'A-Z' 'a-z')"
      _picked=""
      for _cand in $_want kyber mq-deadline none noop deadline bfq; do
        case " $_avail " in
          *" $_cand "*) _picked="$_cand"; break ;;
        esac
      done
      if [ -n "$_picked" ]; then
        if write_file "$_q/scheduler" "$_picked"; then
          _note "io[$_s]: scheduler -> $_picked"
        else
          APPLY_WARN=$((APPLY_WARN + 1)); _note "io[$_s]: WARN scheduler write"
        fi
      else
        _note "io[$_s]: scheduler '$P_IO_SCHEDULER' unavailable ($_avail), kept"
      fi
    fi
    # read_ahead_kb
    if ! is_keep "$P_IO_READ_AHEAD_KB"; then
      _ra="$(clamp_int "$P_IO_READ_AHEAD_KB" 32 2048)"
      if write_file "$_q/read_ahead_kb" "$_ra"; then
        _note "io[$_s]: read_ahead_kb -> $_ra"
      else
        APPLY_WARN=$((APPLY_WARN + 1)); _note "io[$_s]: WARN read_ahead_kb write"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# apply_vm - /proc/sys/vm tunables (non-critical)
# ---------------------------------------------------------------------------
apply_vm() {
  if ! enable_flag ENABLE_VM_TWEAKS; then
    _note "vm: skipped (disabled)"
    return 0
  fi
  _vm_set() {
    _vm_key="$1"; _vm_raw="$2"; _vm_min="$3"; _vm_max="$4"
    is_keep "$_vm_raw" && return 0
    _vm_val="$(clamp_int "$_vm_raw" "$_vm_min" "$_vm_max")"
    if write_file "/proc/sys/vm/$_vm_key" "$_vm_val"; then
      _note "vm: $_vm_key -> $_vm_val"
    else
      APPLY_WARN=$((APPLY_WARN + 1)); _note "vm: WARN $_vm_key write"
    fi
  }
  _vm_set swappiness "$P_VM_SWAPPINESS" 0 200
  _vm_set vfs_cache_pressure "$P_VM_VFS_CACHE_PRESSURE" 0 1000
  _vm_set dirty_ratio "$P_VM_DIRTY_RATIO" 1 100
  _vm_set dirty_background_ratio "$P_VM_DIRTY_BACKGROUND_RATIO" 1 100
  _vm_set compaction_proactiveness "$P_VM_COMPACTION_PROACTIVENESS" 0 100
  _vm_set watermark_boost_factor "$P_VM_WATERMARK_BOOST_FACTOR" 0 1000000
}

# ---------------------------------------------------------------------------
# current_profile - print active profile name (default balanced)
# ---------------------------------------------------------------------------
current_profile() {
  init_default_config
  _cp="$(config_get CURRENT_PROFILE)"
  case "$_cp" in
    battery_saver|balanced|performance|gaming|custom) print -r -- "$_cp" ;;
    *) print -r -- 'balanced' ;;
  esac
}

# ---------------------------------------------------------------------------
# apply_profile NAME [--no-backup]
# Full pipeline: snapshot -> apply domains -> verify counts -> rollback on fail
# Echoes notes; returns 0 ok / 1 rolled back / 2 usage error
# ---------------------------------------------------------------------------
apply_profile() {
  _ap_name="$1"; _ap_nobackup="${2:-}"
  _ap_conf="$(profile_file "$_ap_name")" || { log "apply_profile: unknown profile '$_ap_name'"; return 2; }
  [ -f "$_ap_conf" ] || { log "apply_profile: missing conf $_ap_conf"; return 2; }

  init_default_config
  APPLY_FAIL=0; APPLY_WARN=0; APPLY_NOTE=""

  _backup=1
  [ "$(config_get BACKUP_ON_APPLY)" = "0" ] && _backup=0
  [ "$_ap_nobackup" = "--no-backup" ] && _backup=0

  _auto_name="auto-$(date +%s)-$$"
  if [ "$_backup" = "1" ]; then
    backup_snapshot "$_auto_name" "pre-apply-$_ap_name" || _note "snapshot failed, continuing without rollback net"
  fi

  load_profile "$_ap_conf"
  apply_cpu
  apply_gpu
  apply_io
  apply_vm

  if [ "$APPLY_FAIL" -gt 0 ]; then
    log "apply_profile: $APPLY_FAIL critical failure(s) applying '$_ap_name' — rolling back"
    if [ "$_backup" = "1" ]; then
      backup_restore "$_auto_name" >/dev/null 2>&1
      APPLY_NOTE="$APPLY_NOTE!! Rollback: ${APPLY_FAIL} critical failure(s), previous state restored."
    else
      APPLY_NOTE="$APPLY_NOTE!! ${APPLY_FAIL} critical failure(s) (backup disabled)."
    fi
    return 1
  fi

  config_set CURRENT_PROFILE "$_ap_name"
  log "apply_profile: applied '$_ap_name' (warn=$APPLY_WARN)"
  command -v module_prop_set_status >/dev/null 2>&1 && module_prop_set_status >/dev/null 2>&1
  return 0
}
