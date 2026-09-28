// Wanhar Mart service worker: lets the apps be installed and shows notifications when the app is closed.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data && e.data.text() }; }
  const page = (d.url || 'customer.html').split('#')[0];
  const icon = 'icon-' + ({ 'rider.html':'rider', 'restaurant.html':'shop', 'admin.html':'admin' }[page] || 'customer') + '-192.png';
  e.waitUntil(self.registration.showNotification(d.title || 'Wanhar Mart', {
    body: d.body || '', icon, badge: icon, tag: d.tag || undefined, renotify: !!d.tag,
    vibrate: [200, 100, 200, 100, 300], data: { url: d.url || 'customer.html' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL(e.notification.data && e.notification.data.url || 'customer.html', self.registration.scope).href;
  const page = target.split('#')[0];
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list){
      if (c.url.split('#')[0].split('?')[0] === page.split('?')[0]){
        await c.focus();
        try { if (target !== c.url && 'navigate' in c) await c.navigate(target); } catch (err) {}
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});
