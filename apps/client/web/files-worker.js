/* Plaintext is streamed in memory only; this worker never opens a cache or database. */
'use strict';
const sources = new Map();
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('message', event => {
  const data = event.data;
  if (data?.action !== 'register' || !event.source?.id || !event.ports[0] || !/^[a-f0-9]{64}$/.test(data.id) ||
      !Number.isInteger(data.size) || data.size < 0 || data.size > (data.download === true ? 100000000000 : 314572800) || typeof data.mime !== 'string' || /[\r\n]/.test(data.mime)) return;
  const port = event.ports[0];
  const source = {download: data.download === true, claimed: false, client: event.source.id, size: data.size, mime: data.mime, name: data.name, port, pending: new Map(), next: 0};
  sources.set(data.id, source);
  port.onmessage = event => {
    const message = event.data;
    if (message.close) {
      sources.delete(data.id);
      for (const wait of source.pending.values()) wait.reject(new Error('Media closed'));
      source.pending.clear(); port.close(); return;
    }
    const wait = source.pending.get(message.id);
    if (!wait) return;
    source.pending.delete(message.id);
    message.error ? wait.reject(new Error('Media read failed')) : wait.resolve(message.bytes);
  };
  port.postMessage({ready: true});
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith('/voicechat-media/')) return;
  event.respondWith((async () => {
    const source = sources.get(url.pathname.substring('/voicechat-media/'.length));
    if (!source || !['GET', 'HEAD'].includes(event.request.method)) return new Response(null, {status: 404});
    // Download navigations omit clientId; their single-use capability is created only by the exporting tab.
    const exporting = source.download && !source.claimed && event.request.mode === 'navigate' && !event.clientId && event.request.referrer.startsWith(self.location.origin + '/');
    if (source.client !== event.clientId && !exporting) return new Response(null, {status: 404});
    if (exporting && event.request.method === 'GET') source.claimed = true;
    let start = 0, end = source.size;
    const range = event.request.headers.get('Range');
    if (range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (!match) return new Response(null, {status: 416});
      start = Number(match[1]);
      if (match[2]) end = Math.min(Number(match[2]) + 1, source.size);
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= end) return new Response(null, {status: 416});
    }
    const headers = {'Content-Type': source.mime, 'Content-Length': String(end - start), 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Cross-Origin-Resource-Policy': 'same-origin'};
    if (range) headers['Content-Range'] = `bytes ${start}-${end - 1}/${source.size}`;
    if (url.searchParams.has('download')) headers['Content-Disposition'] = `attachment; filename*=UTF-8''${encodeURIComponent(source.name || 'file')}`;
    if (event.request.method === 'HEAD') return new Response(null, {headers});
    let cancelled = false;
    const stream = new ReadableStream({
      async pull(controller) {
        if (start >= end) { controller.close(); source.port.postMessage({done: true}); return; }
        try {
          const count = Math.min(4 * 1024 * 1024, end - start);
          const id = ++source.next;
          const bytes = await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => { source.pending.delete(id); reject(new Error('Media timeout')); }, 60000);
            source.pending.set(id, {resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); }});
            source.port.postMessage({id, start, end: start + count});
          });
          if (cancelled) return;
          if (!(bytes instanceof Uint8Array) || bytes.length !== count) throw new Error('Invalid part');
          controller.enqueue(bytes); start += count;
        } catch (error) { if (!cancelled) controller.error(error); source.port.postMessage({failed: true}); }
      },
      cancel() { cancelled = true; source.port.postMessage({failed: true}); },
    }, {highWaterMark: 1});
    return new Response(stream, {status: range ? 206 : 200, headers});
  })());
});
