// IndexedDB persistence. The whole app state is one small document (~1 MB at most),
// written atomically on every change.
const DB_NAME = 'pm-tracker', STORE = 'kv', KEY = 'state';

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
let dbp = null;
const db = () => (dbp ||= open());

export async function loadState() {
  const d = await db();
  return new Promise((resolve, reject) => {
    const r = d.transaction(STORE).objectStore(STORE).get(KEY);
    r.onsuccess = () => resolve(r.result || null);
    r.onerror = () => reject(r.error);
  });
}
export async function saveState(state) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(state, KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
export async function requestPersistence() {
  try { if (navigator.storage?.persist) return await navigator.storage.persist(); } catch {}
  return false;
}

export function emptyState() {
  return {
    schema: 1,
    retailers: {},            // id -> retailer
    route: { stops: [], end: 'last', builtAt: null },
    settings: { soonDays: 30, autoLocate: true, home: null, leadDays: 14 },
    meta: { createdAt: new Date().toISOString(), lastBackupAt: null, changesSinceBackup: 0, icsExported: {} },
  };
}
