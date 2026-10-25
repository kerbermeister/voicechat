/* Dedicated notifications worker: no chat cache or E2EE material is stored here. */
function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('voicechat-push', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('settings');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function binding(value, write = false) {
  const db = await database();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction('settings', write ? 'readwrite' : 'readonly');
      const store = transaction.objectStore('settings');
      const result = write ? store.put(value, 'binding') : store.get('binding');
      transaction.oncomplete = () => resolve(result.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  } finally { db.close(); }
}
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('message', event => {
  if (event.data?.type !== 'bind') return;
  event.waitUntil(binding(event.data.binding, true).then(
    () => event.ports[0]?.postMessage({ok: true}),
    () => event.ports[0]?.postMessage({ok: false}),
  ));
});
self.addEventListener('push', event => {
  event.waitUntil((async () => {
    let payload;
    try { payload = event.data?.json(); } catch (_) { return; }
    if (!payload || payload.binding !== await binding()) return;
    // Always show a visible notification, including while a window is open (iOS requirement).
    await self.registration.showNotification('VoiceChat', {
      body: 'Новое сообщение или входящий звонок',
      icon: new URL('icons/Icon-192.png', self.registration.scope).href,
      badge: new URL('icons/Icon-192.png', self.registration.scope).href,
      silent: false,
    });
  })());
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    for (const client of windows) {
      if (client.url.startsWith(self.registration.scope)) return client.focus();
    }
    return self.clients.openWindow(self.registration.scope);
  })());
});
