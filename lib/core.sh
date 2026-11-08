#
# ThermalCore - core library: logging, sysfs io, validation, JSON
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

# ---------------------------------------------------------------------------
# Paths (override for testing via environment)
# ---------------------------------------------------------------------------
THERMALCORE_MODDIR="${THERMALCORE_MODDIR:-/data/adb/modules/thermal-core}"
THERMALCORE_DATA="${THERMALCORE_DATA:-/data/adb/thermal-core}"
THERMALCORE_SYSROOT="${THERMALCORE_SYSROOT:-}"
THERMALCORE_LOG_DIR="$THERMALCORE_DATA/logs"
THERMALCORE_BACKUP_DIR="$THERMALCORE_DATA/backup"
THERMALCORE_STATE_FILE="$THERMALCORE_DATA/config.conf"
THERMALCORE_CUSTOM_CONF="$THERMALCORE_DATA/custom.conf"
THERMALCORE_DETECT_CACHE="$THERMALCORE_DATA/detect.cache"
THERMALCORE_GUARD_PID="$THERMALCORE_DATA/guard.pid"
THERMALCORE_GUARD_STATE="$THERMALCORE_DATA/guard.state"
THERMALCORE_CPU_STAT_CACHE="$THERMALCORE_DATA/.cpu_stat"
THERMALCORE_CR=$'\r'
THERMALCORE_TAB=$'\t' 

# ---------------------------------------------------------------------------
# init_dirs - create private data dirs (0755 root)
# ---------------------------------------------------------------------------
init_dirs() {
  [ -d "$THERMALCORE_DATA" ] || mkdir -p "$THERMALCORE_DATA" 2>/dev/null
  [ -d "$THERMALCORE_LOG_DIR" ] || mkdir -p "$THERMALCORE_LOG_DIR" 2>/dev/null
  [ -d "$THERMALCORE_BACKUP_DIR" ] || mkdir -p "$THERMALCORE_BACKUP_DIR" 2>/dev/null
  chmod 0755 "$THERMALCORE_DATA" "$THERMALCORE_LOG_DIR" "$THERMALCORE_BACKUP_DIR" 2>/dev/null
}

# ---------------------------------------------------------------------------
# spath - prefix a sysfs/procfs absolute path with the (optional) test root
# ---------------------------------------------------------------------------
spath() {
  print -r -- "$THERMALCORE_SYSROOT$1"
}

# ---------------------------------------------------------------------------
# read_file PATH - read a file trimmed, empty on failure
# ---------------------------------------------------------------------------
read_file() {
  _rf_path="$THERMALCORE_SYSROOT$1"
  [ -f "$_rf_path" ] || return 1
  _rf_val=""
  IFS= read -r _rf_val < "$_rf_path" 2>/dev/null
  case "$_rf_val" in
    *"$THERMALCORE_CR"*) _rf_val="${_rf_val%"$THERMALCORE_CR"}" ;;
  esac
  print -r -- "$_rf_val"
}

# read_val PATH -> sets _RV in-process (no subshell). 1 if unreadable.
read_val() {
  _rv_path="$THERMALCORE_SYSROOT$1"
  _RV=""
  [ -f "$_rv_path" ] || return 1
  IFS= read -r _RV < "$_rv_path" 2>/dev/null
  case "$_RV" in
    *"$THERMALCORE_CR"*) _RV="${_RV%"$THERMALCORE_CR"}" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# write_file PATH VALUE - atomic-ish write, fails quietly (returns 1)
# ---------------------------------------------------------------------------
write_file() {
  _wf_path="$THERMALCORE_SYSROOT$1"
  [ -f "$_wf_path" ] || return 1
  [ -w "$_wf_path" ] || return 1
  print -r -- "$2" > "$_wf_path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# log MSG... - append to log file with size cap (keeps last ~200 lines >512KB)
# ---------------------------------------------------------------------------
log() {
  init_dirs
  _log_line="$(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
  print -r -- "$_log_line" >> "$THERMALCORE_LOG_DIR/thermalcore.log" 2>/dev/null
  _sz=$(wc -c < "$THERMALCORE_LOG_DIR/thermalcore.log" 2>/dev/null)
  if [ -n "$_sz" ] && [ "$_sz" -gt 524288 ]; then
    tail -n 200 "$THERMALCORE_LOG_DIR/thermalcore.log" > "$THERMALCORE_LOG_DIR/thermalcore.log.tmp" 2>/dev/null
    mv "$THERMALCORE_LOG_DIR/thermalcore.log.tmp" "$THERMALCORE_LOG_DIR/thermalcore.log" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
# str_trim VALUE -> sets _ST (strips CR + leading/trailing spaces, no forks)
str_trim() {
  _ST="$1"
  case "$_ST" in
    *"$THERMALCORE_CR"*) _ST="${_ST%"$THERMALCORE_CR"}" ;;
  esac
  _ST="${_ST#"${_ST%%[! ]*}"}"
  _ST="${_ST%"${_ST##*[! ]}"}"
}

is_int() {
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;
    -*) [ ${#1} -gt 1 ] ;;
    *) return 0 ;;
  esac
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# pct_value VALUE PERCENT -> integer VALUE*PERCENT/100 (awk: no 32-bit overflow)
pct_value() {
  is_uint "$1" || { print -r -- 0; return 1; }
  _pv_v="$1"; _pv_p="$2"; is_uint "$_pv_p" || _pv_p=0
  print -r -- "$(( (_pv_v / 100) * _pv_p + ((_pv_v % 100) * _pv_p) / 100 ))"
}

# clamp_int VALUE MIN MAX -> prints clamped value
clamp_int() {
  _ci_v="$1"; _ci_min="$2"; _ci_max="$3"
  is_int "$_ci_v" || { print -r -- "$_ci_min"; return 1; }
  [ "$_ci_v" -lt "$_ci_min" ] && _ci_v="$_ci_min"
  [ "$_ci_v" -gt "$_ci_max" ] && _ci_v="$_ci_max"
  print -r -- "$_ci_v"
}

# json_escape STRING -> JSON-safe string
json_escape() {
  case "$1" in
    *\\*|*\"*|*"$THERMALCORE_TAB"*)
      print -nr -- "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n\r' ;;
    *)
      print -nr -- "$1" ;;
  esac
}
# json_escape_val VALUE -> sets _JE in-process (no subshell)
json_escape_val() {
  case "$1" in
    *\\*|*\"*|*"$THERMALCORE_TAB"*)
      _JE="$(print -nr -- "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n\r')" ;;
    *)
      _JE="$1" ;;
  esac
}

# json_kv_bool / json_kv_num / json_kv_str helpers kept inline in status.sh

# ---------------------------------------------------------------------------
# normalize_temp_centi CENTI - decide milli/deci/plain °C -> prints "xx.x"
# Accepts raw integer: >=1000 => millidegree, >=100 => decidegree, else degree
# ---------------------------------------------------------------------------
temp_tenths() {
  _tt_v="$1"
  is_int "$_tt_v" || return 1
  case "$_tt_v" in
    -*) _tt_abs="${_tt_v#-}"; _tt_neg=1 ;;
    *)  _tt_abs="$_tt_v"; _tt_neg=0 ;;
  esac
  if [ "$_tt_abs" -ge 1000 ]; then
    _tt_t=$(( (_tt_abs + 50) / 100 ))
  elif [ "$_tt_abs" -ge 100 ]; then
    _tt_t="$_tt_abs"
  else
    _tt_t=$(( _tt_abs * 10 ))
  fi
  [ "$_tt_neg" = 1 ] && _tt_t=$(( -_tt_t ))
  print -r -- "$_tt_t"
}

tenths_to_c() {
  _tc_t="$1"
  if [ "$_tc_t" -lt 0 ]; then
    _tc_a=$(( -_tc_t )); _tc_s="-"
  else
    _tc_a="$_tc_t"; _tc_s=""
  fi
  print -r -- "${_tc_s}$(( _tc_a / 10 )).$(( _tc_a % 10 ))"
}

normalize_temp() {
  _nt_t="$(temp_tenths "$1")" || { print -r -- '0.0'; return 1; }
  tenths_to_c "$_nt_t"
}

# freq_pct CUR MAX -> integer percent (scaled to kHz: safe on 32-bit shells)
freq_pct() {
  is_uint "$1" && is_uint "$2" && [ "$2" -gt 0 ] || { print -r -- '0'; return 1; }
  _fp_cur=$(( $1 / 1000 ))
  _fp_max=$(( $2 / 1000 ))
  [ "$_fp_max" -gt 0 ] || { print -r -- '0'; return 1; }
  print -r -- "$(( _fp_cur * 100 / _fp_max ))"
}
# freq_pct_val CUR MAX -> sets _FPCT in-process. 0 on success.
freq_pct_val() {
  _FPCT=0
  is_uint "$1" && is_uint "$2" && [ "$2" -gt 0 ] || return 1
  _fpv_cur=$(( $1 / 1000 )); _fpv_max=$(( $2 / 1000 ))
  [ "$_fpv_max" -gt 0 ] || return 1
  _FPCT=$(( _fpv_cur * 100 / _fpv_max ))
  return 0
}

# num_gt A B -> true when unsigned integer A > B (length-safe)
num_gt() {
  [ "${#1}" -gt "${#2}" ] && return 0
  [ "${#1}" -lt "${#2}" ] && return 1
  [ "$1" \> "$2" ]
}

# ---------------------------------------------------------------------------
# prop_get KEY [DEFAULT] - getprop with fallback (never fails)
# ---------------------------------------------------------------------------
prop_get() {
  _pg_v="$(getprop "$1" 2>/dev/null)"
  if [ -z "$_pg_v" ]; then
    print -r -- "${2:-}"
  else
    print -r -- "$_pg_v"
  fi
}

# ---------------------------------------------------------------------------
# config_get KEY [FILE] - read key from a shell-style conf (KEY=VALUE lines)
# ---------------------------------------------------------------------------
config_get() {
  _cg_key="$1"; _cg_file="${2:-$THERMALCORE_STATE_FILE}"
  [ -f "$_cg_file" ] || return 1
  _cg_val=""
  while IFS= read -r _cg_line; do
    case "$_cg_line" in
      "$_cg_key="*) _cg_val="${_cg_line#*=}"; break ;;
    esac
  done < "$_cg_file"
  # strip surrounding quotes if any
  case "$_cg_val" in
    \"*\") _cg_val="${_cg_val#\"}"; _cg_val="${_cg_val%\"}" ;;
    \'*\') _cg_val="${_cg_val#\'}"; _cg_val="${_cg_val%\'}" ;;
  esac
  print -r -- "$_cg_val"
}

# ---------------------------------------------------------------------------
# config_set KEY VALUE [FILE] - update or append key atomically (0644 root)
# ---------------------------------------------------------------------------
config_set() {
  _cs_key="$1"; _cs_val="$2"; _cs_file="${3:-$THERMALCORE_STATE_FILE}"
  init_dirs
  _cs_tmp="$_cs_file.tmp.$$"
  if [ -f "$_cs_file" ]; then
    grep -v -E "^${_cs_key}=" "$_cs_file" > "$_cs_tmp" 2>/dev/null
  else
    : > "$_cs_tmp"
  fi
  print -r -- "$_cs_key=$_cs_val" >> "$_cs_tmp"
  mv "$_cs_tmp" "$_cs_file" && chmod 0644 "$_cs_file"
}

# ---------------------------------------------------------------------------
# storage_devs - real block storage devices worth tuning (sda*, mmcblk*, nvme*, ufs*)
# ---------------------------------------------------------------------------
storage_devs() {
  for _d in "$THERMALCORE_SYSROOT/sys/block"/*; do
    [ -d "$_d" ] || continue
    _name="${_d##*/}"
    case "$_name" in
      sd*|mmcblk*|nvme*|ufs*) print -r -- "$_name" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# pick_from_list WANTED ACTUAL_LIST... -> prints wanted if present else first fallback
# Used with governor fallback chains.
# ---------------------------------------------------------------------------
pick_from_list() {
  _pfl_want="$1"; shift
  _pfl_have=" $* "
  case "$_pfl_have" in
    *" $_pfl_want "*) print -r -- "$_pfl_want"; return 0 ;;
  esac
  return 1
}

# first_available WANTED_LIST ; availability read from stdin line (space separated)
# usage: pick_governor "wanted" "avail1 avail2 ..." fallback1 fallback2 ...
pick_governor() {
  _pgv_want="$1"; _pgv_avail="$2"; shift 2
  case " $_pgv_avail " in
    *" $_pgv_want "*) print -r -- "$_pgv_want"; return 0 ;;
  esac
  for _pgv_fb in "$@"; do
    case " $_pgv_avail " in
      *" $_pgv_fb "*) print -r -- "$_pgv_fb"; log "governor fallback: '$_pgv_want' unavailable -> '$_pgv_fb'"; return 0 ;;
    esac
  done
  return 1
}

# pick_freq AVAIL_LIST_FILE TARGET_HZ - snap TARGET to nearest available freq (<= target preferred)
pick_freq() {
  _pf_file="$(spath "$1")"; _pf_target="$2"
  [ -f "$_pf_file" ] || { print -r -- "$_pf_target"; return 0; }
  _pf_best=""
  read_val "$1"; _pf_all="$_RV"
  for _pf_f in $_pf_all; do
    is_uint "$_pf_f" || continue
    if [ "$_pf_f" -le "$_pf_target" ]; then
      if [ -z "$_pf_best" ] || [ "$_pf_f" -gt "$_pf_best" ]; then _pf_best="$_pf_f"; fi
    fi
  done
  if [ -z "$_pf_best" ]; then
    # target below everything: take lowest available
    for _pf_f in $_pf_all; do
      is_uint "$_pf_f" || continue
      if [ -z "$_pf_best" ] || [ "$_pf_f" -lt "$_pf_best" ]; then _pf_best="$_pf_f"; fi
    done
  fi
  print -r -- "${_pf_best:-$_pf_target}"
}

# now_ts - unix timestamp
now_ts() { date +%s 2>/dev/null || print -r -- '0'; }
