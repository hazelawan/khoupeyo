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

// Pass page requests to the network; if the phone is offline show a short message instead of an error page.
self.addEventListener('fetch', e => {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fetch(e.request).catch(() => new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><body style="font-family:sans-serif;text-align:center;padding:40px 20px;color:#1E2B25"><h2>No internet</h2><p>Please check your internet and try again.</p><p dir="rtl">انٹرنیٹ نہیں ہے۔ براہ کرم انٹرنیٹ چیک کریں۔</p><button onclick="location.reload()" style="padding:12px 20px;border:0;border-radius:12px;background:#1F6F4A;color:#fff;font-size:16px">Try again</button></body>', { headers:{ 'Content-Type':'text/html; charset=utf-8' } })));
});
