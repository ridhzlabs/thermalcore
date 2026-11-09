'use strict';

/*
 * Regression test for the WebUI bridge.
 *
 * KernelSU / KernelSU-Next / APatch / MMRL pass the async callback as the
 * *name* of a global function. Passing a function object silently breaks the
 * callback and produced the false "command timed out" dialog.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const app = fs.readFileSync(path.join(__dirname, '..', 'webroot', 'js', 'app.js'), 'utf8');
const match = app.match(/\/\* bridge-core:start \*\/([\s\S]*?)\/\* bridge-core:end \*\//);
assert(match, 'bridge-core markers not found in app.js');

function makeBridge(bridgeImpl) {
  const windowObj = {};
  const sandbox = {
    window: windowObj,
    bridgeFn: function () { return bridgeImpl; },
    setTimeout: setTimeout,
    clearTimeout: clearTimeout,
    console: console,
    Promise: Promise,
    Number: Number,
    String: String,
    Error: Error
  };
  vm.createContext(sandbox);
  vm.runInContext(match[1], sandbox, { filename: 'bridge-core.js' });
  assert.strictEqual(typeof sandbox.bridgeExec, 'function', 'bridgeExec missing');
  return { exec: sandbox.bridgeExec, window: windowObj };
}

function pendingCallbackKeys(windowObj) {
  return Object.keys(windowObj).filter(function (k) {
    return k.indexOf('__thermalcore_cb_') === 0;
  });
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('passes a global callback name, not a function', async function () {
  let seen;
  const ctx = makeBridge(function (cmd, cb) {
    seen = cb;
    setTimeout(function () { ctx.window[cb](0, 'hello', ''); }, 5);
    return null;
  });
  const result = await ctx.exec('echo hello', 1000);
  assert.strictEqual(typeof seen, 'string', 'callback must be a string name');
  assert.ok(/^[A-Za-z_$][\w$]*$/.test(seen), 'callback name must be a valid identifier');
  assert.strictEqual(result.code, 0);
  assert.strictEqual(result.stdout, 'hello');
  assert.strictEqual(result.stderr, '');
  assert.deepStrictEqual(pendingCallbackKeys(ctx.window), [], 'callback should be cleaned up');
});

test('returns exit code and stderr', async function () {
  const ctx = makeBridge(function (cmd, cb) {
    setTimeout(function () { ctx.window[cb](1, '', 'boom'); }, 5);
    return null;
  });
  const result = await ctx.exec('false', 1000);
  assert.strictEqual(result.code, 1);
  assert.strictEqual(result.stderr, 'boom');
});

test('supports promise-based and synchronous bridges', async function () {
  let ctx = makeBridge(function () {
    return Promise.resolve({ errno: 0, stdout: 'promise', stderr: '' });
  });
  assert.strictEqual((await ctx.exec('true', 1000)).stdout, 'promise');

  ctx = makeBridge(function () { return 'sync'; });
  const result = await ctx.exec('true', 1000);
  assert.strictEqual(result.code, 0);
  assert.strictEqual(result.stdout, 'sync');
});

test('times out with a timeout flag and cleans the callback', async function () {
  const ctx = makeBridge(function () { return null; });
  await assert.rejects(ctx.exec('hang', 40), function (err) {
    return err && err.timeout === true && /timed out/.test(err.message);
  });
  assert.deepStrictEqual(pendingCallbackKeys(ctx.window), [], 'callback should be removed on timeout');
});

test('keeps concurrent callbacks isolated', async function () {
  const cbs = [];
  const ctx = makeBridge(function (cmd, cb) {
    cbs.push(cb);
    return null;
  });
  const p1 = ctx.exec('first', 1000);
  const p2 = ctx.exec('second', 1000);
  assert.strictEqual(cbs.length, 2);
  assert.notStrictEqual(cbs[0], cbs[1]);
  ctx.window[cbs[1]](0, 'b', '');
  ctx.window[cbs[0]](0, 'a', '');
  assert.strictEqual((await p1).stdout, 'a');
  assert.strictEqual((await p2).stdout, 'b');
  assert.deepStrictEqual(pendingCallbackKeys(ctx.window), []);
});

(async function () {
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log('PASS  ' + name);
    } catch (err) {
      console.error('FAIL  ' + name);
      console.error(err && err.stack ? err.stack : err);
      process.exitCode = 1;
    }
  }
  console.log((process.exitCode ? 'FAILED' : 'OK') + ' - ' + tests.length + ' bridge tests');
})();
