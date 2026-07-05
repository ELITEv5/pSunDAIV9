// pSunDAI V9 — Service Worker
// Bump CACHE_VER when deploying a new IPFS CID so stale clients get fresh assets.
const CACHE_VER = "psundai-v9-1";
const ASSETS = [
  "./",
  "./index.html",
  "./liquidations.html",
  "./ethers.umd.min.js",
  "./sundailogo.png",
  "./favicon.svg",
  "./manifest.json",
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE_VER)
      .then(c => c.addAll(ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_VER).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Cache-first: serve from cache, fall back to network.
// Ideal for IPFS: assets are immutable per CID, so stale cache never happens.
self.addEventListener("fetch", e => {
  // Only handle same-origin GET requests (skip MetaMask RPC etc.)
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin && !url.pathname.startsWith("/ipfs/")) return;

  e.respondWith(
    caches.match(e.request).then(cached => {
      if (cached) return cached;
      return fetch(e.request).then(res => {
        if (!res || res.status !== 200 || res.type === "opaque") return res;
        const clone = res.clone();
        caches.open(CACHE_VER).then(c => c.put(e.request, clone));
        return res;
      });
    })
  );
});
