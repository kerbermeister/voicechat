const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {test} = require('node:test');
const root = require('node:path').resolve(__dirname, '../apps/client/web');
const code = name => fs.readFileSync(`${root}/${name}`, 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

test('iOS audio unlock resumes remote tracks, preserves local muting and cancels ringing', async () => {
  const listeners = {};
  const nodes = [];
  let remotePlays = 0, localPlays = 0;
  const audio = [
    {srcObject: {}, muted: false, play: async () => { remotePlays++; }},
    {srcObject: {}, muted: true, play: async () => { localPlays++; }},
  ];
  class AudioContext {
    constructor() { this.state = 'suspended'; this.sampleRate = 48000; this.destination = {}; }
    resume() { this.state = 'running'; return Promise.resolve(); }
    createBuffer() { return {}; }
    decodeAudioData() { return Promise.resolve({}); }
    createBufferSource() {
      const source = {connect() {}, disconnect() {}, start() { this.started = true; }, stop() { this.stopped = true; }};
      nodes.push(source); return source;
    }
  }
  const document = {baseURI: 'https://voice.example/', body: {}, querySelectorAll: () => audio, addEventListener: (type, fn) => listeners[type] = fn};
  const window = {AudioContext};
  vm.runInNewContext(code('media_audio.js'), {window, document, URL, Promise, Map, fetch: async () => ({ok: true, arrayBuffer: async () => new ArrayBuffer(1)}), MutationObserver: class { observe() {} }});
  const api = window.VoiceChatAudio;
  api.prepare();
  assert.equal(await api.play('ring', 'ringtone', true), false);
  assert.equal(nodes.length, 0);
  assert.equal(typeof listeners.pointerdown, 'function');
  assert.equal(typeof listeners.click, 'function');
  listeners.pointerup();
  await tick();
  assert.ok(remotePlays > 0);
  assert.equal(localPlays, 0);
  const ring = nodes.find(node => node.loop);
  assert.ok(ring.started);
  api.stop('ring');
  assert.ok(ring.stopped);
  audio[0].play = async () => { throw new Error('NotAllowedError'); };
  assert.equal(await api.resume(), false);
  api.close();
});

function clientEnvironment({installed = true, permission = 'granted', bindingOK = true} = {}) {
  const calls = [];
  let bind;
  const subscription = {options: {}, toJSON: () => ({endpoint: 'https://web.push.apple.com/test', keys: {}}), unsubscribe: async () => calls.push('unsubscribe')};
  const registration = {
    active: {postMessage: (message, ports) => { bind = message.binding; ports[0].postMessage({ok: bindingOK}); }},
    pushManager: {getSubscription: async () => null, subscribe: async () => subscription},
    getNotifications: async () => [],
  };
  const navigator = {userAgent: 'iPhone', serviceWorker: {register: async () => {calls.push('register'); return registration;}, ready: Promise.resolve(registration), getRegistration: async () => registration}};
  const Notification = {requestPermission() { calls.push('permission'); return Promise.resolve(permission); }};
  class MessageChannel {
    constructor() {
      this.port1 = {close() {}};
      this.port2 = {postMessage: value => queueMicrotask(() => this.port1.onmessage({data: value}))};
    }
  }
  const window = {PushManager: {}, Notification, matchMedia: () => ({matches: installed})};
  const context = {window, navigator, Notification, document: {baseURI: 'https://voice.example/'}, URL, Uint8Array, atob, AbortController, setTimeout, clearTimeout, MessageChannel,
    fetch: async (url, options) => { calls.push(url); assert.equal(options.headers.Authorization, 'Bearer secret'); return {ok: true, json: async () => url.endsWith('/config') ? {public_key: Buffer.alloc(65).toString('base64url')} : {binding: 'new-binding'}}; }};
  vm.runInNewContext(code('push_client.js'), context);
  return {api: window.VoiceChatPush, calls, get binding() {return bind;}};
}

test('iPhone push requests permission during the click before async work', async () => {
  const env = clientEnvironment();
  const enabling = env.api.enable('https://voice.example/api', 'secret');
  assert.deepEqual(env.calls, ['permission']);
  assert.match(await enabling, /включены/);
  assert.equal(env.binding, 'new-binding');
  assert.ok(env.calls.some(value => value.endsWith('/subscribe')));
});

test('Failed local binding removes the pusher and browser subscription', async () => {
  const env = clientEnvironment({bindingOK: false});
  await assert.rejects(env.api.enable('https://voice.example/api', 'secret'), /сохранить настройку/);
  assert.equal(env.calls.filter(value => value.endsWith('/subscribe')).length, 2);
  assert.ok(env.calls.includes('unsubscribe'));
});

test('Safari tab and denied permission never register or send a subscription', async () => {
  const tab = clientEnvironment({installed: false});
  await assert.rejects(tab.api.enable('https://voice.example/api', 'secret'), /экран «Домой»/);
  assert.deepEqual(tab.calls, []);
  const denied = clientEnvironment({permission: 'denied'});
  await assert.rejects(denied.api.enable('https://voice.example/api', 'secret'), /Разрешите/);
  assert.deepEqual(denied.calls, ['permission']);
});

test('Worker persists account binding, ignores old-account push and displays generic notification', async () => {
  const handlers = {}, values = new Map(), notices = [];
  let focused = false, opened;
  const db = {close() {}, transaction() {
    const transaction = {objectStore: () => ({
      put(value, key) {values.set(key, value); const result = {result: key}; setImmediate(() => transaction.oncomplete()); return result;},
      get(key) {const result = {result: values.get(key)}; setImmediate(() => transaction.oncomplete()); return result;},
    })}; return transaction;
  }};
  const indexedDB = {open() { const request = {result: db}; setImmediate(() => request.onsuccess()); return request; }};
  const self = {addEventListener: (type, fn) => handlers[type] = fn,
    registration: {scope: 'https://voice.example/', showNotification: async (...args) => notices.push(args)},
    clients: {matchAll: async () => [{url: 'https://voice.example/', focus: async () => {focused = true;}}], openWindow: async url => opened = url},
  };
  vm.runInNewContext(code('push_worker.js'), {self, indexedDB, URL});
  let pending;
  const waitUntil = promise => pending = promise;
  handlers.message({data: {type: 'bind', binding: 'current'}, ports: [{postMessage: value => assert.equal(value.ok, true)}], waitUntil});
  await pending;
  for (const binding of ['previous', 'current']) {
    handlers.push({data: {json: () => ({binding, body: 'SECRET MESSAGE', url: 'https://evil.test'})}, waitUntil});
    await pending;
  }
  assert.equal(notices.length, 1);
  assert.equal(notices[0][0], 'VoiceChat');
  assert.equal(notices[0][1].silent, false);
  assert.doesNotMatch(JSON.stringify(notices), /SECRET|evil/);
  handlers.notificationclick({notification: {close() {}}, waitUntil});
  await pending;
  assert.equal(focused, true);
  assert.equal(opened, undefined);
});
