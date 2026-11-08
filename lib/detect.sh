#
# ThermalCore - hardware detection (chipset/CPU/GPU/thermal/storage)
#
# Copyright (C) 2026-2027 ridhzxlabs
# Licensed under the Apache License, Version 2.0
#

# shellcheck shell=sh

# GPU recognisable name fragments are matched inline in _detect_gpu

# ---------------------------------------------------------------------------
# _detect_root_manager - prints Magisk | KernelSU | APatch | Unknown
# ---------------------------------------------------------------------------
detect_root_manager() {
  if [ -d "$(spath /data/adb/ksu)" ] || [ -f "$(spath /data/adb/ksud)" ] || command -v ksud >/dev/null 2>&1; then
    print -nr -- 'KernelSU'
    return 0
  fi
  if [ -d "$(spath /data/adb/ap)" ] || [ -f "$(spath /data/adb/apd)" ]; then
    print -nr -- 'APatch'
    return 0
  fi
  if [ -d "$(spath /data/adb/magisk)" ] || [ -f "$(spath /data/adb/magisk/magisk)" ]; then
    print -nr -- 'Magisk'
    return 0
  fi
  print -nr -- 'Unknown'
}

# ---------------------------------------------------------------------------
# _detect_gpu - sets globals: GPU_KIND GPU_NODE GPU_NAME (via stdout lines)
# GPU_KIND: kgsl | devfreq | mali_dvfs | none
# ---------------------------------------------------------------------------
_detect_gpu() {
  # 1) Qualcomm KGSL
  _kg="$(spath /sys/class/kgsl/kgsl-3d0)"
  if [ -d "$_kg" ]; then
    _kg_gov=""; _kg_min=""; _kg_max=""; _kg_cur=""
    if [ -d "$_kg/devfreq" ]; then
      _kg_gov="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/governor)"
      _kg_min="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/min_freq)"
      _kg_max="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/max_freq)"
      _kg_cur="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq)"
      _kg_avail="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/available_governors)"
      GPU_KIND=kgsl; GPU_NODE=/sys/class/kgsl/kgsl-3d0/devfreq
      print -r -- "gpu_kind=$GPU_KIND
gpu_node=$GPU_NODE
gpu_name=kgsl-3d0
gpu_governor=${_kg_gov:-unknown}
gpu_gov_avail=${_kg_avail:-}
gpu_min_freq=${_kg_min:-0}
gpu_max_freq=${_kg_max:-0}
gpu_cur_freq=${_kg_cur:-0}"
      return 0
    fi
    # legacy kgsl nodes
    _lk_min="$(read_file /sys/class/kgsl/kgsl-3d0/min_gpuclk)"
    _lk_max="$(read_file /sys/class/kgsl/kgsl-3d0/max_gpuclk)"
    _lk_cur="$(read_file /sys/class/kgsl/kgsl-3d0/gpuclk)"
    _lk_gov="$(read_file /sys/class/kgsl/kgsl-3d0/devfreq/governor)"; [ -z "$_lk_gov" ] && _lk_gov="$(read_file /sys/class/kgsl/kgsl-3d0/default_governor)"
    GPU_KIND=kgsl; GPU_NODE=/sys/class/kgsl/kgsl-3d0
    print -r -- "gpu_kind=$GPU_KIND
gpu_node=$GPU_NODE
gpu_name=kgsl-3d0
gpu_governor=${_lk_gov:-unknown}
gpu_gov_avail=
gpu_min_freq=${_lk_min:-0}
gpu_max_freq=${_lk_max:-0}
gpu_cur_freq=${_lk_cur:-0}
gpu_min_node=min_gpuclk
gpu_max_node=max_gpuclk"
    return 0
  fi

  # 2) generic devfreq scan (Mali / Tensor g3d / Exynos / Xclipse ...)
  for _d in "$THERMALCORE_SYSROOT/sys/class/devfreq"/*; do
    [ -d "$_d" ] || continue
    _name="${_d##*/}"
    read_val "/sys/class/devfreq/$_name/name"; _realname="$_RV"
    case "$_name $_realname" in
      *[A-Z]*)
        _name="$(print -nr -- "$_name" | tr 'A-Z' 'a-z')"
        _realname="$(print -nr -- "$_realname" | tr 'A-Z' 'a-z')" ;;
    esac
    case "$_name $_realname" in
      *dvfsrc*|*memory*|*bandwidth*|*bw*|*bus*|*cache*|*cci*) continue ;;
      *mali*|*kgsl*|*gpu*|*g3d*|*adreno*|*xclipse*|*tensor*|*exynos*|*3d*)
        read_val "/sys/class/devfreq/$_name/governor"; _gov="$_RV"
        read_val "/sys/class/devfreq/$_name/available_governors"; _avail="$_RV"
        read_val "/sys/class/devfreq/$_name/min_freq"; _min="$_RV"
        read_val "/sys/class/devfreq/$_name/max_freq"; _max="$_RV"
        read_val "/sys/class/devfreq/$_name/cur_freq"; _cur="$_RV"
        GPU_KIND=devfreq; GPU_NODE="/sys/class/devfreq/$_name"
        print -r -- "gpu_kind=$GPU_KIND
gpu_node=$GPU_NODE
gpu_name=$_name
gpu_governor=${_gov:-unknown}
gpu_gov_avail=${_avail:-}
gpu_min_freq=${_min:-0}
gpu_max_freq=${_max:-0}
gpu_cur_freq=${_cur:-0}"
        return 0
        ;;
    esac
  done

  # 3) legacy Exynos mali dvfs nodes
  _em="$(spath /sys/class/misc/mali0/device)"
  if [ -d "$_em" ] && [ -w "$_em/dvfs_max_lock" ]; then
    GPU_KIND=mali_dvfs; GPU_NODE=/sys/class/misc/mali0/device
    print -r -- "gpu_kind=$GPU_KIND
gpu_node=$GPU_NODE
gpu_name=mali0
gpu_governor=
gpu_gov_avail=
gpu_min_freq=
gpu_max_freq=
gpu_cur_freq="
    return 0
  fi

  GPU_KIND=none; GPU_NODE=
  print -r -- "gpu_kind=none
gpu_node=
gpu_name=
gpu_governor=
gpu_gov_avail=
gpu_min_freq=0
gpu_max_freq=0
gpu_cur_freq=0"
  return 0
}

# ---------------------------------------------------------------------------
# _detect_cpu_clusters - emits policy_N_* lines for every cpufreq policy
# ---------------------------------------------------------------------------
_detect_cpu_clusters() {
  _n=0
  for _p in "$THERMALCORE_SYSROOT/sys/devices/system/cpu/cpufreq"/policy*; do
    [ -d "$_p" ] || continue
    _base="${_p##*/}"
    _pol="${_base#policy}"
    case "$_pol" in (*[!0-9]*) continue ;; esac

    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_governor"; _gov="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_available_governors"; _gavail="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_min_freq"; _cmin="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/cpuinfo_max_freq"; _cmax="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_min_freq"; _smin="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_max_freq"; _smax="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_cur_freq"; _cur="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/scaling_available_frequencies"; _freqs="$_RV"
    read_val "/sys/devices/system/cpu/cpufreq/$_base/related_cpus"; _related="$_RV"
    [ -z "$_related" ] && { read_val "/sys/devices/system/cpu/cpufreq/$_base/affected_cpus"; _related="$_RV"; }
    # governor tunable dir (name varies: sugov_ext / schedutil / walt ...)
    _tdir=""
    for _t in sugov_ext schedutil walt walt_boost interactive conservative powersave performance; do
      [ -d "$_p/$_t" ] && { _tdir="$_t"; break; }
    done
    print -r -- "policy_${_pol}_related=${_related:-$_pol}"
    print -r -- "policy_${_pol}_governor=${_gov:-unknown}
policy_${_pol}_gov_avail=${_gavail:-}"
    print -r -- "policy_${_pol}_cpuinfo_min=${_cmin:-0}
policy_${_pol}_cpuinfo_max=${_cmax:-0}"
    print -r -- "policy_${_pol}_scaling_min=${_smin:-0}
policy_${_pol}_scaling_max=${_smax:-0}"
    print -r -- "policy_${_pol}_cur_freq=${_cur:-0}
policy_${_pol}_avail_freq=${_freqs:-}"
    print -r -- "policy_${_pol}_tunable_dir=${_tdir:-}"
    print -r -- "cpu_policy_${_pol}=1"
    _n=$((_n + 1))
  done
  print -r -- "cpu_cluster_count=$_n"
}

# ---------------------------------------------------------------------------
# _detect_thermal - emit thermal_zone_N_* summary + interesting zone indexes
# ---------------------------------------------------------------------------
_detect_thermal() {
  _count=0
  _z_bat=""; _z_gpu=""; _z_soc=""; _z_skin=""; _z_cpu=""
  for _z in "$THERMALCORE_SYSROOT/sys/class/thermal"/thermal_zone*; do
    [ -d "$_z" ] || continue
    _idx="${_z##*thermal_zone}"
    case "$_idx" in (*[!0-9]*) continue ;; esac
    read_val "/sys/class/thermal/thermal_zone$_idx/type"; _type="$_RV"
    print -r -- "thermal_zone_${_idx}_type=$_type"
    case "$_type" in
      *battery*|*Battery*|*BATTERY*)  [ -z "$_z_bat" ]  && _z_bat="$_idx" ;;
      *gpu*|*Gpu*|*GPU*|*gpuss*)      [ -z "$_z_gpu" ]  && _z_gpu="$_idx" ;;
      *soc*|*Soc*|*SOC*|*tsens*|*TSENS*|*ap*-*top*|*AP*-*TOP*) [ -z "$_z_soc" ] && _z_soc="$_idx" ;;
      *skin*|*Skin*|*SKIN*|*tskin*)   [ -z "$_z_skin" ] && _z_skin="$_idx" ;;
      *cpu*|*Cpu*|*CPU*)              [ -z "$_z_cpu" ]  && _z_cpu="$_idx" ;;
    esac
    _count=$((_count + 1))
  done
  print -r -- "thermal_zone_count=$_count"
  print -r -- "thermal_zone_battery=${_z_bat:--1}
thermal_zone_gpu=${_z_gpu:--1}
thermal_zone_soc=${_z_soc:--1}
thermal_zone_skin=${_z_skin:--1}
thermal_zone_cpu=${_z_cpu:--1}"
}

# ---------------------------------------------------------------------------
# detect_refresh - rebuild $THERMALCORE_DETECT_CACHE, print it
# ---------------------------------------------------------------------------
detect_refresh() {
  init_dirs
  _tmp="$THERMALCORE_DETECT_CACHE.tmp.$$"
  {
    print -r -- 'detect_version=1'
    _pp="$THERMALCORE_DATA/.props.$$"
    _p_soc=""; _p_platform=""; _p_hw=""; _p_dev=""; _p_model=""
    _p_rel=""; _p_sdk=""; _p_fp=""; _p_abi=""
    ( getprop ) > "$_pp" 2>/dev/null
    if [ -s "$_pp" ]; then
      while IFS= read -r _pl; do
        _pk="${_pl%%]: [*}"; _pk="${_pk#[}"
        _pv="${_pl#*]: [}"; _pv="${_pv%]}"
        case "$_pk" in
          ro.soc.model)             _p_soc="$_pv" ;;
          ro.board.platform)        _p_platform="$_pv" ;;
          ro.hardware)              _p_hw="$_pv" ;;
          ro.product.device)        _p_dev="$_pv" ;;
          ro.product.model)         _p_model="$_pv" ;;
          ro.build.version.release) _p_rel="$_pv" ;;
          ro.build.version.sdk)     _p_sdk="$_pv" ;;
          ro.build.fingerprint)     _p_fp="$_pv" ;;
          ro.product.cpu.abi)       _p_abi="$_pv" ;;
        esac
      done < "$_pp"
    fi
    rm -f "$_pp" 2>/dev/null
    [ -n "$_p_soc" ] || _p_soc="${_p_hw:-unknown}"
    [ -n "$_p_platform" ] || _p_platform="unknown"
    [ -n "$_p_hw" ] || _p_hw="unknown"
    [ -n "$_p_dev" ] || _p_dev="unknown"
    [ -n "$_p_model" ] || _p_model="unknown"
    [ -n "$_p_rel" ] || _p_rel="unknown"
    [ -n "$_p_sdk" ] || _p_sdk=0
    [ -n "$_p_fp" ] || _p_fp="unknown"
    [ -n "$_p_abi" ] || _p_abi="arm64-v8a"
    print -r -- "chipset=$_p_soc"
    print -r -- "platform=$_p_platform"
    print -r -- "hardware=$_p_hw"
    print -r -- "device=$_p_dev"
    print -r -- "product_model=$_p_model"
    print -r -- "android_release=$_p_rel"
    print -r -- "sdk_int=$_p_sdk"
    print -r -- "build_fingerprint=$_p_fp"
    print -r -- "kernel=$(uname -r 2>/dev/null)"
    print -r -- "abi=$_p_abi"
    print -r -- "root_manager=$(detect_root_manager)"
    _dc_mem=""
    while read -r _dc_mk _dc_mv _dc_mu; do
      [ "$_dc_mk" = "MemTotal:" ] && { _dc_mem="$_dc_mv"; break; }
    done < "$(spath /proc/meminfo)"
    print -r -- "mem_total_kb=${_dc_mem:-0}"
    _detect_cpu_clusters
    _detect_gpu
    _detect_thermal
    _dc_sd=""
    for _dc_s in $(storage_devs); do _dc_sd="$_dc_sd$_dc_s "; done
    print -r -- "storage_devs=${_dc_sd% }"
  } > "$_tmp"
  chmod 0644 "$_tmp"
  mv "$_tmp" "$THERMALCORE_DETECT_CACHE"
}

# ---------------------------------------------------------------------------
# detect_cache - print cache, rebuilding if missing/stale (>24h)
# ---------------------------------------------------------------------------
detect_cache() {
  if [ ! -f "$THERMALCORE_DETECT_CACHE" ]; then
    detect_refresh >/dev/null
  else
    _mtime="$(stat -c %Y "$THERMALCORE_DETECT_CACHE" 2>/dev/null || echo 0)"
    _now="$(now_ts)"
    if [ $((_now - _mtime)) -gt 86400 ]; then
      detect_refresh >/dev/null
    fi
  fi
  cat "$THERMALCORE_DETECT_CACHE"
}

# ---------------------------------------------------------------------------
# detect_get KEY [DEFAULT] - read one key from cache
# ---------------------------------------------------------------------------
detect_get() {
  config_get "$1" "$THERMALCORE_DETECT_CACHE"
}
