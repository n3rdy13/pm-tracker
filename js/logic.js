// Pure logic: dates, status, sorting, distance, route optimisation, Google Maps links, calendar export.
// No DOM access here so it can be unit-tested in Node.

export const CYCLE_MONTHS = 6;
export const MAX_STOPS_PER_LEG = 9; // Google Maps limit the user works with

// ---------- dates (all dates are local 'YYYY-MM-DD' strings) ----------
export function todayStr(d = new Date()) {
  const y = d.getFullYear(), m = String(d.getMonth() + 1).padStart(2, '0'), day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
function parse(s) { const [y, m, d] = s.split('-').map(Number); return { y, m, d }; }
export function addMonths(s, n) {
  const { y, m, d } = parse(s);
  const total = (y * 12 + (m - 1)) + n;
  const ny = Math.floor(total / 12), nm = total % 12;          // nm 0-based
  const last = new Date(ny, nm + 1, 0).getDate();              // clamp Aug 31 + 6 -> Feb 28/29
  return `${ny}-${String(nm + 1).padStart(2, '0')}-${String(Math.min(d, last)).padStart(2, '0')}`;
}
export function daysBetween(a, b) { // b - a in whole days
  const pa = parse(a), pb = parse(b);
  return Math.round((Date.UTC(pb.y, pb.m - 1, pb.d) - Date.UTC(pa.y, pa.m - 1, pa.d)) / 86400000);
}
export function fmtDate(s) {
  if (!s) return '—';
  const { y, m, d } = parse(s);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

// ---------- status ----------
export const STATUS = {
  overdue: { rank: 0, label: 'Overdue' },
  never:   { rank: 1, label: 'Never visited' },
  soon:    { rank: 2, label: 'Due soon' },
  current: { rank: 3, label: 'Current' },
};
export function lastVisit(r) {
  if (!r.visits || !r.visits.length) return null;
  return r.visits.reduce((mx, v) => (v.date > mx ? v.date : mx), r.visits[0].date);
}
export function computeStatus(r, today, soonDays = 30) {
  const last = lastVisit(r);
  if (!last) return { status: 'never', last: null, due: null, daysToDue: null };
  const due = addMonths(last, CYCLE_MONTHS);
  const daysToDue = daysBetween(today, due);
  const status = daysToDue < 0 ? 'overdue' : daysToDue <= soonDays ? 'soon' : 'current';
  return { status, last, due, daysToDue };
}
export const needsVisit = (st) => st === 'overdue' || st === 'never' || st === 'soon';

// ---------- distance ----------
export function haversineMi(a, b) {
  const R = 3958.8, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(x)));
}
export const ROAD_FACTOR = 1.25; // straight line -> rough road miles, for estimates only
export const hasCoords = (r) => r && typeof r.lat === 'number' && typeof r.lng === 'number';

// ---------- importance sort ----------
// Overdue (most overdue first) -> Never visited -> Due soon (soonest first) -> Current (soonest first).
// Ties (and the whole "never visited" group) are broken by distance from `ref` when known, then city/name.
export function sortByImportance(items, ref) {
  const dist = (r) => (ref && hasCoords(r) ? haversineMi(ref, r) : Infinity);
  return items
    .map((x) => ({ ...x, _d: dist(x.r) }))
    .sort((a, b) => {
      const ra = STATUS[a.s.status].rank, rb = STATUS[b.s.status].rank;
      if (ra !== rb) return ra - rb;
      if (a.s.status !== 'never' && a.s.daysToDue !== b.s.daysToDue) return a.s.daysToDue - b.s.daysToDue;
      if (a._d !== b._d) return a._d - b._d;
      return (a.r.city + a.r.name).localeCompare(b.r.city + b.r.name);
    });
}

// ---------- route optimisation ----------
// points: [{lat,lng}], start: {lat,lng}, end: {lat,lng}|null (null = finish at last stop)
// returns order (indices into points) minimising straight-line distance.
function pathLen(order, pts, start, end) {
  let d = 0, prev = start;
  for (const i of order) { d += haversineMi(prev, pts[i]); prev = pts[i]; }
  if (end) d += haversineMi(prev, end);
  return d;
}
function heldKarp(pts, start, end) {
  const n = pts.length, N = 1 << n;
  const dp = new Float64Array(N * n).fill(Infinity), par = new Int8Array(N * n).fill(-1);
  const D = pts.map((a) => pts.map((b) => haversineMi(a, b)));
  for (let i = 0; i < n; i++) dp[(1 << i) * n + i] = haversineMi(start, pts[i]);
  for (let mask = 1; mask < N; mask++) {
    for (let i = 0; i < n; i++) {
      const cur = dp[mask * n + i];
      if (!(mask & (1 << i)) || cur === Infinity) continue;
      for (let j = 0; j < n; j++) {
        if (mask & (1 << j)) continue;
        const nm = mask | (1 << j), v = cur + D[i][j];
        if (v < dp[nm * n + j]) { dp[nm * n + j] = v; par[nm * n + j] = i; }
      }
    }
  }
  let best = Infinity, last = -1, full = N - 1;
  for (let i = 0; i < n; i++) {
    const v = dp[full * n + i] + (end ? haversineMi(pts[i], end) : 0);
    if (v < best) { best = v; last = i; }
  }
  const order = []; let mask = full, i = last;
  while (i !== -1) { order.push(i); const p = par[mask * n + i]; mask &= ~(1 << i); i = p; }
  return order.reverse();
}
function twoOpt(order, pts, start, end) {
  let best = order.slice(), bestLen = pathLen(best, pts, start, end), improved = true, guard = 0;
  while (improved && guard++ < 200) {
    improved = false;
    for (let i = 0; i < best.length - 1; i++) {
      for (let k = i + 1; k < best.length; k++) {
        const cand = best.slice(0, i).concat(best.slice(i, k + 1).reverse(), best.slice(k + 1));
        const len = pathLen(cand, pts, start, end);
        if (len + 1e-9 < bestLen) { best = cand; bestLen = len; improved = true; }
      }
    }
  }
  return best;
}
export function optimizeOrder(pts, start, end = null) {
  const n = pts.length;
  if (n <= 1) return pts.map((_, i) => i);
  if (n <= 12) return heldKarp(pts, start, end);
  // nearest neighbour seed + 2-opt
  const left = new Set(pts.map((_, i) => i)), order = []; let cur = start;
  while (left.size) {
    let bi = -1, bd = Infinity;
    for (const i of left) { const d = haversineMi(cur, pts[i]); if (d < bd) { bd = d; bi = i; } }
    order.push(bi); left.delete(bi); cur = pts[bi];
  }
  return twoOpt(order, pts, start, end);
}
export function routeMiles(orderedPts, start, end = null) {
  return pathLen(orderedPts.map((_, i) => i), orderedPts, start, end);
}

// Auto-pick: chain nearest-next from the start among stores that need a visit.
// Overdue stores count as 30% closer so they get pulled in first.
export function autoPick(candidates, start, count, maxMiles = 75) {
  const pool = candidates.filter((c) => hasCoords(c.r) && haversineMi(start, c.r) <= maxMiles);
  const chosen = []; let cur = start;
  while (chosen.length < count && pool.length) {
    let bi = -1, bs = Infinity;
    pool.forEach((c, i) => {
      const w = c.s.status === 'overdue' ? 0.7 : c.s.status === 'soon' ? 1.3 : 1;
      const score = haversineMi(cur, c.r) * w;
      if (score < bs) { bs = score; bi = i; }
    });
    const [c] = pool.splice(bi, 1); chosen.push(c); cur = c.r;
  }
  return chosen;
}

// ---------- Google Maps ----------
export function mapsQuery(r) {
  // A pin the user set by hand is more reliable than the street address.
  if (r.geo === 'manual' && hasCoords(r)) return `${r.lat},${r.lng}`;
  return [r.address, r.city, r.state || 'MO'].filter(Boolean).join(', ');
}
// stops: array of retailers (or {lat,lng,label} for a return point), already ordered.
export function splitLegs(stops, size = MAX_STOPS_PER_LEG) {
  const legs = [];
  for (let i = 0; i < stops.length; i += size) legs.push(stops.slice(i, i + size));
  return legs;
}
const q = (r) => (r.__point ? `${r.lat},${r.lng}` : mapsQuery(r));
export function googleWebUrl(leg) {
  const dest = leg[leg.length - 1], way = leg.slice(0, -1);
  const p = new URLSearchParams({ api: '1', destination: q(dest), travelmode: 'driving' });
  if (way.length) p.set('waypoints', way.map(q).join('|'));
  return 'https://www.google.com/maps/dir/?' + p.toString(); // no origin = start from current location
}
export function googleAppUrl(leg) {
  const daddr = leg.map((r) => encodeURIComponent(q(r))).join('+to:');
  return `comgooglemaps://?daddr=${daddr}&directionsmode=driving`;
}
export function googleSingleUrl(r) {
  return 'https://www.google.com/maps/dir/?' + new URLSearchParams({ api: '1', destination: mapsQuery(r), travelmode: 'driving' });
}

// ---------- calendar (.ics) ----------
function icsEscape(s) { return String(s).replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n'); }
function icsFold(line) { // RFC 5545: max 75 octets per line
  const out = []; let s = line;
  while (s.length > 73) { out.push(s.slice(0, 73)); s = ' ' + s.slice(73); }
  out.push(s); return out.join('\r\n');
}
// groups: [{due:'YYYY-MM-DD', retailers:[...], seq:n}]
export function buildIcs(groups, leadDays = 14, stamp = new Date()) {
  const ds = stamp.toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//pm-tracker//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH'];
  for (const g of groups) {
    const start = g.due.replace(/-/g, ''), endD = addDaysStr(g.due, 1).replace(/-/g, '');
    const n = g.retailers.length;
    lines.push('BEGIN:VEVENT',
      `UID:pm-due-${start}-${g.seq || 0}@pm-tracker`,
      `DTSTAMP:${ds}`,
      `DTSTART;VALUE=DATE:${start}`, `DTEND;VALUE=DATE:${endD}`,
      icsFold(`SUMMARY:${icsEscape(`PM due: ${n} retailer${n === 1 ? '' : 's'}`)}`),
      icsFold(`DESCRIPTION:${icsEscape(g.retailers.map((r) => `${r.name} (#${r.id}) - ${r.address}, ${r.city}`).join('\n'))}`),
      'TRANSP:TRANSPARENT',
      'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${icsEscape(`PM due in ${leadDays} days: ${n} retailer(s)`)}`, `TRIGGER:-P${leadDays}D`, 'END:VALARM',
      'BEGIN:VALARM', 'ACTION:DISPLAY', 'DESCRIPTION:PM due today', 'TRIGGER;RELATED=START:PT9H', 'END:VALARM',
      'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.join('\r\n') + '\r\n';
}
export function addDaysStr(s, n) {
  const { y, m, d } = parse(s);
  return todayStr(new Date(y, m - 1, d + n));
}

// ---------- spreadsheet rows -> retailers ----------
// rows: array of arrays (sheet_to_json header:1). Finds the header row with "Retailer #".
export function retailersFromRows(rows, tab) {
  const norm = (v) => String(v ?? '').trim().toLowerCase();
  const hi = rows.findIndex((r) => r && r.some((c) => norm(c) === 'retailer #'));
  if (hi < 0) return [];
  const h = rows[hi].map(norm);
  const col = (name) => h.indexOf(name);
  const ci = { id: col('retailer #'), name: col('retailer name'), addr: col('address'), city: col('city') };
  const out = new Map();
  for (const r of rows.slice(hi + 1)) {
    if (!r) continue;
    let id = r[ci.id];
    if (id === undefined || id === null || String(id).trim() === '') continue;
    id = typeof id === 'number' ? String(Math.trunc(id)) : String(id).trim();
    if (out.has(id)) continue;
    const clean = (v) => String(v ?? '').replace(/\s+/g, ' ').trim();
    out.set(id, { id, name: clean(r[ci.name]), address: clean(r[ci.addr]), city: clean(r[ci.city]), state: 'MO', tab: String(tab) });
  }
  return [...out.values()];
}
