const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');
const web = path.resolve(__dirname, '../web');
const html = fs.readFileSync(path.join(web, 'index.html'), 'utf8');
const startup = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const bootstrap = fs.readFileSync(path.join(web, 'flutter_bootstrap.js'), 'utf8')
  .replace(/\{\{flutter_\w+\}\}/g, '');

function environment() {
  const handlers = {};
  const elements = Object.fromEntries(['startup', 'startup-status', 'startup-retry'].map(id =>
    [id, {hidden: true, remove() { this.removed = true; }, addEventListener(type, fn) { this[type] = fn; }}]));
  let timer, cleared = false, reloads = 0;
  const window = {addEventListener: (type, fn) => handlers[type] = fn,
    location: {reload: () => reloads++}};
  const context = {window, document: {getElementById: id => elements[id]},
    setTimeout: fn => {timer = fn; return 1;}, clearTimeout: () => cleared = true};
  vm.runInNewContext(startup, context);
  return {context, window, handlers, elements, slow: () => timer(),
    get cleared() {return cleared;}, get reloads() {return reloads;}};
}

test('slow download stays visible, offers manual retry, and never reloads automatically', () => {
  const env = environment();
  env.slow();
  assert.match(env.elements['startup-status'].textContent, /больше времени/);
  assert.equal(env.elements['startup-retry'].hidden, false);
  assert.equal(env.reloads, 0);
  env.elements['startup-retry'].click();
  assert.equal(env.reloads, 1);
});

test('resource error remains actionable until a real first frame arrives', () => {
  const env = environment();
  env.handlers.error();
  env.window.voicechatStartup.stage('ignored');
  env.slow();
  assert.match(env.elements['startup-status'].textContent, /Не удалось/);
  assert.equal(env.elements['startup-retry'].hidden, false);
  assert.ok(env.cleared);
  assert.ok(!env.elements.startup.removed);
  env.handlers['flutter-first-frame']();
  assert.ok(env.elements.startup.removed);
});

test('bootstrap does not wait for service workers or remove shell before first frame', async () => {
  const env = environment();
  let options, ran = false;
  env.context.navigator = {get serviceWorker() {throw new Error('Worker must not gate startup');}};
  env.context._flutter = {loader: {load: async value => {options = value;}}};
  vm.runInNewContext(bootstrap, env.context);
  assert.equal(options.serviceWorkerSettings, undefined);
  await options.onEntrypointLoaded({initializeEngine: async () => ({runApp: async () => {ran = true;}})});
  assert.ok(ran);
  assert.ok(!env.elements.startup.removed);
  env.handlers['flutter-first-frame']();
  assert.ok(env.elements.startup.removed);
  assert.ok(env.cleared);
});

test('loader and engine failures expose retry instead of leaving a blank screen', async () => {
  for (const phase of ['loader', 'engine', 'app']) {
    const env = environment();
    let options;
    env.context._flutter = {loader: {load: async value => {
      options = value;
      if (phase === 'loader') throw new Error('network');
    }}};
    vm.runInNewContext(bootstrap, env.context);
    if (phase !== 'loader') await options.onEntrypointLoaded({initializeEngine: async () => {
      if (phase === 'engine') throw new Error('wasm');
      return {runApp: async () => {throw new Error('app');}};
    }});
    await new Promise(resolve => setImmediate(resolve));
    assert.match(env.elements['startup-status'].textContent, /Не удалось/);
    assert.equal(env.elements['startup-retry'].hidden, false);
  }
});

test('shell precedes scripts and helper downloads do not block HTML parsing', () => {
  assert.ok(html.indexOf('id="startup"') < html.indexOf('<script'));
  const scripts = [...html.matchAll(/<script src="([^"]+)"([^>]*)>/g)];
  assert.deepEqual(scripts.map(s => s[1]), ['vault.js', 'files.js', 'photos.js', 'media_audio.js', 'push_client.js', 'flutter_bootstrap.js']);
  for (const script of scripts) assert.match(script[2], /defer/);
  assert.equal(scripts.at(-1)[1], 'flutter_bootstrap.js');
  assert.match(html, /rel="preload" href="main.dart.js" as="script"/);
});

test('new bootstrap also starts with an older cached HTML entrypoint', async () => {
  let options, ran = false;
  vm.runInNewContext(bootstrap, {window: {}, _flutter: {loader: {
    load: async value => {options = value;},
  }}});
  await options.onEntrypointLoaded({initializeEngine: async () => ({runApp: async () => {ran = true;}})});
  assert.ok(ran);
});
