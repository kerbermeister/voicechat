/* Password protects records at rest, not a compromised origin or unlocked tab. */
(() => {
  'use strict';
  const sessions = new Map();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder('utf-8', {fatal: true});
  const bytes = n => crypto.getRandomValues(new Uint8Array(n));
  const b64 = data => {
    let result = '';
    const view = new Uint8Array(data);
    for (let offset = 0; offset < view.length; offset += 32768) result += String.fromCharCode(...view.subarray(offset, offset + 32768));
    return btoa(result);
  };
  const unb64 = data => Uint8Array.from(atob(data), c => c.charCodeAt(0));
  const request = req => new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error('Close other tabs before opening the vault'));
  });
  const completed = txn => new Promise((resolve, reject) => {
    txn.oncomplete = resolve;
    txn.onabort = txn.onerror = () => reject(txn.error || new Error('Storage write aborted'));
  });
  const aad = (name, store, id) => encoder.encode(JSON.stringify([name, store, id, 1]));
  async function seal(key, name, store, id, text) {
    const iv = bytes(12);
    const body = await crypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: aad(name, store, id)}, key, encoder.encode(text));
    return JSON.stringify({v: 1, iv: b64(iv), body: b64(body)});
  }
  async function unseal(key, name, store, id, envelope) {
    const value = JSON.parse(envelope);
    if (value.v !== 1 || typeof value.iv !== 'string' || typeof value.body !== 'string') throw new Error('Invalid encrypted record');
    const iv = unb64(value.iv);
    if (iv.length !== 12) throw new Error('Invalid nonce');
    return decoder.decode(await crypto.subtle.decrypt({name: 'AES-GCM', iv, additionalData: aad(name, store, id)}, key, unb64(value.body)));
  }
  function session(name) {
    const value = sessions.get(name);
    if (!value) throw new Error('Vault is locked');
    return value;
  }
  async function blobStore(name, mode, action) {
    session(name);
    const req = indexedDB.open(`${name}.blobs`, 1);
    req.onupgradeneeded = () => req.result.createObjectStore('chunks');
    const db = await request(req);
    try {
      const txn = db.transaction('chunks', mode);
      const done = completed(txn);
      const result = await request(action(txn.objectStore('chunks')));
      await done;
      return result;
    } finally { db.close(); }
  }
  async function open(name, password, remember = false) {
    if (!isSecureContext || !crypto.subtle || !navigator.locks || !indexedDB.databases) throw new Error('Secure context and a modern browser are required');
    const resuming = password === null;
    const resumeName = `voicechat.unlock:${name}`;
    if (!resuming && (typeof password !== 'string' || password.length < 12 || password.length > 1024)) throw new Error('Use a separate passphrase of 12–1024 characters');
    let release;
    const held = new Promise(resolve => { release = resolve; });
    let acquired;
    const ready = new Promise(resolve => { acquired = resolve; });
    const lockTask = navigator.locks.request(`voicechat:${name}`, {ifAvailable: true}, async lock => {
      acquired(!!lock);
      if (lock) await held;
    });
    if (!await Promise.race([ready, lockTask.then(() => false)])) { await lockTask; throw new Error('This profile is open in another tab'); }
    let db;
    try {
      const databases = await indexedDB.databases();
      if (databases.some(d => d.name === name)) throw new Error('Legacy plaintext profile: recover history before removing site data');
      const req = indexedDB.open(`${name}.vault`, 1);
      req.onupgradeneeded = () => req.result.createObjectStore('meta');
      db = await request(req);
      let header = await request(db.transaction('meta').objectStore('meta').get('header'));
      if (!header && databases.some(d => d.name === `${name}.encrypted` || d.name === `${name}.blobs`)) throw new Error('Vault header is missing; restore history instead of overwriting data');
      const salt = header ? unb64(header.salt) : bytes(16);
      if (salt.length !== 16 || (header && header.v !== 1)) throw new Error('Unsupported vault format');
      let raw;
      if (resuming) {
        const saved = sessionStorage.getItem(resumeName);
        if (!header || !saved) throw new Error('Unlock the vault with your local passphrase');
        raw = unb64(saved);
      } else {
        const material = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveBits']);
        raw = new Uint8Array(await crypto.subtle.deriveBits({name: 'PBKDF2', hash: 'SHA-256', salt, iterations: 600000}, material, 256));
      }
      if (raw.length !== 32) throw new Error('Invalid session key');
      const key = await crypto.subtle.importKey('raw', raw, {name: 'AES-GCM'}, false, ['encrypt', 'decrypt']);
      const resumeKey = remember ? b64(raw) : null;
      raw.fill(0);
      if (header) {
        if (await unseal(key, name, 'meta', 'header', header.check) !== 'voicechat-vault-v1') throw new Error('Invalid vault check');
      } else {
        header = {v: 1, salt: b64(salt), check: await seal(key, name, 'meta', 'header', 'voicechat-vault-v1')};
        const txn = db.transaction('meta', 'readwrite');
        const done = completed(txn);
        txn.objectStore('meta').put(header, 'header');
        await done;
      }
      // Opt-in tab session only: never persist the account password or vault passphrase.
      if (remember) sessionStorage.setItem(resumeName, resumeKey);
      else sessionStorage.removeItem(resumeName);
      sessions.set(name, {key, release, lockTask});
    } catch (error) {
      if (resuming) sessionStorage.removeItem(resumeName);
      release();
      await lockTask;
      throw error;
    } finally {
      db?.close();
    }
  }
  async function close(name) {
    sessionStorage.removeItem(`voicechat.unlock:${name}`);
    const value = sessions.get(name);
    if (!value) return;
    sessions.delete(name);
    value.release();
    await value.lockTask;
  }
  globalThis.voicechatVault = Object.freeze({
    open, close,
    async usage(name) {
      session(name);
      let bytes = 0;
      const existing = new Set((await indexedDB.databases()).map(db => db.name));
      for (const suffix of ['encrypted', 'blobs', 'vault']) {
        const databaseName = `${name}.${suffix}`;
        if (!existing.has(databaseName)) continue;
        const db = await request(indexedDB.open(databaseName));
        try {
          for (const store of db.objectStoreNames) {
            await new Promise((resolve, reject) => {
              const cursor = db.transaction(store).objectStore(store).openCursor();
              cursor.onerror = () => reject(cursor.error);
              cursor.onsuccess = () => {
                const item = cursor.result;
                if (!item) { resolve(); return; }
                // UTF-16 payload estimate, one bounded encrypted record at a time.
                bytes += 2 * (String(item.key).length + JSON.stringify(item.value).length);
                item.continue();
              };
            });
          }
        } finally { db.close(); }
      }
      return bytes;
    },
    async writeBlob(name, id, data) {
      if (!(data instanceof Uint8Array) || data.length > 4 * 1024 * 1024) throw new Error('Invalid chunk');
      const envelope = await seal(session(name).key, name, 'blobs', id, b64(data));
      await blobStore(name, 'readwrite', store => store.put(envelope, id));
    },
    async readBlob(name, id) {
      const envelope = await blobStore(name, 'readonly', store => store.get(id));
      return envelope === undefined ? null : unb64(await unseal(session(name).key, name, 'blobs', id, envelope));
    },
    deleteBlob: (name, id) => blobStore(name, 'readwrite', store => store.delete(id)),
    readAccount: () => sessionStorage.getItem('voicechat.account'),
    writeAccount: value => value === null ? sessionStorage.removeItem('voicechat.account') : sessionStorage.setItem('voicechat.account', value),
    encrypt: (name, store, id, text) => seal(session(name).key, name, store, id, text),
    decrypt: (name, store, id, envelope) => unseal(session(name).key, name, store, id, envelope),
    async erase(name) {
      sessionStorage.removeItem(`voicechat.unlock:${name}`);
      if (sessions.has(name)) throw new Error('Close the vault before erasing');
      await navigator.locks.request(`voicechat:${name}`, {ifAvailable: true}, async lock => {
        if (!lock) throw new Error('Profile in use');
        await request(indexedDB.deleteDatabase(`${name}.encrypted`));
        await request(indexedDB.deleteDatabase(`${name}.blobs`));
        await request(indexedDB.deleteDatabase(`${name}.vault`));
      });
    },
  });
})();
