import * as L0 from './logic.js';
import { loadState, saveState, emptyState, requestPersistence } from './db.js';

const {
  todayStr, addMonths, daysBetween, fmtDate, STATUS, computeStatus, needsVisit, haversineMi, ROAD_FACTOR, hasCoords,
  sortByImportance, optimizeOrder, autoPick, splitLegs, googleWebUrl, googleAppUrl, googleSingleUrl, mapsQuery,
  buildIcs, retailersFromRows, lastVisit,
} = L0;

export const APP_VERSION = '1.0.0';
const PAGE = 150;

let S = null;                 // app state (persisted)
let here = null;              // {lat,lng,acc,ts}
const ui = { view: 'list', filter: 'all', tab: '', q: '', shown: PAGE, detailId: null };
let nearMap = null, nearLayer = null, routeMap = null, routeLayer = null;

// ---------------- helpers ----------------
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const today = () => todayStr();
const active = () => Object.values(S.retailers).filter((r) => !r.archived);
const st = (r) => computeStatus(r, today(), S.settings.soonDays);
const ref = () => here || S.settings.home || null;
const miles = (d) => (d === Infinity || d == null ? '' : d < 10 ? `${d.toFixed(1)} mi` : `${Math.round(d)} mi`);
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;

function statusText(s) {
  if (s.status === 'never') return 'Never visited';
  if (s.status === 'overdue') return `${-s.daysToDue} d overdue`;
  if (s.status === 'soon') return s.daysToDue === 0 ? 'Due today' : `Due in ${s.daysToDue} d`;
  return `Due ${fmtDate(s.due)}`;
}
const geoLabel = { exact: 'Address match', approx: 'Approximate (town center)', manual: 'Set by you', none: 'Missing' };

async function persist(changed = true) {
  if (changed) S.meta.changesSinceBackup = (S.meta.changesSinceBackup || 0) + 1;
  await saveState(S);
  updateBadge();
}

function toast(msg, opts = {}) {
  const t = $('#toast');
  t.innerHTML = `<span>${esc(msg)}</span>${opts.undo ? '<button id="toast-undo">Undo</button>' : ''}`;
  t.hidden = false;
  clearTimeout(toast._t);
  if (opts.undo) $('#toast-undo').onclick = () => { t.hidden = true; opts.undo(); };
  toast._t = setTimeout(() => (t.hidden = true), opts.undo ? 6000 : 3000);
}

function showModal(html) {
  $('#modal-body').innerHTML = html;
  $('#modal').hidden = false;
  return $('#modal-body');
}
function closeModal() { $('#modal').hidden = true; $('#modal-body').innerHTML = ''; }
$('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal' || e.target.closest('[data-close="modal"]')) closeModal(); });

// ---------------- location ----------------
function getLocation({ fresh = false } = {}) {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('Location is not available on this device.'));
    const btn = $('#btn-locate'); btn.classList.add('busy'); $('#locate-label').textContent = 'Locating…';
    navigator.geolocation.getCurrentPosition(
      (p) => {
        here = { lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy, ts: Date.now() };
        btn.classList.remove('busy'); btn.classList.add('ok'); $('#locate-label').textContent = 'Located';
        resolve(here);
      },
      (err) => {
        btn.classList.remove('busy'); $('#locate-label').textContent = 'Locate';
        reject(new Error(err.code === 1 ? 'Location permission is off. Turn it on in Settings › Privacy › Location Services.' : 'Could not get your location.'));
      },
      { enableHighAccuracy: true, timeout: 20000, maximumAge: fresh ? 15000 : 120000 },
    );
  });
}
async function locateAndRender(opts) {
  try { await getLocation(opts); render(); return true; }
  catch (e) { toast(e.message); return false; }
}
$('#btn-locate').onclick = () => locateAndRender({ fresh: true });

// town center = median of exact matches in the same city
function townCenter(city) {
  const c = String(city || '').toUpperCase();
  const pts = Object.values(S.retailers).filter((r) => r.city.toUpperCase() === c && (r.geo === 'exact' || r.geo === 'manual') && hasCoords(r));
  if (!pts.length) return null;
  const lats = pts.map((p) => p.lat).sort((a, b) => a - b), lngs = pts.map((p) => p.lng).sort((a, b) => a - b);
  return { lat: lats[lats.length >> 1], lng: lngs[lngs.length >> 1] };
}

// ---------------- navigation ----------------
function setView(v) {
  ui.view = v;
  $$('.view').forEach((s) => (s.hidden = s.id !== `view-${v}`));
  $$('.tabbar button').forEach((b) => b.classList.toggle('on', b.dataset.view === v));
  $('#view-title').textContent = $(`#view-${v}`).dataset.title;
  window.scrollTo(0, 0);
  render();
}
$$('.tabbar button').forEach((b) => (b.onclick = () => setView(b.dataset.view)));

function render() {
  const has = Object.keys(S.retailers).length > 0;
  $('#welcome').hidden = has;
  $('#list-content').hidden = !has;
  const n = S.route.stops.length;
  $('#route-count').hidden = !n; $('#route-count').textContent = n;
  if (ui.view === 'list') renderList();
  if (ui.view === 'near') renderNear();
  if (ui.view === 'route') renderRoute();
  if (ui.view === 'more') renderMore();
  if (ui.detailId) renderDetail();
}

// ---------------- list ----------------
function renderSummary(items) {
  const c = { overdue: 0, never: 0, soon: 0, current: 0 };
  items.forEach((x) => c[x.s.status]++);
  const total = items.length, visited = c.soon + c.current;
  const pct = total ? Math.round((visited / total) * 100) : 0;
  $('#summary').innerHTML =
    ['overdue', 'never', 'soon', 'current'].map((k) => `<button class="stat ${k}" data-f="${k}"><b>${c[k]}</b><span>${STATUS[k].label}</span></button>`).join('') +
    `<div class="progress"><div class="row-between"><span><b>${visited}</b> of ${total} visited in the last 6 months</span><b>${pct}%</b></div><div class="bar"><i style="width:${pct}%"></i></div></div>`;
  $$('#summary .stat').forEach((b) => (b.onclick = () => setFilter(b.dataset.f)));
}
function renderBanners(items) {
  const out = [];
  const due7 = items.filter((x) => x.s.status === 'soon' && x.s.daysToDue <= 7).length;
  const over = items.filter((x) => x.s.status === 'overdue').length;
  if (over || due7) out.push(`<div class="banner alert"><span>${over ? `<b>${plural(over, 'retailer')}</b> overdue` : ''}${over && due7 ? ' · ' : ''}${due7 ? `<b>${due7}</b> due within 7 days` : ''}</span><button class="btn" data-f="${over ? 'overdue' : 'soon'}">Show</button></div>`);
  const ch = S.meta.changesSinceBackup || 0;
  const last = S.meta.lastBackupAt ? new Date(S.meta.lastBackupAt) : null;
  const stale = !last || (Date.now() - last.getTime()) > 7 * 86400000;
  if (ch > 0 && stale) out.push(`<div class="banner warn"><span>${last ? `Last backup ${fmtDate(todayStr(last))}.` : 'No backup yet.'} ${plural(ch, 'change')} not backed up.</span><button class="btn" id="banner-backup">Back up</button></div>`);
  $('#banners').innerHTML = out.join('');
  $$('#banners [data-f]').forEach((b) => (b.onclick = () => setFilter(b.dataset.f)));
  const bb = $('#banner-backup'); if (bb) bb.onclick = exportBackup;
}
function setFilter(f) {
  ui.filter = f; ui.shown = PAGE;
  $$('#filters .chip').forEach((c) => c.classList.toggle('on', c.dataset.f === f));
  renderList();
}
$$('#filters .chip').forEach((c) => (c.onclick = () => setFilter(c.dataset.f)));
$('#search').addEventListener('input', (e) => { ui.q = e.target.value.trim().toLowerCase(); ui.shown = PAGE; renderList(); });
$('#tab-filter').onchange = (e) => { ui.tab = e.target.value; ui.shown = PAGE; renderList(); };
$('#more-rows').onclick = () => { ui.shown += PAGE; renderList(); };

function rowHtml(x, { showAdd = true } = {}) {
  const { r, s } = x, inRoute = S.route.stops.includes(r.id);
  const geo = r.geo === 'approx' || r.geo === 'none' ? `<span class="pill geo">${r.geo === 'none' ? 'No location' : 'Approx. location'}</span>` : '';
  const doneToday = lastVisit(r) === today() ? '<span class="pill done">Done today</span>' : '';
  return `<li class="rowi s-${s.status}" data-id="${esc(r.id)}">
    <span class="stripe"></span>
    <div class="main" data-open="${esc(r.id)}">
      <div class="name">${esc(r.name)}</div>
      <div class="sub">#${esc(r.id)} · ${esc(r.address)}, ${esc(r.city)}</div>
      <div class="meta"><span class="pill ${s.status}">${esc(statusText(s))}</span>${doneToday}${geo}</div>
    </div>
    <div class="side">
      <span class="dist">${miles(x._d)}</span>
      ${showAdd ? `<button class="addbtn ${inRoute ? 'in' : ''}" data-toggle="${esc(r.id)}" aria-label="${inRoute ? 'Remove from route' : 'Add to route'}">${inRoute ? '✓' : '+'}</button>` : ''}
    </div>
  </li>`;
}
function bindRows(container) {
  container.onclick = (e) => {
    const t = e.target.closest('[data-toggle]');
    if (t) { toggleRoute(t.dataset.toggle); return; }
    const o = e.target.closest('[data-open]');
    if (o) openDetail(o.dataset.open);
  };
}
bindRows($('#list')); bindRows($('#near-list'));

function renderList() {
  const all = active().map((r) => ({ r, s: st(r) }));
  renderSummary(all); renderBanners(all);
  // tabs
  const tabs = [...new Set(all.map((x) => x.r.tab).filter(Boolean))].sort();
  const sel = $('#tab-filter');
  if (sel.options.length - 1 !== tabs.length) sel.innerHTML = '<option value="">All tabs</option>' + tabs.map((t) => `<option value="${esc(t)}">Tab ${esc(t)}</option>`).join('');
  sel.value = ui.tab;
  let items = all;
  if (ui.filter === 'geo') items = items.filter((x) => x.r.geo === 'approx' || x.r.geo === 'none');
  else if (ui.filter !== 'all') items = items.filter((x) => x.s.status === ui.filter);
  if (ui.tab) items = items.filter((x) => x.r.tab === ui.tab);
  if (ui.q) items = items.filter((x) => `${x.r.id} ${x.r.name} ${x.r.city} ${x.r.address}`.toLowerCase().includes(ui.q));
  const sorted = sortByImportance(items, ref());
  const where = here ? 'your location' : S.settings.home ? 'home base' : null;
  $('#sort-note').textContent = `${sorted.length} shown · Overdue → Never visited → Due soon → Current` + (where ? ` · nearest to ${where} first within each group (straight-line miles)` : ' · tap Locate to sort by distance');
  $('#list').innerHTML = sorted.slice(0, ui.shown).map((x) => rowHtml(x)).join('') || '<li class="card muted">No retailers match.</li>';
  $('#more-rows').hidden = sorted.length <= ui.shown;
}

// ---------------- detail ----------------
function openDetail(id) {
  ui.detailId = id;
  $('#detail').hidden = false;
  $('#detail').scrollTop = 0;
  renderDetail();
}
$('#detail').addEventListener('click', (e) => { if (e.target.closest('[data-close="detail"]')) { ui.detailId = null; $('#detail').hidden = true; render(); } });

function renderDetail() {
  const r = S.retailers[ui.detailId];
  if (!r) { ui.detailId = null; $('#detail').hidden = true; return; }
  const s = st(r), inRoute = S.route.stops.includes(r.id);
  const d = ref() && hasCoords(r) ? haversineMi(ref(), r) : null;
  const visits = [...(r.visits || [])].sort((a, b) => (a.date < b.date ? 1 : -1));
  $('#detail-body').innerHTML = `
    <div class="card">
      <p class="d-title">${esc(r.name)}</p>
      <span class="pill ${s.status}">${esc(statusText(s))}</span> ${r.archived ? '<span class="pill geo">Archived</span>' : ''}
      <dl class="kv">
        <dt>Retailer ID</dt><dd>${esc(r.id)}</dd>
        <dt>Address</dt><dd>${esc(r.address)}<br>${esc(r.city)}, ${esc(r.state || 'MO')}</dd>
        <dt>Tab</dt><dd>${esc(r.tab || '—')}</dd>
        <dt>Last visit</dt><dd>${fmtDate(s.last)}</dd>
        <dt>Next due</dt><dd>${s.due ? fmtDate(s.due) : 'Now (never visited)'}</dd>
        <dt>Location</dt><dd>${esc(geoLabel[r.geo] || 'Missing')}${d != null ? ` · ${miles(d)} away` : ''}</dd>
      </dl>
      <div class="btn-row">
        <button class="btn primary" id="d-done">Mark done</button>
        <button class="btn" id="d-nav">Navigate</button>
      </div>
      <div class="btn-row">
        <button class="btn" id="d-route">${inRoute ? 'Remove from route' : 'Add to route'}</button>
        <button class="btn" id="d-loc">Fix location</button>
      </div>
    </div>
    <div class="card">
      <h2>Notes</h2>
      <textarea id="d-notes" placeholder="Gate code, contact, hours, terminal notes…">${esc(r.notes || '')}</textarea>
    </div>
    <div class="card">
      <h2>Visit history</h2>
      ${visits.length ? `<ul class="visits">${visits.map((v) => `<li><span><b>${fmtDate(v.date)}</b>${v.note ? `<br><span class="muted">${esc(v.note)}</span>` : ''}</span><button class="link-btn" data-delvisit="${esc(v.id)}">Delete</button></li>`).join('')}</ul>` : '<p class="muted">No visits recorded yet.</p>'}
    </div>
    <div class="card">
      <div class="btn-row">
        <button class="btn" id="d-edit">Edit details</button>
        <button class="btn ghost ${r.archived ? '' : 'danger-text'}" id="d-archive">${r.archived ? 'Restore from archive' : 'Archive (store closed)'}</button>
      </div>
    </div>`;
  $('#d-done').onclick = () => markDoneModal(r.id);
  $('#d-nav').onclick = () => openMaps([r], 'single');
  $('#d-route').onclick = () => { toggleRoute(r.id); renderDetail(); };
  $('#d-loc').onclick = () => fixLocationModal(r.id);
  $('#d-edit').onclick = () => editModal(r.id);
  $('#d-archive').onclick = async () => {
    if (!r.archived && !confirm(`Archive ${r.name}? It will be hidden from lists and routes.`)) return;
    r.archived = !r.archived;
    if (r.archived) S.route.stops = S.route.stops.filter((x) => x !== r.id);
    await persist(); render();
  };
  $('#d-notes').onchange = async (e) => { r.notes = e.target.value; await persist(); toast('Notes saved'); };
  $$('[data-delvisit]').forEach((b) => (b.onclick = async () => {
    const v = r.visits.find((x) => x.id === b.dataset.delvisit);
    if (!v || !confirm(`Delete the visit on ${fmtDate(v.date)}?`)) return;
    r.visits = r.visits.filter((x) => x !== v);
    await persist(); render();
  }));
}

// ---------------- mark done ----------------
function markDoneModal(id) {
  const r = S.retailers[id];
  const weak = r.geo !== 'exact' && r.geo !== 'manual';
  const body = showModal(`
    <h2>Mark done</h2>
    <p class="muted small">${esc(r.name)} · #${esc(r.id)}</p>
    <label class="field">Visit date<input type="date" id="m-date" value="${today()}" max="${today()}"></label>
    <label class="field">Note (optional)<input type="text" id="m-note" placeholder="e.g. replaced printer head"></label>
    <label class="check"><input type="checkbox" id="m-loc" ${weak ? 'checked' : ''}>
      <span>Save my current position as this store's location${weak ? ' <b>(recommended: current location is approximate)</b>' : ''}<br><span class="muted tiny">Only check this if you're at the store.</span></span></label>
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button><button class="btn primary" id="m-save">Save visit</button></div>`);
  $('#m-save', body).onclick = async () => {
    const date = $('#m-date', body).value || today();
    if (date > today()) { toast("Visit date can't be in the future"); return; }
    const note = $('#m-note', body).value.trim(), saveLoc = $('#m-loc', body).checked;
    const before = JSON.parse(JSON.stringify(r));
    r.visits = r.visits || [];
    r.visits.push({ id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`, date, note, at: new Date().toISOString() });
    closeModal();
    let locMsg = '';
    if (saveLoc) {
      try { const p = await getLocation({ fresh: true }); Object.assign(r, { lat: p.lat, lng: p.lng, geo: 'manual' }); locMsg = ' · location saved'; }
      catch (e) { locMsg = ' · location not saved'; }
    }
    await persist(); render();
    toast(`Done: ${r.name}. Next due ${fmtDate(addMonths(lastVisit(r), 6))}${locMsg}`, {
      undo: async () => { S.retailers[id] = before; await persist(); render(); },
    });
  };
}

// ---------------- locations ----------------
function parseCoords(text) {
  const t = String(text);
  const m = t.match(/@(-?\d+\.\d+),\s*(-?\d+\.\d+)/) || t.match(/(-?\d{1,2}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)/);
  if (!m) return null;
  const lat = parseFloat(m[1]), lng = parseFloat(m[2]);
  if (Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
  return { lat, lng };
}
function fixLocationModal(id) {
  const r = S.retailers[id];
  const tc = townCenter(r.city);
  const body = showModal(`
    <h2>Fix location</h2>
    <p class="muted small">${esc(r.name)} — currently: <b>${esc(geoLabel[r.geo] || 'Missing')}</b>. Locations are used for distance and route order; Google Maps navigates by address.</p>
    <div class="btn-row"><button class="btn primary" id="f-here">I'm at the store — use my position</button></div>
    <label class="field">Or paste coordinates / a Google Maps link<input type="text" id="f-paste" placeholder="37.2089, -93.2923"></label>
    <div class="btn-row"><button class="btn" id="f-save">Save pasted location</button>${tc ? '<button class="btn ghost" id="f-town">Use town center</button>' : ''}</div>
    <p class="muted tiny">Tip: in Google Maps, long-press the store to drop a pin, then copy the coordinates shown.</p>
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button></div>`);
  const done = async (p, geo, msg) => { Object.assign(r, { lat: p.lat, lng: p.lng, geo }); await persist(); closeModal(); render(); toast(msg); };
  $('#f-here', body).onclick = async () => {
    try { const p = await getLocation({ fresh: true }); await done(p, 'manual', `Location saved (±${Math.round(p.acc)} m)`); }
    catch (e) { toast(e.message); }
  };
  $('#f-save', body).onclick = async () => {
    const p = parseCoords($('#f-paste', body).value);
    if (!p) { toast("Couldn't read coordinates from that"); return; }
    await done(p, 'manual', 'Location saved');
  };
  if (tc) $('#f-town', body).onclick = () => done(tc, 'approx', 'Set to town center');
}

function editModal(id) {
  const r = S.retailers[id];
  const body = showModal(`
    <h2>Edit details</h2>
    <label class="field">Name<input type="text" id="e-name" value="${esc(r.name)}"></label>
    <label class="field">Street address<input type="text" id="e-addr" value="${esc(r.address)}"></label>
    <label class="field">City<input type="text" id="e-city" value="${esc(r.city)}"></label>
    <label class="field">Tab<input type="text" id="e-tab" value="${esc(r.tab || '')}" inputmode="numeric"></label>
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button><button class="btn primary" id="e-save">Save</button></div>`);
  $('#e-save', body).onclick = async () => {
    const addr = $('#e-addr', body).value.trim(), city = $('#e-city', body).value.trim().toUpperCase();
    const moved = addr !== r.address || city !== r.city;
    r.name = $('#e-name', body).value.trim() || r.name;
    r.address = addr; r.city = city; r.tab = $('#e-tab', body).value.trim();
    if (moved && r.geo !== 'manual') { const tc = townCenter(city); Object.assign(r, tc ? { ...tc, geo: 'approx' } : { lat: null, lng: null, geo: 'none' }); }
    await persist(); closeModal(); render(); toast('Saved');
  };
}

function addRetailerModal() {
  const body = showModal(`
    <h2>Add retailer</h2>
    <label class="field">Retailer ID<input type="text" id="a-id" inputmode="numeric"></label>
    <label class="field">Name<input type="text" id="a-name"></label>
    <label class="field">Street address<input type="text" id="a-addr"></label>
    <label class="field">City<input type="text" id="a-city"></label>
    <label class="field">Tab<input type="text" id="a-tab" inputmode="numeric" placeholder="600"></label>
    <label class="check"><input type="checkbox" id="a-here"><span>I'm at the store — use my position as its location</span></label>
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button><button class="btn primary" id="a-save">Add</button></div>`);
  $('#a-save', body).onclick = async () => {
    const id = $('#a-id', body).value.trim();
    if (!id) return toast('Retailer ID is required');
    if (S.retailers[id]) return toast(`ID ${id} already exists (${S.retailers[id].name})`);
    const r = { id, name: $('#a-name', body).value.trim() || `Retailer ${id}`, address: $('#a-addr', body).value.trim(), city: $('#a-city', body).value.trim().toUpperCase(), state: 'MO', tab: $('#a-tab', body).value.trim(), visits: [], notes: '', lat: null, lng: null, geo: 'none', addedAt: new Date().toISOString() };
    if ($('#a-here', body).checked) {
      try { const p = await getLocation({ fresh: true }); Object.assign(r, { lat: p.lat, lng: p.lng, geo: 'manual' }); } catch (e) { toast(e.message); }
    }
    if (r.geo === 'none') { const tc = townCenter(r.city); if (tc) Object.assign(r, tc, { geo: 'approx' }); }
    S.retailers[id] = r;
    await persist(); closeModal(); render(); toast(`Added ${r.name}`);
  };
}

// ---------------- route ----------------
async function toggleRoute(id) {
  const i = S.route.stops.indexOf(id);
  if (i >= 0) S.route.stops.splice(i, 1);
  else S.route.stops.push(id);
  await persist(false); render();
  if (i < 0) toast(`Added to route (${S.route.stops.length} stop${S.route.stops.length === 1 ? '' : 's'})`);
}
function endPoint() {
  if (S.route.end === 'start' && S.route.start) return S.route.start;
  if (S.route.end === 'home' && S.settings.home) return S.settings.home;
  return null;
}
async function optimizeRoute({ quiet = false } = {}) {
  let start = here;
  if (!start) { try { start = await getLocation(); } catch { start = S.settings.home || null; } }
  if (!start) { toast('Need your location (or a home base) to optimize'); return; }
  S.route.start = { lat: start.lat, lng: start.lng };
  const rs = S.route.stops.map((id) => S.retailers[id]).filter(Boolean);
  const withC = rs.filter(hasCoords), without = rs.filter((r) => !hasCoords(r));
  const order = optimizeOrder(withC, start, endPoint());
  S.route.stops = order.map((i) => withC[i].id).concat(without.map((r) => r.id));
  S.route.builtAt = new Date().toISOString();
  await persist(false); render();
  if (!quiet) toast(without.length ? `Optimized. ${plural(without.length, 'stop')} without a location left at the end.` : 'Route optimized');
}
async function autoBuild() {
  let start = here;
  if (!start) { try { start = await getLocation({ fresh: true }); } catch (e) { toast(e.message); return; } }
  const count = parseInt($('#auto-count').value, 10);
  const cands = active().map((r) => ({ r, s: st(r) })).filter((x) => needsVisit(x.s.status) && lastVisit(x.r) !== today());
  const picked = autoPick(cands, start, count);
  if (!picked.length) { toast('No stores needing a visit within 75 miles'); return; }
  if (S.route.stops.length && !confirm(`Replace the current route (${S.route.stops.length} stops) with ${picked.length} new stops?`)) return;
  S.route.stops = picked.map((x) => x.r.id);
  await optimizeRoute({ quiet: true });
  setView('route');
  toast(`Built a ${picked.length}-stop route`);
}
$('#btn-auto').onclick = autoBuild;
$('#btn-optimize').onclick = () => optimizeRoute();
$('#btn-clear-route').onclick = async () => { if (!confirm('Clear all stops from the route?')) return; S.route.stops = []; await persist(false); render(); };
$$('#route-end button').forEach((b) => (b.onclick = async () => { S.route.end = b.dataset.end; await persist(false); await optimizeRoute({ quiet: true }); render(); }));

function routeSequence() {
  const stops = S.route.stops.map((id) => S.retailers[id]).filter(Boolean);
  const e = endPoint();
  if (e) stops.push({ __point: true, lat: e.lat, lng: e.lng, name: S.route.end === 'home' ? 'Home' : 'Back to start' });
  return stops;
}
function openMaps(leg, mode) {
  const m = mode === 'single' ? S.settings.mapsMode || 'app' : mode;
  if (m === 'app') {
    window.location.href = googleAppUrl(leg);
  } else {
    const url = mode === 'single' ? googleSingleUrl(leg[0]) : googleWebUrl(leg);
    window.open(url, '_blank', 'noopener');
  }
}

function renderRoute() {
  const ids = S.route.stops;
  $('#route-empty').hidden = !!ids.length; $('#route-body').hidden = !ids.length;
  if (!ids.length) return;
  $$('#route-end button').forEach((b) => {
    b.classList.toggle('on', b.dataset.end === S.route.end);
    b.disabled = b.dataset.end === 'home' && !S.settings.home;
  });
  const seq = routeSequence(), stops = seq.filter((x) => !x.__point);
  const legs = splitLegs(seq);
  // Don't waste a whole Google Maps leg on just the drive back.
  let tailNote = '';
  const lastLeg = legs[legs.length - 1];
  if (legs.length > 1 && lastLeg.length === 1 && lastLeg[0].__point) { legs.pop(); tailNote = ` After the last stop, head ${S.route.end === 'home' ? 'home' : 'back to your start point'}.`; }
  const start = S.route.start;
  let est = '';
  if (start) {
    let d = 0, prev = start;
    seq.filter(hasCoords).forEach((p) => { d += haversineMi(prev, p); prev = p; });
    est = ` · about ${Math.round(d * ROAD_FACTOR)} road miles (estimate)`;
  }
  const doneN = stops.filter((r) => lastVisit(r) === today()).length;
  $('#route-stats').innerHTML = `<b>${plural(stops.length, 'stop')}</b>${est} · ${plural(legs.length, 'Google Maps leg')}${doneN ? ` · <b>${doneN} done today</b>` : ''}`;
  let idx = 0;
  $('#route-legs').innerHTML = legs.map((leg, li) => {
    const a = idx + 1; idx += leg.length;
    return `<div class="leg"><h3>Leg ${li + 1} · stops ${a}–${idx}</h3>
      <div class="muted small">${leg.map((x) => esc(x.name)).join(' → ')}</div>
      <div class="btn-row"><button class="btn primary" data-leg="${li}" data-mode="app">Open in Google Maps</button><button class="btn" data-leg="${li}" data-mode="web">Web link</button></div></div>`;
  }).join('') + `<p class="muted tiny">Each leg starts from wherever you are when you open it.${tailNote} If "Open in Google Maps" does nothing, use "Web link".</p>`;
  $$('#route-legs [data-leg]').forEach((b) => (b.onclick = () => openMaps(legs[+b.dataset.leg], b.dataset.mode)));

  $('#route-list').innerHTML = stops.map((r, i) => {
    const s = st(r), done = lastVisit(r) === today();
    return `<li class="rowi s-${s.status}"><span class="num">${i + 1}</span>
      <div class="main" data-open="${esc(r.id)}"><div class="name">${esc(r.name)}</div>
        <div class="sub">${esc(r.address)}, ${esc(r.city)}</div>
        <div class="meta">${done ? '<span class="pill done">Done today</span>' : `<span class="pill ${s.status}">${esc(statusText(s))}</span>`}${hasCoords(r) ? '' : '<span class="pill geo">No location</span>'}</div></div>
      <div class="route-actions">
        ${done ? '' : `<button class="mini" data-rdone="${esc(r.id)}" aria-label="Mark done"><svg viewBox="0 0 24 24"><path d="M5 12l5 5 9-10"/></svg></button>`}
        <button class="mini" data-up="${i}" aria-label="Move up" ${i === 0 ? 'disabled' : ''}><svg viewBox="0 0 24 24"><path d="M6 15l6-6 6 6"/></svg></button>
        <button class="mini" data-down="${i}" aria-label="Move down" ${i === stops.length - 1 ? 'disabled' : ''}><svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg></button>
        <button class="mini" data-rm="${esc(r.id)}" aria-label="Remove"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      </div></li>`;
  }).join('');
  const rl = $('#route-list');
  rl.onclick = async (e) => {
    const b = e.target.closest('button');
    if (b?.dataset.rdone) return markDoneModal(b.dataset.rdone);
    if (b?.dataset.rm) { S.route.stops = S.route.stops.filter((x) => x !== b.dataset.rm); await persist(false); return render(); }
    if (b?.dataset.up || b?.dataset.down) {
      const i = +(b.dataset.up ?? b.dataset.down), j = b.dataset.up !== undefined ? i - 1 : i + 1;
      const a = S.route.stops; [a[i], a[j]] = [a[j], a[i]]; await persist(false); return render();
    }
    const o = e.target.closest('[data-open]'); if (o) openDetail(o.dataset.open);
  };
  drawRouteMap(seq);
}

// ---------------- maps (Leaflet) ----------------
const COLORS = () => {
  const cs = getComputedStyle(document.documentElement);
  return { overdue: cs.getPropertyValue('--overdue').trim(), never: cs.getPropertyValue('--never').trim(), soon: cs.getPropertyValue('--soon').trim(), current: cs.getPropertyValue('--current').trim() };
};
function makeMap(el) {
  if (!window.L) return null;
  const m = L.map(el, { zoomControl: true, attributionControl: true });
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap contributors' }).addTo(m);
  m.setView([37.2, -93.3], 8);
  return m;
}
function meMarker(layer) {
  if (here) L.marker([here.lat, here.lng], { icon: L.divIcon({ className: 'me-marker', iconSize: [16, 16] }), interactive: false }).addTo(layer);
}
function drawRouteMap(seq) {
  if (!window.L) return;
  if (!routeMap) { routeMap = makeMap($('#route-map')); routeLayer = L.layerGroup().addTo(routeMap); }
  routeLayer.clearLayers();
  setTimeout(() => routeMap.invalidateSize(), 0);
  const pts = [];
  const start = S.route.start;
  if (start) pts.push([start.lat, start.lng]);
  let n = 0;
  seq.forEach((p) => {
    if (!hasCoords(p)) return;
    pts.push([p.lat, p.lng]);
    if (p.__point) return;
    n++;
    L.marker([p.lat, p.lng], { icon: L.divIcon({ className: 'num-marker', html: String(S.route.stops.indexOf(p.id) + 1), iconSize: [26, 26] }) })
      .bindPopup(`<b>${esc(p.name)}</b><br>${esc(p.address)}, ${esc(p.city)}`).addTo(routeLayer);
  });
  meMarker(routeLayer);
  if (pts.length > 1) L.polyline(pts, { color: getComputedStyle(document.documentElement).getPropertyValue('--accent').trim(), weight: 3, opacity: 0.8, dashArray: '6 6' }).addTo(routeLayer);
  if (pts.length) routeMap.fitBounds(L.latLngBounds(pts).pad(0.15), { maxZoom: 14 });
}

function renderNear() {
  const loc = $('#near-loc');
  if (!here) {
    loc.textContent = S.settings.home ? 'Using home base — tap Refresh for your current location.' : 'Tap Refresh to find your location.';
  } else {
    const ago = Math.round((Date.now() - here.ts) / 60000);
    loc.textContent = `Your location ${ago < 1 ? 'just now' : `${ago} min ago`} (±${Math.round(here.acc)} m)`;
  }
  const origin = ref();
  const radius = +$('#near-radius').value, show = $('#near-show').value;
  let items = active().map((r) => ({ r, s: st(r) })).filter((x) => hasCoords(x.r));
  if (show === 'need') items = items.filter((x) => needsVisit(x.s.status) && lastVisit(x.r) !== today());
  if (origin) {
    items = items.map((x) => ({ ...x, _d: haversineMi(origin, x.r) })).filter((x) => x._d <= radius).sort((a, b) => a._d - b._d);
  } else items = [];
  $('#near-list').innerHTML = origin
    ? items.slice(0, 200).map((x) => rowHtml(x)).join('') || `<li class="card muted">Nothing ${show === 'need' ? 'needing a visit ' : ''}within ${radius} miles.</li>`
    : '';
  // map
  if (!window.L) return;
  if (!nearMap) {
    nearMap = makeMap($('#near-map')); nearLayer = L.layerGroup().addTo(nearMap);
    nearMap.on('popupopen', (e) => { const b = e.popup.getElement()?.querySelector('[data-open]'); if (b) b.onclick = () => openDetail(b.dataset.open); });
  }
  setTimeout(() => nearMap.invalidateSize(), 0);
  nearLayer.clearLayers();
  const c = COLORS();
  items.slice(0, 300).forEach((x) => {
    L.circleMarker([x.r.lat, x.r.lng], { radius: 8, color: '#fff', weight: 2, fillColor: c[x.s.status], fillOpacity: 0.95 })
      .bindPopup(`<b>${esc(x.r.name)}</b><br>${esc(statusText(x.s))} · ${miles(x._d)}<br><button class="btn small" data-open="${esc(x.r.id)}" style="margin-top:6px">Open</button>`)
      .addTo(nearLayer);
  });
  meMarker(nearLayer);
  if (origin) {
    const pts = [[origin.lat, origin.lng], ...items.slice(0, 40).map((x) => [x.r.lat, x.r.lng])];
    nearMap.fitBounds(L.latLngBounds(pts).pad(0.1), { maxZoom: 13 });
  }
}
$('#near-refresh').onclick = () => locateAndRender({ fresh: true });
$('#near-radius').onchange = renderNear; $('#near-show').onchange = renderNear;

// ---------------- files: backup / restore / import ----------------
async function deliverFile(blob, filename, { preferShare = true } = {}) {
  const file = new File([blob], filename, { type: blob.type });
  if (preferShare && navigator.canShare && navigator.canShare({ files: [file] })) {
    try { await navigator.share({ files: [file], title: filename }); return true; }
    catch (e) { if (e.name === 'AbortError') return false; }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = filename;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
  return true;
}
async function exportBackup() {
  const payload = { type: 'pm-tracker-backup', version: 1, appVersion: APP_VERSION, exportedAt: new Date().toISOString(), state: S };
  const blob = new Blob([JSON.stringify(payload)], { type: 'application/json' });
  const ok = await deliverFile(blob, `pm-tracker-backup-${today()}.json`);
  if (!ok) return;
  S.meta.lastBackupAt = new Date().toISOString(); S.meta.changesSinceBackup = 0;
  await persist(false); render(); toast('Backup created');
}
$('#btn-backup').onclick = exportBackup;

async function readFile(file) {
  if (/\.xlsx$/i.test(file.name)) return { kind: 'xlsx', data: await file.arrayBuffer() };
  const text = await file.text();
  try { return { kind: 'json', data: JSON.parse(text) }; } catch { throw new Error("That file isn't a backup, retailer list or .xlsx report."); }
}
async function handleFile(file, { restoreOnly = false } = {}) {
  if (!file) return;
  try {
    const f = await readFile(file);
    if (f.kind === 'json' && f.data?.type === 'pm-tracker-backup') return restoreBackup(f.data);
    if (restoreOnly) throw new Error("That isn't a PM Tracker backup file.");
    if (f.kind === 'json' && f.data?.type === 'pm-tracker-retailers') return previewMerge(f.data.retailers, 'retailer list');
    if (f.kind === 'xlsx') return importXlsx(f.data, file.name);
    throw new Error('Unrecognized file.');
  } catch (e) { toast(e.message); }
}
['#welcome-file', '#import-file'].forEach((s) => ($(s).onchange = (e) => { handleFile(e.target.files[0]); e.target.value = ''; }));
$('#restore-file').onchange = (e) => { handleFile(e.target.files[0], { restoreOnly: true }); e.target.value = ''; };

async function restoreBackup(b) {
  const st2 = b.state;
  if (!st2 || typeof st2.retailers !== 'object') return toast('Backup file is damaged.');
  const n = Object.keys(st2.retailers).length, visits = Object.values(st2.retailers).reduce((a, r) => a + (r.visits?.length || 0), 0);
  const cur = Object.keys(S.retailers).length;
  if (cur && !confirm(`Replace everything on this phone (${cur} retailers) with the backup from ${new Date(b.exportedAt).toLocaleString()} (${n} retailers, ${visits} visits)?`)) return;
  S = { ...emptyState(), ...st2, settings: { ...emptyState().settings, ...st2.settings }, meta: { ...emptyState().meta, ...st2.meta, lastBackupAt: b.exportedAt, changesSinceBackup: 0 } };
  await persist(false); ui.detailId = null; $('#detail').hidden = true; setView('list');
  toast(`Restored ${n} retailers and ${visits} visits`);
}

async function importXlsx(buf, name) {
  for (let i = 0; i < 50 && !window.XLSX; i++) await new Promise((r) => setTimeout(r, 100));
  if (!window.XLSX) throw new Error('Spreadsheet reader failed to load.');
  const wb = XLSX.read(buf, { type: 'array' });
  const usable = wb.SheetNames.filter((n) => {
    const rows = XLSX.utils.sheet_to_json(wb.Sheets[n], { header: 1, blankrows: false });
    return rows.slice(0, 15).some((r) => r && r.some((c) => String(c ?? '').trim().toLowerCase() === 'retailer #'));
  });
  if (!usable.length) throw new Error('No sheets with a "Retailer #" column found.');
  const defaults = ['600', '610', '620', '630', '640'];
  const pre = usable.some((n) => defaults.includes(n.trim())) ? (n) => defaults.includes(n.trim()) : () => true;
  const body = showModal(`
    <h2>Import ${esc(name)}</h2>
    <p class="muted small">Choose which tabs to import. Dates in the report are ignored — only your own visits count.</p>
    <div class="filters" style="flex-wrap:wrap">${usable.map((n) => `<label class="check" style="margin:4px 10px 4px 0"><input type="checkbox" value="${esc(n)}" ${pre(n) ? 'checked' : ''}> ${esc(n)}</label>`).join('')}</div>
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button><button class="btn primary" id="x-next">Next</button></div>`);
  $('#x-next', body).onclick = () => {
    const tabs = $$('input[type=checkbox]:checked', body).map((c) => c.value);
    if (!tabs.length) return toast('Pick at least one tab');
    const seen = new Map();
    tabs.forEach((t) => retailersFromRows(XLSX.utils.sheet_to_json(wb.Sheets[t], { header: 1, blankrows: false }), t.trim()).forEach((r) => { if (!seen.has(r.id)) seen.set(r.id, r); }));
    previewMerge([...seen.values()], 'report');
  };
}

function previewMerge(list, label) {
  if (!Array.isArray(list) || !list.length) return toast('No retailers found in that file.');
  const add = [], upd = [], same = [];
  for (const inc of list) {
    if (!inc?.id) continue;
    const id = String(inc.id), cur = S.retailers[id];
    if (!cur) add.push(inc);
    else if (cur.name !== inc.name || cur.address !== inc.address || cur.city !== inc.city || (hasCoords(inc) && inc.geo === 'exact' && (cur.geo === 'none' || cur.geo === 'approx'))) upd.push(inc);
    else same.push(inc);
  }
  const body = showModal(`
    <h2>Import ${esc(label)}</h2>
    <dl class="kv"><dt>New retailers</dt><dd>${add.length}</dd><dt>Updated name/address</dt><dd>${upd.length}</dd><dt>Unchanged</dt><dd>${same.length}</dd></dl>
    <p class="muted tiny">Existing visits and notes are kept. Retailers missing from this file are not removed.</p>
    ${upd.length ? `<details class="small" style="margin-top:8px"><summary>Show updates</summary><ul>${upd.slice(0, 50).map((u) => { const c = S.retailers[u.id]; return `<li>#${esc(u.id)}: ${esc(c.name)}, ${esc(c.address)} → ${esc(u.name)}, ${esc(u.address)}</li>`; }).join('')}</ul></details>` : ''}
    <div class="btn-row"><button class="btn ghost" data-close="modal">Cancel</button><button class="btn primary" id="i-go" ${add.length + upd.length ? '' : 'disabled'}>Import</button></div>`);
  $('#i-go', body).onclick = async () => {
    for (const inc of add) {
      const r = { id: String(inc.id), name: inc.name || '', address: inc.address || '', city: (inc.city || '').toUpperCase(), state: inc.state || 'MO', tab: inc.tab ? String(inc.tab) : '', visits: [], notes: '', lat: null, lng: null, geo: 'none', addedAt: new Date().toISOString() };
      if (hasCoords(inc)) Object.assign(r, { lat: inc.lat, lng: inc.lng, geo: inc.geo || 'approx' });
      S.retailers[r.id] = r;
    }
    for (const inc of add) { const r = S.retailers[String(inc.id)]; if (r.geo === 'none') { const tc = townCenter(r.city); if (tc) Object.assign(r, tc, { geo: 'approx' }); } }
    for (const inc of upd) {
      const r = S.retailers[String(inc.id)];
      const moved = inc.address !== r.address || inc.city !== r.city;
      Object.assign(r, { name: inc.name || r.name, address: inc.address || r.address, city: inc.city || r.city, tab: inc.tab ? String(inc.tab) : r.tab });
      if (hasCoords(inc) && inc.geo === 'exact' && r.geo !== 'manual') Object.assign(r, { lat: inc.lat, lng: inc.lng, geo: 'exact' });
      else if (moved && r.geo !== 'manual') { const tc = townCenter(r.city); Object.assign(r, tc ? { ...tc, geo: 'approx' } : { lat: null, lng: null, geo: 'none' }); }
    }
    await persist(); closeModal(); setView('list');
    toast(`Imported: ${add.length} new, ${upd.length} updated`);
  };
}
$('#btn-add').onclick = addRetailerModal;

$('#btn-show-archived').onclick = () => {
  const arch = Object.values(S.retailers).filter((r) => r.archived);
  const body = showModal(`<h2>Archived retailers</h2>${arch.length ? `<ul class="visits">${arch.map((r) => `<li><span><b>${esc(r.name)}</b><br><span class="muted">#${esc(r.id)} · ${esc(r.city)}</span></span><button class="btn small" data-unarch="${esc(r.id)}">Restore</button></li>`).join('')}</ul>` : '<p class="muted">None.</p>'}<div class="btn-row"><button class="btn" data-close="modal">Close</button></div>`);
  $$('[data-unarch]', body).forEach((b) => (b.onclick = async () => { S.retailers[b.dataset.unarch].archived = false; await persist(); closeModal(); render(); toast('Restored'); }));
};

// ---------------- reminders ----------------
function icsGroups() {
  const t = today(), by = new Map();
  for (const r of active()) {
    const s = st(r);
    if (!s.due || s.due < t) continue;
    const done = S.meta.icsExported[s.due] || [];
    if (done.includes(r.id)) continue;
    if (!by.has(s.due)) by.set(s.due, []);
    by.get(s.due).push(r);
  }
  return [...by.entries()].sort().map(([due, retailers]) => ({ due, retailers, seq: S.meta.icsExportSeq?.[due] || 0 }));
}
$('#btn-ics').onclick = async () => {
  const groups = icsGroups();
  if (!groups.length) return toast('No new due dates to add. Mark some visits done first.');
  const ics = buildIcs(groups, S.settings.leadDays);
  await deliverFile(new Blob([ics], { type: 'text/calendar' }), `pm-due-dates-${today()}.ics`, { preferShare: false });
  S.meta.icsExportSeq ||= {};
  groups.forEach((g) => {
    S.meta.icsExported[g.due] = [...(S.meta.icsExported[g.due] || []), ...g.retailers.map((r) => r.id)];
    S.meta.icsExportSeq[g.due] = (S.meta.icsExportSeq[g.due] || 0) + 1;
  });
  await persist(false); renderMore();
  toast(`Exported ${plural(groups.length, 'due date')} — tap "Add All" in the calendar preview`);
};
function badgeCount() {
  return active().map(st).filter((s) => s.status === 'overdue' || (s.status === 'soon' && s.daysToDue <= 7)).length;
}
function updateBadge() {
  try {
    if (!('setAppBadge' in navigator)) return;
    const n = badgeCount();
    (n ? navigator.setAppBadge(n) : navigator.clearAppBadge()).catch(() => {});
  } catch {}
}
$('#btn-badge').onclick = async () => {
  if (!('Notification' in window)) return toast('Add the app to your Home Screen first, then try again.');
  const p = await Notification.requestPermission();
  updateBadge(); renderMore();
  toast(p === 'granted' ? 'Badge enabled' : 'Permission not granted');
};
$('#soon-days').onchange = async (e) => { S.settings.soonDays = +e.target.value; await persist(false); toast('Saved'); };

// ---------------- more ----------------
function renderMore() {
  const all = Object.values(S.retailers), act = all.filter((r) => !r.archived);
  const visits = all.reduce((a, r) => a + (r.visits?.length || 0), 0);
  const geoWeak = act.filter((r) => r.geo === 'approx' || r.geo === 'none').length;
  $('#backup-status').textContent = S.meta.lastBackupAt ? `Last backup: ${new Date(S.meta.lastBackupAt).toLocaleString()} · ${plural(S.meta.changesSinceBackup || 0, 'change')} since.` : 'No backup made yet.';
  $('#data-status').textContent = `${act.length} active retailers, ${all.length - act.length} archived, ${visits} visits recorded. ${geoWeak} with approximate or missing locations.`;
  const pending = icsGroups().length;
  const perm = 'Notification' in window ? Notification.permission : 'unavailable';
  $('#reminder-status').textContent = `${pending} due date${pending === 1 ? '' : 's'} not yet in your calendar. Icon badge: ${perm === 'granted' ? 'on' : perm === 'unavailable' ? 'needs Home Screen install' : 'off'} (shows overdue + due within 7 days: ${badgeCount()}).`;
  $('#soon-days').value = String(S.settings.soonDays);
  $('#home-status').textContent = S.settings.home ? `Set: ${S.settings.home.lat.toFixed(4)}, ${S.settings.home.lng.toFixed(4)}` : 'Not set.';
  $('#auto-locate').checked = !!S.settings.autoLocate;
  $('#maps-mode').value = S.settings.mapsMode || 'app';
  navigator.storage?.persisted?.().then((p) => { $('#about').textContent = `PM Tracker v${APP_VERSION} · storage ${p ? 'protected from cleanup' : 'not yet protected (add to Home Screen)'} · data stays on this device.`; })
    .catch(() => { $('#about').textContent = `PM Tracker v${APP_VERSION}`; });
}
$('#btn-home-set').onclick = async () => {
  try { const p = await getLocation({ fresh: true }); S.settings.home = { lat: p.lat, lng: p.lng }; await persist(false); renderMore(); toast('Home base saved'); }
  catch (e) { toast(e.message); }
};
$('#btn-home-clear').onclick = async () => { S.settings.home = null; if (S.route.end === 'home') S.route.end = 'last'; await persist(false); renderMore(); };
$('#auto-locate').onchange = async (e) => { S.settings.autoLocate = e.target.checked; await persist(false); };
$('#maps-mode').onchange = async (e) => { S.settings.mapsMode = e.target.value; await persist(false); };
$('#btn-erase').onclick = async () => {
  if (!confirm('Erase ALL retailers, visits and notes from this phone?')) return;
  if (!confirm('This cannot be undone. Erase everything?')) return;
  S = emptyState(); await persist(false); setView('list'); toast('All data erased');
};

// ---------------- service worker ----------------
function registerSW() {
  if (!('serviceWorker' in navigator) || location.protocol === 'file:') return;
  navigator.serviceWorker.register('sw.js').then((reg) => {
    const offer = (w) => { $('#update-banner').hidden = false; $('#btn-update').onclick = () => w.postMessage('skipWaiting'); };
    if (reg.waiting && navigator.serviceWorker.controller) offer(reg.waiting);
    reg.addEventListener('updatefound', () => {
      const w = reg.installing;
      w?.addEventListener('statechange', () => { if (w.state === 'installed' && navigator.serviceWorker.controller) offer(w); });
    });
    setInterval(() => reg.update().catch(() => {}), 60 * 60 * 1000);
  }).catch(() => {});
  let reloaded = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => { if (!reloaded) { reloaded = true; location.reload(); } });
}

// ---------------- boot ----------------
async function init() {
  S = (await loadState()) || emptyState();
  const base = emptyState();
  S.settings = { ...base.settings, ...S.settings }; S.meta = { ...base.meta, ...S.meta }; S.route = { ...base.route, ...S.route };
  await saveState(S);
  requestPersistence();
  registerSW();
  setView('list');
  updateBadge();
  if (S.settings.autoLocate && Object.keys(S.retailers).length) locateAndRender().catch(() => {});
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') render(); });
}
window.__pm = { get state() { return S; }, setHere: (p) => { here = { acc: 10, ts: Date.now(), ...p }; render(); } }; // test hook
init();
