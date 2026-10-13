# PM Tracker

A phone web app for tracking 6-month preventative-maintenance (PM) visits to retailers and routing them through Google Maps.

- **All data stays on the phone** (IndexedDB). This repo holds only the app code — never commit retailer lists or backups (`.gitignore` blocks `*.json`, `*.xlsx`).
- List sorted by importance: **Overdue → Never visited → Due soon → Current**, nearest first within each group.
- **Near Me** + **auto-built routes** (stops ordered optimally; split into Google Maps legs of up to 9 stops).
- **Mark done** with date and note; next visit due 6 calendar months later.
- **Backup / Restore** (JSON file), **import** of retailer lists or PM report spreadsheets (.xlsx, tabs 600–640 preselected; report dates ignored).
- **Reminders**: summary banner on open, Home Screen icon badge, and calendar (.ics) export of due dates.

## Install on iPhone
1. Open the GitHub Pages URL in **Safari**.
2. Share → **Add to Home Screen**. Always open it from the Home Screen icon (this keeps iOS from clearing its storage).
3. Open the app → **Choose file…** → pick `retailers-881.json` (saved in Files/iCloud Drive).
4. Allow location when asked. Then **More → Back up now** and save the backup to iCloud Drive.

## Updating the app
Edit files, bump `VERSION` in `sw.js` and `APP_VERSION` in `js/app.js`, push. The app shows "New version ready — Reload".

## Files
- `js/logic.js` — dates, status, sorting, route optimisation (exact for ≤12 stops), Google Maps URLs, .ics
- `js/app.js` — UI; `js/db.js` — storage; `sw.js` — offline cache
- `vendor/` — Leaflet 1.9.4, SheetJS 0.18.5
