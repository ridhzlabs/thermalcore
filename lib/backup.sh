#
# ThermalCore - backup / restore / rollback framework
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

# shellcheck shell=sh

BACKUP_KEEP=5
BACKUP_INSTALL_NAME="install-initial"

# ---------------------------------------------------------------------------
# managed_paths - print "ABSOLUTE_PATH<TAB>class" for every node we may write
# class: cpu | gpu | vm | io
# ---------------------------------------------------------------------------
managed_paths() {
  # CPU cpufreq policies
  for _p in "$THERMALCORE_SYSROOT/sys/devices/system/cpu/cpufreq"/policy*; do
    [ -d "$_p" ] || continue
    print -r -- "/sys/devices/system/cpu/cpufreq/${_p##*/}/scaling_governor	cpu"
    print -r -- "/sys/devices/system/cpu/cpufreq/${_p##*/}/scaling_max_freq	cpu"
    print -r -- "/sys/devices/system/cpu/cpufreq/${_p##*/}/scaling_min_freq	cpu"
  done
  # GPU (devfreq or kgsl devfreq or legacy mali dvfs)
  if [ -d "$THERMALCORE_SYSROOT/sys/class/kgsl/kgsl-3d0/devfreq" ]; then
    print -r -- "/sys/class/kgsl/kgsl-3d0/devfreq/governor	gpu"
    print -r -- "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq	gpu"
    print -r -- "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq	gpu"
  elif [ -d "$THERMALCORE_SYSROOT/sys/class/kgsl/kgsl-3d0" ]; then
    print -r -- "/sys/class/kgsl/kgsl-3d0/min_gpuclk	gpu"
    print -r -- "/sys/class/kgsl/kgsl-3d0/max_gpuclk	gpu"
  else
    for _g in "$THERMALCORE_SYSROOT/sys/class/devfreq"/*; do
      [ -d "$_g" ] || continue
      _n="${_g##*/}"
      read_val "/sys/class/devfreq/$_n/name"; _rn="$_RV"
      case "$_n $_rn" in
        *[A-Z]*) _n="$(print -nr -- "$_n" | tr 'A-Z' 'a-z')"; _rn="$(print -nr -- "$_rn" | tr 'A-Z' 'a-z')" ;;
      esac
      case "$_n $_rn" in
        *dvfsrc*|*memory*|*bandwidth*|*bw*|*bus*|*cache*|*cci*) continue ;;
        *mali*|*kgsl*|*gpu*|*g3d*|*adreno*|*xclipse*|*tensor*|*exynos*|*3d*)
          print -r -- "/sys/class/devfreq/$_n/governor	gpu"
          print -r -- "/sys/class/devfreq/$_n/min_freq	gpu"
          print -r -- "/sys/class/devfreq/$_n/max_freq	gpu"
          break
          ;;
      esac
    done
    if [ -d "$THERMALCORE_SYSROOT/sys/class/misc/mali0/device" ]; then
      print -r -- "/sys/class/misc/mali0/device/dvfs_min_lock	gpu"
      print -r -- "/sys/class/misc/mali0/device/dvfs_max_lock	gpu"
    fi
  fi
  # VM tunables
  for _v in swappiness vfs_cache_pressure dirty_ratio dirty_background_ratio compaction_proactiveness watermark_boost_factor; do
    [ -f "$THERMALCORE_SYSROOT/proc/sys/vm/$_v" ] && print -r -- "/proc/sys/vm/$_v	vm"
  done
  # Storage I/O
  for _s in $(storage_devs); do
    print -r -- "/sys/block/$_s/queue/scheduler	io"
    print -r -- "/sys/block/$_s/queue/read_ahead_kb	io"
  done
}

# ---------------------------------------------------------------------------
# read_managed_value PATH - value suitable for restore (scheduler -> selected)
# ---------------------------------------------------------------------------
read_managed_value() {
  _RMV=""
  read_val "$1" || return 1
  _rmv="$_RV"
  case "$1" in
    */queue/scheduler)
      case "$_rmv" in
        *"["*"]"*) _rmv="${_rmv##*\[}"; _rmv="${_rmv%%\]*}" ;;
        *" "*) _rmv="${_rmv%% *}" ;;
      esac ;;
  esac
  _RMV="$_rmv"
  print -r -- "$_rmv"
}

# ---------------------------------------------------------------------------
# backup_snapshot NAME REASON - snapshot all managed paths
# ---------------------------------------------------------------------------
backup_snapshot() {
  _bs_name="$1"; _bs_reason="${2:-manual}"
  case "$_bs_name" in
    ''|*[!A-Za-z0-9._-]*) log "backup_snapshot: invalid name '$_bs_name'"; return 1 ;;
  esac
  init_dirs
  _bs_dir="$THERMALCORE_BACKUP_DIR/$_bs_name"
  rm -rf "$_bs_dir"
  mkdir -p "$_bs_dir" || return 1
  _tmp="$_bs_dir/state.tmp"
  : > "$_tmp"
  managed_paths > "$_bs_dir/paths.tmp"
  while IFS='	' read -r _path _class; do
    read_managed_value "$_path"; _val="$_RMV"
    [ -n "$_val" ] && print -r -- "$_path	$_val" >> "$_tmp"
  done < "$_bs_dir/paths.tmp"
  rm -f "$_bs_dir/paths.tmp"
  mv "$_tmp" "$_bs_dir/state"
  _bs_profile="unknown"
  if command -v current_profile >/dev/null 2>&1; then
    _bs_profile="$(current_profile 2>/dev/null)"
  fi
  {
    print -r -- "name=$_bs_name"
    print -r -- "reason=$_bs_reason"
    print -r -- "created=$(now_ts)"
    print -r -- "profile=${_bs_profile:-unknown}"
    print -r -- "files=$(wc -l < "$_bs_dir/state" 2>/dev/null)"
  } > "$_bs_dir/manifest"
  chmod 0644 "$_bs_dir/state" "$_bs_dir/manifest"
  log "backup_snapshot: '$_bs_name' ($_bs_reason) files=$(wc -l < "$_bs_dir/state")"
  backup_prune
  return 0
}

# ---------------------------------------------------------------------------
# backup_restore NAME - write snapshot values back; returns #failures
# ---------------------------------------------------------------------------
backup_restore() {
  _br_name="$1"
  _br_dir="$THERMALCORE_BACKUP_DIR/$_br_name"
  [ -f "$_br_dir/state" ] || { log "backup_restore: '$_br_name' not found"; return 2; }
  _fail=0; _ok=0
  while IFS='	' read -r _path _val; do
    [ -n "$_path" ] || continue
    if write_file "$_path" "$_val"; then
      _ok=$((_ok + 1))
    else
      _fail=$((_fail + 1))
      log "backup_restore: FAILED $_path=$_val"
    fi
  done < "$_br_dir/state"
  _br_profile="$(config_get profile "$_br_dir/manifest" 2>/dev/null)"
  case "$_br_profile" in
    battery_saver|balanced|performance|gaming|custom)
      config_set CURRENT_PROFILE "$_br_profile"
      log "backup_restore: current profile restored to '$_br_profile'" ;;
  esac
  log "backup_restore: '$_br_name' ok=$_ok fail=$_fail"
  return $_fail
}

# ---------------------------------------------------------------------------
# backup_prune - keep newest BACKUP_KEEP snapshots + install-initial
# ---------------------------------------------------------------------------
backup_prune() {
  [ -d "$THERMALCORE_BACKUP_DIR" ] || return 0
  # keep newest BACKUP_KEEP snapshots; install-initial is always kept
  _all="$(ls -1t "$THERMALCORE_BACKUP_DIR" 2>/dev/null)"
  _i=0
  for _d in $_all; do
    [ "$_d" = "$BACKUP_INSTALL_NAME" ] && continue
    _i=$((_i + 1))
    if [ "$_i" -gt "$BACKUP_KEEP" ]; then
      rm -rf "${THERMALCORE_BACKUP_DIR:?}/$_d"
      log "backup_prune: removed old snapshot '$_d'"
    fi
  done
}

# ---------------------------------------------------------------------------
# backup_latest - print name of most recent snapshot (excluding install-initial)
# ---------------------------------------------------------------------------
backup_latest() {
  ls -1t "$THERMALCORE_BACKUP_DIR" 2>/dev/null | grep -v -x "$BACKUP_INSTALL_NAME" | head -n 1
}

# ---------------------------------------------------------------------------
# backup_list - print "name<TAB>created<TAB>reason<TAB>files"
# ---------------------------------------------------------------------------
backup_list() {
  [ -d "$THERMALCORE_BACKUP_DIR" ] || return 0
  for _d in "$THERMALCORE_BACKUP_DIR"/*; do
    [ -d "$_d" ] || continue
    _m="$_d/manifest"
    if [ -f "$_m" ]; then
      _name="$(config_get name "$_m")"; _created="$(config_get created "$_m")"
      _reason="$(config_get reason "$_m")"; _files="$(config_get files "$_m")"
      printf '%s\t%s\t%s\t%s\n' "${_name:-${_d##*/}}" "${_created:-0}" "${_reason:-?}" "${_files:-?}"
    else
      printf '%s\t0\t?\t?\n' "${_d##*/}"
    fi
  done
}
