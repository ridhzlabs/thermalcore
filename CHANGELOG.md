# Changelog

## [v2.1.0] - 2026-11-08

### Highlights
- Universal detection hardened for third-party ROMs and spoofed fingerprints: chipset/platform are read from real props and sysfs, not the build fingerprint.
- New module banner and description; version bumped to 2.1.0 (versionCode 3).
- Manager updates enabled through `updateJson`.

### Performance
- `status --json` reduced from 14.87s to ~0.42s and `detect` from 7.33s to ~0.38s.
- Profile apply reduced from ~3.6s to ~1.2–2.0s.
- Fork-free thermal zone, cluster, storage, GPU and VM JSON emitters; builtin reads and in-process config parsing replace per-value subprocesses.
- Root cause: this ROM's shell has no `printf` builtin, so every `printf` was a ~17ms external fork.

### Fixes
- 32-bit shell arithmetic overflow in percentage-based frequency math.
- Global variable clobbering in VM tuning and `custom setmany` argument handling.
- Scheduler parsing fallback when the selected value is not bracketed.
- Backup manifests now store and restore the active profile.
- Cleanup hook renamed so glob-based `service.d` runners execute it.

### Notes
- Flash over 2.0.0 and reboot. Runtime data in `/data/adb/thermal-core` is preserved.
- WebUI requires KernelSU, APatch or MMRL.

## [v2.0.0] - 2026-11-06

- First public release.
- Universal hardware detection: CPU clusters, GPU, thermal zones, storage, VM, SoC and root manager.
- Five profiles: battery saver, balanced, performance, gaming and custom.
- CLI with human-readable and JSON output.
- Live WebUI with dashboard, profile switching, guard controls and custom editor.
- Thermal guard with trigger, mitigation and cooldown recovery.
- Snapshot, restore and factory-restore safety model with automatic rollback.
- Bundled AI thermal engine daemon.
- Install, uninstall, boot and cleanup lifecycle scripts.
- 70-case offline mock test suite.
