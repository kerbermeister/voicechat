(() => {
  'use strict';
  const saves = new Map();
  const streams = new Map();
  let worker;
  async function mediaWorker() {
    if (!worker) worker = (async () => {
      if (!navigator.serviceWorker) throw new Error('Secure context and service workers required');
      const registration = await navigator.serviceWorker.register('/files-worker.js', {scope: '/'});
      const next = registration.installing || registration.waiting || registration.active;
      if (!next) throw new Error('Media worker unavailable');
      if (next.state !== 'activated') await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Media worker activation timeout')), 15000);
        next.addEventListener('statechange', () => { if (next.state === 'activated') { clearTimeout(timeout); resolve(); } });
      });
      if (navigator.serviceWorker.controller?.scriptURL !== next.scriptURL) await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Media worker control timeout')), 15000);
        navigator.serviceWorker.addEventListener('controllerchange', () => { clearTimeout(timeout); resolve(); }, {once: true});
      });
      return next;
    })();
    return worker;
  }
  async function stream(name, mime, size, read, download = false) {
    const active = await mediaWorker();
    const id = [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, '0')).join('');
    const channel = new MessageChannel();
    let ready, done, failed;
    const opened = new Promise(resolve => { ready = resolve; });
    const completed = new Promise((resolve, reject) => { done = resolve; failed = reject; });
    completed.catch(() => {});
    channel.port1.onmessage = async event => {
      const data = event.data;
      if (data.ready) { ready(); return; }
      if (data.done) { done(); return; }
      if (data.failed) { failed(new Error('Download interrupted')); return; }
      try {
        const bytes = new Uint8Array(await read(data.start, data.end));
        channel.port1.postMessage({id: data.id, bytes}, [bytes.buffer]);
      } catch (_) { channel.port1.postMessage({id: data.id, error: true}); failed(new Error('Cannot read file')); }
    };
    active.postMessage({action: 'register', id, name, mime, size, download}, [channel.port2]);
    await opened;
    const url = `${location.origin}/voicechat-media/${id}`;
    streams.set(url, {port: channel.port1, completed});
    return url;
  }
  function revoke(url) {
    const source = streams.get(url); streams.delete(url);
    if (source) { source.port.postMessage({close: true}); source.port.close(); }
    else if (url.startsWith('blob:')) URL.revokeObjectURL(url);
  }
  globalThis.voicechatFiles = Object.freeze({
    supportsSavePicker: () => !!globalThis.showSaveFilePicker,
    async beginSave(name) {
      let handle;
      try { handle = await showSaveFilePicker({suggestedName: name.replace(/[\\/]/g, '_')}); }
      catch (error) { if (error.name === 'AbortError') return null; throw error; }
      const id = crypto.randomUUID(); saves.set(id, await handle.createWritable()); return id;
    },
    async write(id, bytes) { const output = saves.get(id); if (!output) throw new Error('Save is closed'); await output.write(bytes); },
    async finish(id, success) {
      const output = saves.get(id); saves.delete(id);
      if (output) await (success ? output.close() : output.abort());
    },
    stream, revoke,
    async download(name, mime, size, read) {
      const url = await stream(name, mime, size, read, true);
      const frame = document.createElement('iframe'); frame.hidden = true;
      try {
        frame.src = `${url}?download`; document.body.append(frame);
        await streams.get(url).completed;
      } finally { frame.remove(); revoke(url); }
    },
  });
})();
