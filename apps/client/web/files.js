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
    let openingTimer;
    const opened = new Promise((resolve, reject) => {
      ready = () => { clearTimeout(openingTimer); resolve(); };
      openingTimer = setTimeout(() => { channel.port1.close(); reject(new Error('Media registration timeout')); }, 15000);
    });
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
  // Native sharing returns to the chat instead of opening an iOS iframe preview.
  async function shareFile(name, mime, size, read) {
    const parts = [];
    for (let start = 0; start < size; start += 4 * 1024 * 1024) {
      const end = Math.min(size, start + 4 * 1024 * 1024);
      const bytes = new Uint8Array(await read(start, end));
      if (bytes.length !== end - start) throw new Error('Incomplete export');
      parts.push(bytes);
    }
    const file = new File(parts, name, {type: mime});
    parts.length = 0;
    if (!navigator.canShare?.({files: [file]})) return null;
    // Async decryption consumes the original activation. A ready button gives
    // Web Share a fresh gesture, without navigating away from the application.
    return await new Promise(resolve => {
      const dialog = document.createElement('dialog');
      dialog.style.cssText = 'max-width:min(380px,calc(100vw - 48px));border:1px solid #8886;border-radius:20px;padding:24px;color:CanvasText;background:Canvas;font:16px system-ui;box-shadow:0 12px 50px #0005';
      const title = document.createElement('h3'); title.id = crypto.randomUUID(); dialog.setAttribute('aria-labelledby', title.id); title.textContent = 'Файл готов к сохранению';
      const text = document.createElement('p'); text.style.overflowWrap = 'anywhere'; text.id = crypto.randomUUID(); dialog.setAttribute('aria-describedby', text.id); text.textContent = `${name} — нажмите «Сохранить», затем выберите «Сохранить в Файлы» в меню iPhone.`;
      const save = document.createElement('button'); save.textContent = 'Сохранить';
      const cancel = document.createElement('button'); cancel.textContent = 'Отмена';
      for (const button of [cancel, save]) button.style.cssText = 'font:inherit;padding:12px 18px;margin:4px;border-radius:12px;border:1px solid #8888';
      let finished = false;
      const finish = result => { if (finished) return; finished = true; dialog.close(); dialog.remove(); resolve(result); };
      cancel.onclick = () => finish('cancelled');
      dialog.oncancel = event => { event.preventDefault(); finish('cancelled'); };
      save.onclick = async () => {
        save.disabled = true;
        try { await navigator.share({files: [file]}); finish('shared'); }
        catch (error) {
          if (error.name === 'AbortError') { finish('cancelled'); return; }
          text.textContent = 'Не удалось открыть меню сохранения. Повторите или нажмите «Отмена». Файл остаётся в чате.';
          save.disabled = false;
        }
      };
      dialog.append(title, text, cancel, save); document.body.append(dialog); dialog.showModal(); save.focus();
    });
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
      const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
      // Bound the sharing copy. Larger files use the existing streaming worker.
      if (ios && navigator.share && size <= 64 * 1024 * 1024) {
        const result = await shareFile(name, mime, size, read);
        if (result !== null) return result;
      }
      if (size === 0) {
        // An empty stream can finish before an iframe starts its download.
        const url = URL.createObjectURL(new Blob([], {type: mime}));
        const link = document.createElement('a'); link.href = url; link.download = name;
        document.body.append(link); link.click(); link.remove();
        setTimeout(() => URL.revokeObjectURL(url), 30000);
        return 'download';
      }
      const url = await stream(name, 'application/octet-stream', size, read, true);
      const frame = document.createElement('iframe'); frame.hidden = true;
      try {
        frame.src = `${url}?download`; document.body.append(frame);
        await streams.get(url).completed;
      } finally { frame.remove(); revoke(url); }
      return 'download';
    },
  });
})();
