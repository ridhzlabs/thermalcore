/* ============================================================
   ThermalCore WebUI — ridhzxlabs
   Talks to the module through the root WebUI bridge (ksu.exec).
   ============================================================ */
(function () {
  'use strict';

  var CLI = '/data/adb/modules/thermal-core/bin/thermalcore';
  var REFRESH_MS = 4000;

  var PROFILES = {
    battery_saver: {
      label: 'Battery Saver', tag: 'Maximum endurance',
      desc: 'Caps CPU and GPU clocks and biases the governor towards power saving. Built-in thermal protection stays untouched.',
      tags: ['cpu ≤66%', 'gpu ≤50%', 'powersave']
    },
    balanced: {
      label: 'Balanced', tag: 'Everyday default',
      desc: 'Vendor-optimal behaviour: full clocks restored, schedutil-family governor, no I/O or VM meddling.',
      tags: ['full clocks', 'schedutil', 'stock-like']
    },
    performance: {
      label: 'Performance', tag: 'Maximum responsiveness',
      desc: 'Performance governor, full CPU/GPU clocks, low-latency I/O scheduler and reduced swap tendency.',
      tags: ['performance', 'low latency', '100%']
    },
    gaming: {
      label: 'Gaming', tag: 'Sustained FPS',
      desc: 'Performance governor plus a raised GPU frequency floor for stable frame pacing, minimal I/O latency and no swap stutter.',
      tags: ['gpu floor 30%', 'kyber', 'low swap']
    },
    custom: {
      label: 'Custom', tag: 'Your own tuning',
      desc: 'Applies the values you configured in the Custom tab. Every value is validated and clamped to kernel capabilities.',
      tags: ['user defined', 'validated', 'safe']
    }
  };

  var ICONS = {
    battery_saver: '<svg viewBox="0 0 24 24"><rect x="2" y="7" width="17" height="10" rx="2.5"/><path d="M22 10.5v3"/><path d="M6.5 10.5v3M10 10.5v3"/></svg>',
    balanced: '<svg viewBox="0 0 24 24"><path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h9M17 17h3"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="15" cy="17" r="2"/></svg>',
    performance: '<svg viewBox="0 0 24 24"><path d="M13 2L4.5 13.5H11L9.8 22 19 10.5h-6.5L13 2z"/></svg>',
    gaming: '<svg viewBox="0 0 24 24"><path d="M7 8h10a5 5 0 0 1 4.9 6l-.7 3a3 3 0 0 1-5.1 1.5L14.5 17h-5l-1.6 1.5A3 3 0 0 1 2.8 17l-.7-3A5 5 0 0 1 7 8z"/><path d="M8 11.5v3M6.5 13h3M16.5 12h.01M18.5 14.5h.01"/></svg>',
    custom: '<svg viewBox="0 0 24 24"><path d="M14.7 6.3a4.5 4.5 0 0 0-6 6L3 18v3h3l5.7-5.7a4.5 4.5 0 0 0 6-6l-2.4 2.4-2.1-.3-.3-2.1 2.8-3z"/></svg>'
  };

  var CUSTOM_FIELDS = [
    ['c_cpu_gov', 'CPU_GOVERNOR', 'str'],
    ['c_cpu_max', 'CPU_MAX_FREQ_PCT', 'int'],
    ['c_cpu_min', 'CPU_MIN_FREQ_PCT', 'int'],
    ['c_gpu_gov', 'GPU_GOVERNOR', 'str'],
    ['c_gpu_max', 'GPU_MAX_FREQ_PCT', 'int'],
    ['c_gpu_min', 'GPU_MIN_FREQ_PCT', 'int'],
    ['c_io_sched', 'IO_SCHEDULER', 'str'],
    ['c_io_ra', 'IO_READ_AHEAD_KB', 'int'],
    ['c_vm_swap', 'VM_SWAPPINESS', 'int'],
    ['c_vm_vfs', 'VM_VFS_CACHE_PRESSURE', 'int'],
    ['c_vm_dirty', 'VM_DIRTY_RATIO', 'int'],
    ['c_vm_dirtybg', 'VM_DIRTY_BACKGROUND_RATIO', 'int'],
    ['c_vm_compact', 'VM_COMPACTION_PROACTIVENESS', 'int'],
    ['c_sugov_up', 'SUGOV_UP_RATE_LIMIT_US', 'int'],
    ['c_sugov_down', 'SUGOV_DOWN_RATE_LIMIT_US', 'int']
  ];

  var DEMO_STATUS = {
    module: {
      id: 'thermal-core', version: '2.1.0', profile: 'balanced', uptime_s: 90210,
      daemon: { pid: 4094, alive: true, learning: 'true', debug: 'false' },
      guard: { enabled: true, triggered: false, battery_max_c: 45, interval_s: 30, last_check: 0 },
      toggles: { cpu: true, gpu: true, io: true, vm: true },
      latest_backup: 'install-initial'
    },
    device: {
      model: 'Demo Device', device: 'demo', chipset: 'MT6878', platform: 'mt6878',
      android: '16', sdk: 36, kernel: '5.15.0-demo', root_manager: 'KernelSU',
      mem_total_mb: 7594, mem_avail_mb: 2660
    },
    battery: { temp_c: 39.0, status: 'Discharging', capacity: 40, current_ua: -460800, voltage_uv: 3782000, health: 'Good' },
    cpu: {
      usage_pct: 14.2,
      clusters: [
        { policy: '0', related: '0 1 2 3', governor: 'sugov_ext', cur_khz: 1200000, min_khz: 450000, max_khz: 1900000, cap_khz: 2000000, freq_pct: 60 },
        { policy: '4', related: '4 5 6 7', governor: 'sugov_ext', cur_khz: 1800000, min_khz: 400000, max_khz: 1800000, cap_khz: 2500000, freq_pct: 72 }
      ]
    },
    gpu: { name: '13000000.mali', governor: 'simple_ondemand', cur_hz: 531000000, min_hz: 265000000, max_hz: 1047000000, freq_pct: 51 },
    thermals: [
      { zone: 7, type: 'battery', temp_c: 39.0 },
      { zone: 32, type: 'gpu', temp_c: 46.6 },
      { zone: 8, type: 'soc_max', temp_c: 55.9 },
      { zone: 18, type: 'cpu-little-core1', temp_c: 50.0 },
      { zone: 10, type: 'cpu-big-core0-2', temp_c: 49.0 },
      { zone: 41, type: 'ap_ntc', temp_c: 42.4 }
    ],
    thermal_max_c: 55.9,
    thermal_max_type: 'soc_max',
    storage: [{ dev: 'sda', scheduler: 'cpq', read_ahead_kb: 128 }],
    vm: { swappiness: 100, vfs_cache_pressure: 80, dirty_ratio: 20, dirty_background_ratio: 5, compaction_proactiveness: 20 },
    timestamp: 0
  };

  var state = {
    demo: false,
    status: null,
    lastUpdate: 0,
    failCount: 0,
    customOrig: null,
    busy: false,
    refreshTimer: null,
    refreshing: false,
    activeTab: 'dashboard'
  };

  /* ---------------- tiny dom helpers ---------------- */
  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function el(id) { return document.getElementById(id); }
  function setText(id, text) { var n = el(id); if (n) n.textContent = text; }
  function setHTML(id, html) { var n = el(id); if (n) n.innerHTML = html; }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function isNum(v) { return typeof v === 'number' && isFinite(v); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------------- formatting ---------------- */
  function fmtTemp(v) { return isNum(v) ? v.toFixed(1) : '—'; }
  function fmtMHz(khz) {
    if (!isNum(khz) || khz <= 0) return '—';
    var mhz = khz / 1000;
    return mhz >= 1000 ? (mhz / 1000).toFixed(2) + ' GHz' : Math.round(mhz) + ' MHz';
  }
  function fmtHz(hz) {
    if (!isNum(hz) || hz <= 0) return '—';
    return Math.round(hz / 1e6) + ' MHz';
  }
  function fmtUptime(sec) {
    if (!isNum(sec) || sec < 0) return '—';
    var d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
    if (d > 0) return d + 'd ' + h + 'h';
    if (h > 0) return h + 'h ' + m + 'm';
    return m + 'm';
  }
  function fmtPower(b) {
    var p = Math.abs((b.voltage_uv || 0) * (b.current_ua || 0)) / 1e12;
    if (!isFinite(p) || p <= 0) return '';
    return p.toFixed(2) + ' W';
  }
  function profileLabel(name) { return (PROFILES[name] && PROFILES[name].label) || name || '—'; }
  function profileDesc(name) { return (PROFILES[name] && PROFILES[name].desc) || ''; }

  /* ---------------- root bridge ---------------- */
  function bridgeFn() {
    if (window.ksu && typeof window.ksu.exec === 'function') return window.ksu.exec.bind(window.ksu);
    if (typeof window.exec === 'function') return window.exec.bind(window);
    return null;
  }
  function hasBridge() { return !!bridgeFn(); }

  function normalizeResult(r) {
    if (r == null) return { code: 0, stdout: '', stderr: '' };
    if (typeof r === 'string') return { code: 0, stdout: r, stderr: '' };
    var code = r.errno;
    if (code === undefined || code === null) code = r.code;
    if (code === undefined || code === null) code = r.exitCode;
    if (code === undefined || code === null) code = r.exit_code;
    return {
      code: Number(code) || 0,
      stdout: String(r.stdout == null ? '' : r.stdout),
      stderr: String(r.stderr == null ? '' : r.stderr)
    };
  }

  function bridgeExec(cmd) {
    return new Promise(function (resolve, reject) {
      var fn = bridgeFn();
      if (!fn) return reject(new Error('WebUI bridge not available'));
      var settled = false;
      var timer = setTimeout(function () {
        if (!settled) { settled = true; reject(new Error('command timed out')); }
      }, 25000);
      function done(r) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(normalizeResult(r));
      }
      try {
        var maybe = fn(cmd, function (a, b, c) {
          if (a !== null && typeof a === 'object') return done(a);
          done({ errno: a, stdout: b, stderr: c });
        });
        if (maybe && typeof maybe.then === 'function') {
          maybe.then(done, function (e) {
            if (!settled) { settled = true; clearTimeout(timer); reject(e); }
          });
        } else if (typeof maybe === 'string') {
          done({ errno: 0, stdout: maybe, stderr: '' });
        } else if (maybe && typeof maybe === 'object') {
          done(maybe);
        }
      } catch (e) {
        if (!settled) { settled = true; clearTimeout(timer); reject(e); }
      }
    });
  }

  function shq(v) {
    return "'" + String(v == null ? '' : v).replace(/'/g, "'\\''") + "'";
  }

  function runCli(args) {
    if (state.demo) return Promise.resolve({ ok: false, code: -2, out: '', err: 'preview mode' });
    return bridgeExec(CLI + ' ' + args).then(function (r) {
      return { ok: r.code === 0, code: r.code, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
    }).catch(function (e) {
      return { ok: false, code: -1, out: '', err: String((e && e.message) || e) };
    });
  }

  /* ---------------- toast / modal ---------------- */
  function toast(msg, kind, ms) {
    var wrap = el('toastWrap');
    var t = document.createElement('div');
    t.className = 'toast' + (kind ? ' ' + kind : '');
    t.textContent = msg;
    wrap.appendChild(t);
    setTimeout(function () {
      t.classList.add('out');
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 220);
    }, ms || 3400);
  }

  var modalResolve = null;
  function openModal(opts) {
    el('modalTitle').textContent = opts.title || 'Confirm';
    el('modalBody').textContent = opts.body || '';
    var pre = el('modalPre');
    if (opts.pre) { pre.textContent = opts.pre; pre.classList.remove('hidden'); }
    else { pre.textContent = ''; pre.classList.add('hidden'); }
    el('modalOk').textContent = opts.okText || 'Confirm';
    el('modalOk').className = 'btn ' + (opts.danger ? 'btn-danger-ghost' : 'btn-primary');
    el('modalCancel').textContent = opts.cancelText || 'Cancel';
    el('modalCancel').classList.toggle('hidden', !!opts.hideCancel);
    el('modal').classList.remove('hidden');
    return new Promise(function (resolve) {
      modalResolve = resolve;
    });
  }
  function closeModal(result) {
    el('modal').classList.add('hidden');
    if (modalResolve) { var r = modalResolve; modalResolve = null; r(result); }
  }
  function confirmDialog(title, body, okText, danger) {
    return openModal({ title: title, body: body, okText: okText || 'Confirm', danger: danger });
  }
  function errorDialog(title, res) {
    var detail = [res && res.out, res && res.err].filter(Boolean).join('\n');
    return openModal({
      title: title,
      body: 'No changes were kept. Details below:',
      pre: detail || 'unknown error',
      okText: 'Close',
      hideCancel: true
    });
  }

  /* ---------------- tabs ---------------- */
  function switchTab(name) {
    if (!name || !el('tab-' + name)) name = 'dashboard';
    state.activeTab = name;
    $$('.tab').forEach(function (b) { b.classList.toggle('active', b.dataset.tab === name); });
    $$('.tab-panel').forEach(function (p) { p.classList.toggle('active', p.id === 'tab-' + name); });
    try { history.replaceState(null, '', '#' + name); } catch (e) { /* ignore */ }
    window.scrollTo(0, 0);
    if (name === 'custom') loadCustom();
    if (name === 'advanced') { refreshLog(); }
    if (name === 'settings' || name === 'dashboard') render(state.status);
  }

  /* ---------------- rendering ---------------- */
  function render(s) {
    if (!s) return;
    var mod = s.module || {};
    var dev = s.device || {};
    var bat = s.battery || {};
    var gpu = s.gpu || {};
    var cpu = s.cpu || {};

    setText('versionChip', 'v' + (mod.version || '2.1.0'));
    el('versionChip').textContent = 'v' + (mod.version || '2.1.0');
    setText('aboutVersion', mod.version || '2.1.0');
    setText('footerUpdate', state.demo ? 'preview' : ('updated ' + new Date().toLocaleTimeString()));

    var profile = mod.profile || 'balanced';
    setText('profileBadge', profileLabel(profile));
    setText('profileName', profileLabel(profile));
    setText('profileDesc', profileDesc(profile));

    /* battery */
    var bt = isNum(bat.temp_c) ? bat.temp_c : 0;
    setText('batteryTemp', fmtTemp(bt));
    var bMeter = el('batteryMeter');
    bMeter.style.width = clamp(bt / 60 * 100, 2, 100) + '%';
    bMeter.className = 'meter-fill ' + (bt >= 45 ? 'hot' : bt >= 40 ? 'warm' : 'cool');
    var bdot = el('batteryDot');
    bdot.className = 'dot ' + (bt >= 45 ? 'err' : bt >= 40 ? 'warn' : 'ok');
    var power = fmtPower(bat);
    setText('batteryFoot', [
      bat.status || '—',
      isNum(bat.capacity) ? bat.capacity + '%' : null,
      power || null
    ].filter(Boolean).join(' · '));

    /* thermal */
    var tmax = isNum(s.thermal_max_c) ? s.thermal_max_c : 0;
    setText('thermalMax', fmtTemp(tmax));
    var tMeter = el('thermalMeter');
    tMeter.style.width = clamp(tmax / 90 * 100, 2, 100) + '%';
    tMeter.className = 'meter-fill ' + (tmax >= 65 ? 'hot' : tmax >= 50 ? 'warm' : 'cool');
    el('thermalDot').className = 'dot ' + (tmax >= 65 ? 'err' : tmax >= 50 ? 'warn' : 'ok');
    setText('thermalFoot', (s.thermal_max_type && s.thermal_max_type !== 'n/a')
      ? s.thermal_max_type + ' · ' + (s.thermals || []).length + ' sensors'
      : (s.thermals || []).length + ' sensors');

    /* daemon */
    var dm = mod.daemon || {};
    setText('daemonState', dm.alive ? 'Running' : 'Stopped');
    el('daemonDot').className = 'dot ' + (dm.alive ? 'ok' : 'err');
    setText('daemonFoot', dm.alive ? ('PID ' + (dm.pid || '—') + ' · learning ' + (dm.learning === 'true' || dm.learning === '1' ? 'on' : 'off')) : 'daemon not running');
    var guard = mod.guard || {};
    setText('daemonMeta', 'guard ' + (guard.enabled ? 'active' : 'off') + (guard.triggered ? ' · OVERHEAT MITIGATION' : ''));

    /* cpu */
    setText('cpuUsage', isNum(cpu.usage_pct) && cpu.usage_pct >= 0 ? 'usage ' + cpu.usage_pct.toFixed(1) + '%' : 'usage —');
    var clusters = cpu.clusters || [];
    var chtml = clusters.map(function (c) {
      var pct = isNum(c.freq_pct) ? c.freq_pct : 0;
      return '<div class="cluster">' +
        '<div><div class="cluster-title">Cluster ' + esc(c.policy) +
        '<small>CPU ' + esc(c.related || '?') + '</small></div>' +
        '<span class="cluster-gov">' + esc(c.governor || '—') + '</span></div>' +
        '<div class="cluster-right">' + fmtMHz(c.cur_khz) + '<br><span class="muted">max ' + fmtMHz(c.max_khz) + '</span></div>' +
        '<div class="meter"><div class="meter-fill power" style="width:' + clamp(pct, 1, 100) + '%"></div></div>' +
        '</div>';
    }).join('');
    setHTML('clusterList', chtml || '<span class="hint">No cpufreq policies detected.</span>');

    /* gpu */
    setText('gpuFreq', isNum(gpu.cur_hz) ? Math.round(gpu.cur_hz / 1e6) : '—');
    setText('gpuGovernor', gpu.governor || '—');
    var gpct = isNum(gpu.freq_pct) ? gpu.freq_pct : 0;
    var gMeter = el('gpuMeter');
    gMeter.style.width = clamp(gpct, 1, 100) + '%';
    setText('gpuMeta', (gpu.name ? gpu.name + ' · ' : '') + 'max ' + fmtHz(gpu.max_hz));

    /* zones */
    var zones = (s.thermals || []).slice().sort(function (a, b) { return (b.temp_c || 0) - (a.temp_c || 0); });
    if (zones.length) {
      setHTML('zoneList', zones.slice(0, 24).map(function (z) {
        var cls = z.temp_c >= 65 ? ' zone hot' : z.temp_c >= 50 ? ' zone warm' : ' zone';
        return '<span class="zone' + cls + '">' + esc(z.type || ('zone ' + z.zone)) +
          ' <b>' + fmtTemp(z.temp_c) + '°</b></span>';
      }).join(''));
    } else {
      setHTML('zoneList', '<span class="hint">No readable thermal sensors.</span>');
    }

    /* device */
    var memA = isNum(dev.mem_avail_mb) ? (dev.mem_avail_mb / 1024).toFixed(1) : '—';
    var memT = isNum(dev.mem_total_mb) ? (dev.mem_total_mb / 1024).toFixed(1) : '—';
    setText('rootManagerChip', dev.root_manager || 'Unknown');
    el('deviceGrid').innerHTML = [
      ['Model', dev.model],
      ['Device', dev.device],
      ['Chipset', dev.chipset],
      ['Platform', dev.platform],
      ['Android', (dev.android || '—') + (dev.sdk ? ' (API ' + dev.sdk + ')' : '')],
      ['Kernel', dev.kernel],
      ['Root manager', dev.root_manager],
      ['RAM', memA + ' / ' + memT + ' GB'],
      ['Uptime', fmtUptime(mod.uptime_s)]
    ].map(function (row) {
      return '<div><span>' + esc(row[0]) + '</span><b>' + esc(row[1] || '—') + '</b></div>';
    }).join('');

    /* active profile cards */
    $$('.profile-card').forEach(function (card) {
      var name = card.getAttribute('data-profile');
      card.classList.toggle('active', name === profile);
      var badge = card.querySelector('.pc-active');
      if (badge) badge.classList.toggle('hidden', name !== profile);
    });

    /* settings + toggles reflect config */
    var tg = mod.toggles || {};
    setChecked('s_cpu', tg.cpu !== false);
    setChecked('s_gpu', tg.gpu !== false);
    setChecked('s_io', tg.io !== false);
    setChecked('s_vm', tg.vm !== false);
    setChecked('s_guard', guard.enabled !== false);
    setChecked('quickGuard', guard.enabled !== false);
    setChecked('s_learning', dm.learning === 'true' || dm.learning === '1');
    setChecked('quickLearning', dm.learning === 'true' || dm.learning === '1');
    setChecked('s_debug', dm.debug === '1' || dm.debug === 'true');
    var gmax = isNum(guard.battery_max_c) ? guard.battery_max_c : 45;
    var gslider = el('s_guard_max');
    if (gslider && document.activeElement !== gslider) gslider.value = gmax;
    setText('s_guard_max_val', gmax + '°C');
    paintRange(gslider);
    var gint = el('s_guard_interval');
    if (gint && document.activeElement !== gint) {
      var iv = String(guard.interval_s || 30);
      if (!gint.querySelector('option[value="' + iv + '"]')) {
        var o = document.createElement('option');
        o.value = iv; o.textContent = iv + ' s';
        gint.appendChild(o);
      }
      gint.value = iv;
    }
    setText('latestBackup', mod.latest_backup && mod.latest_backup !== 'none' ? 'latest: ' + mod.latest_backup : 'no backup yet');
    if (el('daemonVersion')) setText('daemonVersion', mod.daemon && mod.daemon.alive ? 'AI online' : 'AI offline');
  }

  function setChecked(id, v) { var n = el(id); if (n) n.checked = !!v; }

  function paintRange(node) {
    if (!node) return;
    var min = Number(node.min || 0), max = Number(node.max || 100), v = Number(node.value);
    var pct = max === min ? 0 : ((v - min) / (max - min)) * 100;
    node.style.setProperty('--fill', pct + '%');
  }

  /* ---------------- status refresh ---------------- */
  function setBridgePill(kind, text) {
    var p = el('bridgePill');
    p.className = 'pill ' + kind;
    p.textContent = text;
  }

  function refresh(force) {
    if (state.demo) { render(state.status || DEMO_STATUS); return Promise.resolve(); }
    if (state.refreshing) return Promise.resolve();
    if (state.busy && !force) return Promise.resolve();
    if (document.hidden && !force) return Promise.resolve();
    state.refreshing = true;
    return runCli('status --json').then(function (res) {
      state.refreshing = false;
      if (!res.ok) return statusFailed(res);
      var data;
      try { data = JSON.parse(res.out); }
      catch (e) { return statusFailed({ out: res.out, err: 'invalid JSON from module' }); }
      state.status = data;
      state.failCount = 0;
      state.lastUpdate = Date.now();
      el('statusError').classList.add('hidden');
      setBridgePill('pill-ok', 'live');
      render(data);
    });
  }

  function statusFailed(res) {
    state.failCount++;
    if (state.failCount >= 2) {
      el('statusError').classList.remove('hidden');
      setText('statusErrorText', (res && (res.err || res.out)) || 'unknown error');
      setBridgePill('pill-err', 'disconnected');
    }
    if (!state.status) render(DEMO_STATUS);
  }

  /* ---------------- actions ---------------- */
  function busyBtn(btn, on) {
    if (!btn) return;
    if (on) btn.classList.add('loading');
    else btn.classList.remove('loading');
    btn.disabled = !!on;
  }

  function doApply(name, btn) {
    if (state.demo) return toast('Preview mode — open via the root manager WebUI to apply.', 'warn');
    if (state.busy) return;
    state.busy = true;
    busyBtn(btn, true);
    runCli('apply ' + shq(name)).then(function (res) {
      state.busy = false;
      busyBtn(btn, false);
      if (res.ok) {
        toast('Applied: ' + profileLabel(name), 'ok');
        refresh(true);
      } else {
        errorDialog('Apply failed — rolled back', res);
      }
    });
  }

  function setConfig(key, value, opts) {
    opts = opts || {};
    if (state.demo) { toast('Preview mode — no changes written.', 'warn'); return Promise.resolve(false); }
    return runCli('config set ' + key + ' ' + shq(value)).then(function (res) {
      if (!res.ok) { errorDialog('Config update failed', res); return false; }
      toast(opts.toast || (key + ' = ' + value), 'ok');
      if (opts.guard) {
        return runCli('guard ' + (value === '1' || value === 'true' ? 'start' : 'stop')).then(function () {
          refresh(true);
          return true;
        });
      }
      refresh(true);
      return true;
    });
  }

  function bindToggle(id, key, opts) {
    var n = el(id);
    if (!n) return;
    n.addEventListener('change', function () {
      setConfig(key, n.checked ? '1' : '0', opts);
    });
  }

  function doResetConfig(btn) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    confirmDialog('Reset configuration?',
      'This resets the active profile, all toggles and the custom profile to defaults.\nKernel values are NOT touched.',
      'Reset', true
    ).then(function (ok) {
      if (!ok) return;
      busyBtn(btn, true);
      runCli('reset-config').then(function (res) {
        busyBtn(btn, false);
        if (!res.ok) return errorDialog('Reset failed', res);
        toast('Configuration reset to defaults', 'ok');
        loadCustom();
        refresh(true);
      });
    });
  }

  /* ---------------- custom profile ---------------- */
  function setRangeLabel(id, text) { setText(id, text); }

  function percentLabel(v) {
    if (v === -1) return 'keep';
    return v + '%';
  }
  function floorLabel(v) {
    if (v === -1) return 'keep';
    if (v === 0) return 'lowest';
    return v + '%';
  }

  function syncCustomLabels() {
    var cpuMax = el('c_cpu_max'), cpuMin = el('c_cpu_min'),
      gpuMax = el('c_gpu_max'), gpuMin = el('c_gpu_min');
    setRangeLabel('c_cpu_max_val', percentLabel(Number(cpuMax.value)));
    setRangeLabel('c_cpu_min_val', floorLabel(Number(cpuMin.value)));
    setRangeLabel('c_gpu_max_val', percentLabel(Number(gpuMax.value)));
    setRangeLabel('c_gpu_min_val', floorLabel(Number(gpuMin.value)));
    [cpuMax, cpuMin, gpuMax, gpuMin].forEach(paintRange);
  }

  function loadCustom() {
    if (state.demo) { populateCustom(state.customOrig || {}); return Promise.resolve(); }
    return runCli('custom get all').then(function (res) {
      if (!res.ok) { toast('Could not read custom profile: ' + (res.err || res.out), 'err'); return; }
      var map = {};
      res.out.split(/\r?\n/).forEach(function (line) {
        if (!line || line.charAt(0) === '#' || line.indexOf('=') < 0) return;
        var i = line.indexOf('=');
        map[line.slice(0, i).trim()] = line.slice(i + 1).trim();
      });
      state.customOrig = map;
      populateCustom(map);
    });
  }

  function populateCustom(map) {
    CUSTOM_FIELDS.forEach(function (f) {
      var node = el(f[0]);
      if (!node) return;
      var v = map[f[1]];
      if (v === undefined) return;
      if (f[2] === 'str') {
        if (node.tagName === 'SELECT') {
          var found = false;
          Array.prototype.forEach.call(node.options, function (o) { if (o.value === v) found = true; });
          if (!found && v !== '') {
            var opt = document.createElement('option');
            opt.value = v; opt.textContent = v;
            node.appendChild(opt);
          }
        }
        node.value = v;
      } else {
        node.value = v;
      }
    });
    syncCustomLabels();
    $$('#customForm .invalid').forEach(function (n) { n.classList.remove('invalid'); });
  }

  function collectCustom() {
    var out = {}, bad = [];
    CUSTOM_FIELDS.forEach(function (f) {
      var node = el(f[0]);
      if (!node) return;
      var v = String(node.value == null ? '' : node.value).trim();
      node.classList.remove('invalid');
      if (f[2] === 'int') {
        if (v === '') v = '-1';
        if (!/^-?\d+$/.test(v)) { bad.push(f[0]); node.classList.add('invalid'); return; }
      }
      out[f[1]] = v;
    });
    return { values: out, bad: bad };
  }

  function saveCustom(applyAfter, btn) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    if (!state.customOrig) {
      toast('Custom profile not loaded yet — retrying…', 'warn');
      return loadCustom();
    }
    var c = collectCustom();
    if (c.bad.length) return toast('Invalid number in: ' + c.bad.join(', '), 'err');
    var orig = state.customOrig || {};
    var changed = [];
    Object.keys(c.values).forEach(function (k) {
      var old = orig[k] === undefined ? null : String(orig[k]);
      if (old === null || old !== c.values[k]) changed.push(k + '=' + c.values[k]);
    });
    if (!changed.length && !applyAfter) return toast('No changes to save', 'warn');

    busyBtn(btn, true);
    var save = changed.length
      ? runCli('custom setmany ' + changed.map(shq).join(' '))
      : Promise.resolve({ ok: true, out: '', err: '' });

    save.then(function (res) {
      if (!res.ok) { busyBtn(btn, false); return errorDialog('Saving custom profile failed', res); }
      if (applyAfter) {
        return runCli('apply custom').then(function (ares) {
          busyBtn(btn, false);
          if (!ares.ok) return errorDialog('Custom profile apply failed — rolled back', ares);
          toast('Custom profile saved & applied', 'ok');
          loadCustom(); refresh(true);
        });
      }
      busyBtn(btn, false);
      toast(changed.length ? 'Custom profile saved' : 'No changes', 'ok');
      loadCustom(); refresh(true);
    });
  }

  /* ---------------- advanced ---------------- */
  function refreshLog() {
    if (state.demo) { el('logView').textContent = 'Preview mode — log unavailable.'; return; }
    runCli('log 100').then(function (res) {
      el('logView').textContent = res.ok ? (res.out || '(empty log)') : ('error: ' + (res.err || res.out));
      el('logView').scrollTop = el('logView').scrollHeight;
    });
  }

  function doBackup(btn) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    busyBtn(btn, true);
    runCli('backup').then(function (res) {
      busyBtn(btn, false);
      if (!res.ok) return errorDialog('Backup failed', res);
      toast(res.out || 'Backup created', 'ok');
      refresh(true);
    });
  }

  function doRestore(kind, btn) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    var title = kind === 'factory' ? 'Restore factory (pre-install) values?' : 'Restore latest backup?';
    var body = kind === 'factory'
      ? 'Rewrites every managed kernel node to the state captured at install time. Use this to fully undo ThermalCore tuning.'
      : 'Rewrites every managed kernel node to the most recent snapshot.';
    confirmDialog(title, body, kind === 'factory' ? 'Restore factory' : 'Restore', true).then(function (ok) {
      if (!ok) return;
      busyBtn(btn, true);
      runCli(kind === 'factory' ? 'restore --factory' : 'restore').then(function (res) {
        busyBtn(btn, false);
        if (!res.ok) return errorDialog('Restore failed', res);
        toast('Restore completed', 'ok');
        refresh(true);
      });
    });
  }

  function doRestartDaemon(btn) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    busyBtn(btn, true);
    runCli('daemon restart').then(function (res) {
      busyBtn(btn, false);
      if (!res.ok) return errorDialog('Daemon restart failed', res);
      toast('ThermalCore AI daemon restarted', 'ok');
      refresh(true);
    });
  }

  function doSetProp(key, value, label) {
    if (state.demo) return toast('Preview mode — no changes written.', 'warn');
    return bridgeExec('setprop ' + shq(key) + ' ' + shq(value)).then(function (r) {
      if (r.code !== 0) return errorDialog('Setting property failed', { out: r.stdout, err: r.stderr });
      toast(label + ' — restart the AI daemon to take effect', 'ok');
      refresh(true);
    }).catch(function (e) {
      errorDialog('Setting property failed', { err: String(e) });
    });
  }

  /* ---------------- build profile cards ---------------- */
  function buildProfiles() {
    var order = ['battery_saver', 'balanced', 'performance', 'gaming', 'custom'];
    el('profileGrid').innerHTML = order.map(function (name) {
      var p = PROFILES[name];
      return '<article class="profile-card profile-card--' + name + '" data-profile="' + name + '">' +
        '<div class="pc-top">' +
        '<div class="pc-icon">' + ICONS[name] + '</div>' +
        '<div><div class="pc-title">' + esc(p.label) +
        ' <span class="badge badge-accent pc-active hidden">active</span></div>' +
        '<div class="pc-tag">' + esc(p.tag) + '</div></div></div>' +
        '<p class="pc-desc">' + esc(p.desc) + '</p>' +
        '<div class="pc-meta">' + p.tags.map(function (t) { return '<span>' + esc(t) + '</span>'; }).join('') + '</div>' +
        '<div class="pc-actions">' +
        '<button class="btn btn-primary btn-sm" type="button" data-apply="' + name + '">Apply</button>' +
        (name === 'custom'
          ? '<button class="btn btn-ghost btn-sm" type="button" data-edit="custom">Edit values</button>'
          : '') +
        '</div></article>';
    }).join('');

    $$('[data-apply]', el('profileGrid')).forEach(function (btn) {
      btn.addEventListener('click', function () { doApply(btn.getAttribute('data-apply'), btn); });
    });
    $$('[data-edit]', el('profileGrid')).forEach(function (btn) {
      btn.addEventListener('click', function () { switchTab('custom'); });
    });
  }

  /* ---------------- bindings ---------------- */
  function bind() {
    $$('.tab').forEach(function (b) {
      b.addEventListener('click', function () { switchTab(b.dataset.tab); });
    });
    el('gotoProfiles').addEventListener('click', function () { switchTab('profiles'); });
    $$('[data-quick-profile]').forEach(function (b) {
      b.addEventListener('click', function () { doApply(b.getAttribute('data-quick-profile'), b); });
    });
    el('bridgePill').addEventListener('click', function () { refresh(true); });

    bindToggle('s_cpu', 'ENABLE_CPU_TWEAKS');
    bindToggle('s_gpu', 'ENABLE_GPU_TWEAKS');
    bindToggle('s_io', 'ENABLE_IO_TWEAKS');
    bindToggle('s_vm', 'ENABLE_VM_TWEAKS');
    bindToggle('s_guard', 'ENABLE_THERMAL_GUARD', { guard: true, toast: 'Thermal guard updated' });
    bindToggle('quickGuard', 'ENABLE_THERMAL_GUARD', { guard: true, toast: 'Thermal guard updated' });

    el('quickGuard').addEventListener('change', function () { el('s_guard').checked = el('quickGuard').checked; });
    el('s_guard').addEventListener('change', function () { el('quickGuard').checked = el('s_guard').checked; });

    var gs = el('s_guard_max');
    gs.addEventListener('input', function () { setText('s_guard_max_val', gs.value + '°C'); paintRange(gs); });
    gs.addEventListener('change', function () {
      var v = parseInt(gs.value, 10) || 45;
      var rec = clamp(v - 3, 30, 55);
      setConfig('THERMAL_GUARD_BATTERY_MAX_C', v, { toast: 'Guard threshold: ' + v + '°C (recover at ' + rec + '°C)' })
        .then(function (ok) { if (ok) runCli('config set THERMAL_GUARD_RECOVER_C ' + shq(rec)); });
    });

    el('s_guard_interval').addEventListener('change', function () {
      setConfig('THERMAL_GUARD_INTERVAL', el('s_guard_interval').value, { toast: 'Guard interval updated' });
    });

    el('s_learning').addEventListener('change', function () {
      doSetProp('persist.sys.rianixia.learning_enabled', el('s_learning').checked ? 'true' : 'false', 'Learning ' + (el('s_learning').checked ? 'enabled' : 'disabled'));
      el('quickLearning').checked = el('s_learning').checked;
    });
    el('quickLearning').addEventListener('change', function () {
      el('s_learning').checked = el('quickLearning').checked;
      doSetProp('persist.sys.rianixia.learning_enabled', el('quickLearning').checked ? 'true' : 'false', 'Learning ' + (el('quickLearning').checked ? 'enabled' : 'disabled'));
    });
    el('s_debug').addEventListener('change', function () {
      doSetProp('persist.sys.rianixia.thermalcore-debug', el('s_debug').checked ? '1' : '0', 'Debug logging ' + (el('s_debug').checked ? 'enabled' : 'disabled'));
    });
    el('restartDaemon').addEventListener('click', function () { doRestartDaemon(el('restartDaemon')); });
    el('quickRestartDaemon').addEventListener('click', function () { doRestartDaemon(el('quickRestartDaemon')); });

    /* custom form */
    ['c_cpu_max', 'c_cpu_min', 'c_gpu_max', 'c_gpu_min'].forEach(function (id) {
      el(id).addEventListener('input', syncCustomLabels);
    });
    el('customApply').addEventListener('click', function () { saveCustom(true, el('customApply')); });
    el('customSave').addEventListener('click', function () { saveCustom(false, el('customSave')); });
    el('customReload').addEventListener('click', function () { loadCustom(); toast('Reloaded saved values', 'ok'); });
    el('customDefaults').addEventListener('click', function () {
      if (state.demo) return toast('Preview mode — no changes written.', 'warn');
      confirmDialog('Restore custom defaults?', 'Resets only the custom profile template. Does not change the active profile or kernel values.', 'Restore defaults', true)
        .then(function (ok) {
          if (!ok) return;
          runCli('reset-custom').then(function (res) {
            if (!res.ok) return errorDialog('Reset custom failed', res);
            toast('Custom profile reset', 'ok');
            loadCustom();
          });
        });
    });

    /* reset config */
    el('resetConfigBtn').addEventListener('click', function () { doResetConfig(el('resetConfigBtn')); });

    /* advanced */
    el('backupNow').addEventListener('click', function () { doBackup(el('backupNow')); });
    el('restoreLatest').addEventListener('click', function () { doRestore('latest', el('restoreLatest')); });
    el('restoreFactory').addEventListener('click', function () { doRestore('factory', el('restoreFactory')); });
    el('logRefresh').addEventListener('click', refreshLog);
    el('logClear').addEventListener('click', function () {
      if (state.demo) return toast('Preview mode — no changes written.', 'warn');
      confirmDialog('Clear module log?', 'Deletes the ThermalCore log file contents. This cannot be undone.', 'Clear log', true)
        .then(function (ok) {
          if (!ok) return;
          runCli('log clear').then(function (res) {
            if (!res.ok) return errorDialog('Clear log failed', res);
            toast('Log cleared', 'ok');
            refreshLog();
          });
        });
    });

    /* modal */
    el('modalCancel').addEventListener('click', function () { closeModal(false); });
    el('modalOk').addEventListener('click', function () { closeModal(true); });
    el('modal').addEventListener('click', function (e) { if (e.target === el('modal')) closeModal(false); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeModal(false); });

    document.addEventListener('visibilitychange', function () { if (!document.hidden) refresh(true); });

    window.addEventListener('hashchange', function () { switchTab(location.hash.slice(1)); });
  }

  /* ---------------- init ---------------- */
  function init() {
    buildProfiles();
    bind();

    var initialTab = location.hash ? location.hash.slice(1) : 'dashboard';
    switchTab(initialTab);
    syncCustomLabels();

    if (!hasBridge()) {
      state.demo = true;
      state.status = DEMO_STATUS;
      el('demoBanner').classList.remove('hidden');
      setBridgePill('pill-warn', 'preview');
      render(DEMO_STATUS);
      state.customOrig = {
        CPU_GOVERNOR: 'schedutil', CPU_MAX_FREQ_PCT: '100', CPU_MIN_FREQ_PCT: '-1',
        GPU_GOVERNOR: 'simple_ondemand', GPU_MAX_FREQ_PCT: '100', GPU_MIN_FREQ_PCT: '-1',
        IO_SCHEDULER: 'auto', IO_READ_AHEAD_KB: '256', VM_SWAPPINESS: '-1',
        VM_VFS_CACHE_PRESSURE: '-1', VM_DIRTY_RATIO: '-1', VM_DIRTY_BACKGROUND_RATIO: '-1',
        VM_COMPACTION_PROACTIVENESS: '-1', SUGOV_UP_RATE_LIMIT_US: '-1', SUGOV_DOWN_RATE_LIMIT_US: '-1'
      };
      populateCustom({
        CPU_GOVERNOR: 'schedutil', CPU_MAX_FREQ_PCT: '100', CPU_MIN_FREQ_PCT: '-1',
        GPU_GOVERNOR: 'simple_ondemand', GPU_MAX_FREQ_PCT: '100', GPU_MIN_FREQ_PCT: '-1',
        IO_SCHEDULER: 'auto', IO_READ_AHEAD_KB: '256', VM_SWAPPINESS: '-1',
        VM_VFS_CACHE_PRESSURE: '-1', VM_DIRTY_RATIO: '-1', VM_DIRTY_BACKGROUND_RATIO: '-1',
        VM_COMPACTION_PROACTIVENESS: '-1', SUGOV_UP_RATE_LIMIT_US: '-1', SUGOV_DOWN_RATE_LIMIT_US: '-1'
      });
      return;
    }

    setBridgePill('pill-ok', 'live');
    refresh(true);
    state.refreshTimer = setInterval(function () {
      if (!document.hidden && !state.busy) refresh(false);
    }, REFRESH_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
