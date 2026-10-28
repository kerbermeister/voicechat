(() => {
  const workerURL = new URL('push_worker.js', document.baseURI);
  const isIPhone = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  function availability() {
    if (isIPhone() && !window.matchMedia('(display-mode: standalone)').matches && !navigator.standalone) {
      return 'На iPhone добавьте VoiceChat на экран «Домой» через меню Safari, затем включите уведомления из приложения.';
    }
    if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return 'Этот браузер не поддерживает push-уведомления.';
    return null;
  }
  async function request(base, token, path, body, routedRequest) {
    if (routedRequest) return JSON.parse(await routedRequest(path, body ? JSON.stringify(body) : null));
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(`${base.replace(/\/$/, '')}/push/${path}`, {
        method: body ? 'POST' : 'GET',
        headers: {'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json'},
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
        redirect: 'error',
      });
      if (!response.ok) throw new Error('Сервис уведомлений недоступен. Повторите позже.');
      return await response.json();
    } finally { clearTimeout(timeout); }
  }
  function keyBytes(key) {
    const raw = atob(key.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - key.length % 4) % 4));
    return Uint8Array.from(raw, c => c.charCodeAt(0));
  }
  async function worker() {
    const registration = await navigator.serviceWorker.register(workerURL.href, {scope: new URL('.', workerURL).pathname, updateViaCache: 'none'});
    // register() may resolve before the first worker can receive messages.
    await navigator.serviceWorker.ready;
    return registration;
  }
  function bind(registration, binding) {
    const target = registration.active || registration.waiting || registration.installing;
    if (!target) throw new Error('Уведомления ещё запускаются. Повторите.');
    return new Promise((resolve, reject) => {
      const channel = new MessageChannel();
      const timeout = setTimeout(() => reject(new Error('Не удалось сохранить настройку уведомлений.')), 5000);
      channel.port1.onmessage = event => {
        clearTimeout(timeout); channel.port1.close();
        event.data?.ok ? resolve() : reject(new Error('Не удалось сохранить настройку уведомлений.'));
      };
      target.postMessage({type: 'bind', binding}, [channel.port2]);
    });
  }
  window.VoiceChatPush = {
    async enable(base, token, routedRequest) {
      const reason = availability();
      if (reason) throw new Error(reason);
      // Request before any await: iOS requires the button's transient activation.
      const permission = Notification.requestPermission();
      if (await permission !== 'granted') throw new Error('Разрешите уведомления для VoiceChat в настройках iPhone или браузера.');
      const config = await request(base, token, 'config', null, routedRequest);
      const registration = await worker();
      let subscription = await registration.pushManager.getSubscription();
      const expectedKey = keyBytes(config.public_key);
      if (subscription && subscription.options.applicationServerKey &&
          String(new Uint8Array(subscription.options.applicationServerKey)) !== String(expectedKey)) {
        await subscription.unsubscribe(); subscription = null;
      }
      subscription ??= await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: expectedKey});
      const response = await request(base, token, 'subscribe', {action: 'register', subscription: subscription.toJSON()}, routedRequest);
      try {
        await bind(registration, response.binding);
      } catch (error) {
        await Promise.allSettled([
          request(base, token, 'subscribe', {action: 'remove'}, routedRequest),
          subscription.unsubscribe(),
        ]);
        throw error;
      }
      return 'Уведомления включены. Звук в фоне зависит от настроек iPhone и режима «Фокусирование».';
    },
    async disable(base, token, routedRequest) {
      if (!('serviceWorker' in navigator)) return 'Уведомления выключены.';
      const registration = await navigator.serviceWorker.getRegistration(workerURL.href);
      if (registration) {
        const subscription = await registration.pushManager.getSubscription();
        if (!subscription) return 'Уведомления выключены.';
        await request(base, token, 'subscribe', {action: 'remove'}, routedRequest);
        await bind(registration, null);
        if (subscription) await subscription.unsubscribe();
        for (const notification of await registration.getNotifications()) notification.close();
      }
      return 'Уведомления выключены на этом устройстве.';
    },
  };
})();
