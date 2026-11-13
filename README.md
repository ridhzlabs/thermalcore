# ThermalCore

![ThermalCore banner](https://raw.githubusercontent.com/ridhzlabs/thermalcore/main/banner.jpg)

[![Release](https://img.shields.io/github/v/release/ridhzlabs/thermalcore?style=flat-square)](https://github.com/ridhzlabs/thermalcore/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/ridhzlabs/thermalcore/build.yml?branch=main&style=flat-square)](https://github.com/ridhzlabs/thermalcore/actions)
[![License](https://img.shields.io/github/license/ridhzlabs/thermalcore?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%2010%2B-3ddc84?style=flat-square)]()

**Universal thermal & power core for Android.** ThermalCore auto-detects your CPU clusters, GPU, thermal zones, storage and VM tunables, then applies safe, reversible profiles through a CLI, a live WebUI, or an AI thermal engine. No device-specific hardcoding, no framework, no kernel patches.

> Tested on a Redmi Note 14 Pro 5G (MediaTek MT6878) running a RealmeUI 7 port with KernelSU, but the module is built to work across Qualcomm, MediaTek, Exynos, Tensor and Unisoc platforms.

## Why ThermalCore

- **Universal by design.** CPU policies, GPU devfreq/KGSL nodes, thermal zones, schedulers and VM paths are discovered at runtime. Missing nodes are skipped, never forced.
- **Fast.** `status --json` went from **14.87s to ~0.42s** and hardware detection from **7.33s to ~0.38s** after replacing the fork-heavy hot paths with builtin shell reads. The WebUI refreshes almost instantly.
- **Safe.** Every apply takes an automatic snapshot first and rolls back on critical write failure. Uninstalling restores pre-install values.
- **Transparent.** Human-readable CLI, JSON output for automation, and a WebUI with live temps, frequencies, guard state and backups.

## Features

| Area | What it does |
| --- | --- |
| Auto-detection | CPU clusters, governors, available freqs, GPU node, thermal zones, storage, RAM, SoC and root manager |
| Profiles | `battery_saver`, `balanced`, `performance`, `gaming`, plus a fully editable `custom` profile |
| Custom tuning | CPU/GPU frequency caps, governors, I/O scheduler and read-ahead, VM tunables, sugov rate limits |
| Thermal guard | Watches battery temperature and caps CPU/GPU when the threshold is crossed, then restores the profile on cooldown |
| AI engine | Bundled `thermal-cored` daemon adapts to vendor thermal zones and learning props |
| WebUI | Live dashboard, one-tap profiles, guard controls, custom editor, backup/restore |
| Safety net | Auto snapshot before apply, rollback on failure, factory restore on uninstall, managed-path-only writes |
| Updates | `updateJson` enabled, so the KernelSU/APatch manager can check and install new releases directly |

## Profiles

| Profile | CPU | GPU | I/O | VM | Use case |
| --- | --- | --- | --- | --- | --- |
| `battery_saver` | smart governor, gentle 75% cap | smart, 60% cap | lean read-ahead | lean writeback, no boost churn | long standby, low charge |
| `balanced` | smart governor, gentle 95% cap | smart, 90% cap | lean read-ahead | lean writeback, no watermark boost | daily driver |
| `performance` | full clocks, boost churn trimmed | performance governor | low latency | latency-friendly | heavy apps |
| `gaming` | sustained high caps, boost churn trimmed | high caps + floor | low latency | responsiveness | long gaming sessions |
| `custom` | your values | your values | your values | your values | full control |

## Compatibility

- **Android:** 10+ (tested on Android 16), arm64.
- **Root managers:** KernelSU, APatch and MMRL for the full WebUI experience. Magisk can run the CLI/service side; its manager has no native webroot, so the WebUI is not available there.
- **Chipsets:** runtime sysfs detection. Validated on MT6878; generic fallbacks cover Qualcomm KGSL/devfreq, Exynos/Tensor devfreq and legacy Mali nodes.
- **Updates:** managers that read `updateJson` (KernelSU, APatch, MMRL) can update in place from the module page.

## Install

1. Download the latest `ThermalCore-<version>.zip` from [Releases](https://github.com/ridhzlabs/thermalcore/releases).
2. Open your root manager, go to **Modules**, choose **Install from storage**, and pick the zip.
3. Reboot.
4. Open the module in the manager and tap **WebUI** (KernelSU/APatch/MMRL).

Updating: use the manager's update button (powered by `update.json`), or flash a newer zip over the old one and reboot. Configuration and backups live in `/data/adb/thermal-core` and survive updates.

## Usage

```sh
thermalcore status                 # human-readable summary
thermalcore status --json          # machine-readable snapshot
thermalcore detect --refresh      # re-scan hardware
thermalcore profiles              # list profiles and mark the active one
thermalcore apply balanced        # snapshot + apply
thermalcore custom set GPU_MAX_FREQ_PCT 70
thermalcore custom setmany CPU_GOVERNOR=schedutil VM_SWAPPINESS=60
thermalcore guard start|status|stop
thermalcore backup [name]         # manual snapshot
thermalcore backups               # list snapshots
thermalcore restore [name]        # restore latest or a named snapshot
thermalcore restore --factory     # pre-install values
thermalcore doctor                # self-test
```

All commands are available from the WebUI and as JSON for automation.

## Performance

Measured on the test device (56 thermal zones, 2 CPU policies) before and after the 2.1.0 hot-path rewrite:

| Operation | 2.0.0 | 2.1.0 |
| --- | --- | --- |
| `status --json` | 14.87s | **0.42s** |
| `detect` | 7.33s | **0.38s** |
| `apply <profile>` | 3.6s | **1.2–2.0s** |
| `custom get all` | 0.11s | **0.06s** |

Root cause: this ROM's `/system/bin/sh` has no `printf` builtin, so every `printf` forked a ~17ms external process. Hot paths now use builtin `read`/`print`, in-process helpers, and fork-free zone/cluster/storage/GPU JSON emitters.

## Safety

- Only Linux-standard managed paths are touched (`cpufreq`, GPU devfreq/KGSL, VM sysctls, block queue). Vendor thermal trips are never written.
- A snapshot is taken before each apply; rollback triggers automatically on critical failure.
- Uninstall restores `install-initial` values and removes runtime data.
- The thermal guard caps frequencies and restores the previous profile after cooldown.

## Build

Requirements: Python 3 (stdlib only), Git.

```sh
python3 scripts/build_zip.py --out dist/ThermalCore-2.2.1.zip
```

The script packages exactly the module payload, sets executable modes, embeds the installer checksums and optionally overrides version metadata:

```sh
python3 scripts/build_zip.py --version 2.2.0 --version-code 4
```

## Tests

The offline mock suite builds a fake sysfs tree and exercises detection, profiles, guard, backup/restore, custom tuning and JSON output without touching the real kernel state:

```sh
su -c 'sh tests/mock_test.sh'
```

Expected: `70 passed, 0 failed`.

## CI/CD

- `Build` runs on every push/PR: shell and JS syntax checks, zip build, artifact upload.
- `Release` runs on `v*` tags: builds the versioned zip, extracts release notes from [CHANGELOG.md](CHANGELOG.md), publishes a GitHub release, then updates `update.json` so managers can update automatically.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes, or the [Releases](https://github.com/ridhzlabs/thermalcore/releases) page.

## License

Apache License 2.0. See [LICENSE](LICENSE).

## Credits

Built and maintained by [ridhzxlabs](https://github.com/ridhzlabs). Thanks to the KernelSU, APatch and MMRL projects for the module and WebUI infrastructure.
