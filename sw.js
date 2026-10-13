// Offline cache for the app shell. Bump VERSION on every release.
const VERSION = 'pm-tracker-v1.0.0';
const ASSETS = [
  './', 'index.html', 'css/app.css', 'js/app.js', 'js/logic.js', 'js/db.js',
  'vendor/leaflet.js', 'vendor/leaflet.css', 'vendor/xlsx.full.min.js',
  'manifest.webmanifest', 'icons/icon-180.png', 'icons/icon-192.png', 'icons/icon-512.png',
];
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(ASSETS)));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('message', (e) => { if (e.data === 'skipWaiting') self.skipWaiting(); });
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return; // map tiles etc. go straight to network
  e.respondWith(
    caches.match(e.request, { ignoreSearch: true }).then((hit) => hit || fetch(e.request).catch(() => caches.match('index.html')))
  );
});
