# Changelog

## [v2.3.0] - 2026-11-14

### Material You WebUI
- Full Material 3 redesign: tonal surface palette (warm-orange seed), 24px rounded cards, pill navigation bar with animated indicator, M3 switches and sliders (vertical-bar handle), pill buttons and snackbar-style toasts.
- Profile-aware dynamic tint: the dashboard hero and profile cards adopt the color of the active profile (green battery saver, orange performance, red gaming...).
- Smoother and lighter at the same time: backdrop blur removed everywhere, all motion is transform/opacity only, subtle ripple feedback, reduced-motion respected.

### Notes
- Update in place from the manager or flash over 2.2.1, then reboot once.

## [v2.2.1] - 2026-11-13

### Dynamic module description badge
- The root manager (KernelSU / APatch / MMRL) now shows the **active profile** in the module description with an emoji badge: ✅ Balanced, 🔋 Battery Saver, 🚀 Performance, 🎮 Gaming, 🛠️ Custom - plus clock caps and daemon state.
- The badge updates automatically on every profile apply (manual, WebUI, post-boot restore and thermal-guard recovery) - no reboot needed, just refresh the module page.

### Notes
- Update in place from the manager or flash over 2.2.0, then reboot once.

## [v2.2.0] - 2026-11-09

### Battery efficiency pass
- `battery_saver`: vendor smart governors kept (no more `powersave` stutter), caps eased to 75% CPU / 60% GPU, 256 KB read-ahead, proactive compaction off and watermark boost disabled - endurance without lag or extra heat.
- `balanced`: gentle 95% CPU / 90% GPU caps, 256 KB read-ahead, lean writeback (dirty 20/5, vfs pressure 80) and watermark boost disabled - full-speed feel, lower drain.
- `performance` / `gaming`: full clocks, floors and low-latency I/O unchanged; only watermark boost churn is disabled, which trims background power for free.
- New tunable `VM_WATERMARK_BOOST_FACTOR` (0-1000000, -1 = keep) in `custom.conf` and the WebUI custom tab.
- Notifications, Doze, sync and wakelock behaviour are untouched - all changes are kernel sysfs only, so nothing heats up beyond normal caps.

### Notes
- Update in place from the manager or flash over 2.1.1, then reboot.

## [v2.1.1] - 2026-11-09

### Fixes
- WebUI bridge compatibility with KernelSU, KernelSU-Next, APatch and MMRL: async `exec` now receives a global callback name instead of a function object. This is the root cause of the false "Apply failed — rolled back / command timed out" dialog after ~25 seconds.
- Apply, backup, restore, custom profile and config actions receive their real exit code, stdout and stderr again instead of waiting forever for a callback that never ran.
- Separate timeout budgets: actions get 60s, status and log polling 30s. A real timeout is reported as a timeout and no longer claims the module rolled back.
- The WebUI recovers live telemetry instead of silently staying on demo values when the bridge is slow.

### Notes
- No kernel or thermal behaviour changed from 2.1.0; this is a WebUI reliability hotfix.
- Update in place from the manager or flash over 2.1.0, then reboot.

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
