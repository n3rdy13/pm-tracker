# PM Tracker for iPhone (native app with Siri)

Replaces the web app. Same data format, so a web-app backup restores straight into it.

## Get the app
Every push that changes `ios/` builds an **unsigned IPA** on GitHub and publishes it here:

**https://github.com/n3rdy13/pm-tracker/releases/download/ios-latest/PMTracker-unsigned.ipa**

Sign and install it with your developer certificate (ESign, Feather, Sideloadly, etc.). The same file is also attached to each run on the Actions tab.

## Move your data over (one time)
1. Old web app → **More › Back up now** → save to Files / iCloud Drive.
2. New app → **Import backup** → pick that file. Retailers, visits, notes and fixed locations all come across.
3. Allow location, then in **More › Siri** tap **Change to Always** (Siri needs Always to know where you are).
4. **More › Reminders** → turn on the badge and due-date notifications.

## Siri
Say "Hey Siri," then:

| Say | What happens |
|---|---|
| "PMs near me in PM Tracker" | Reads the 3 closest stores that need PM (distance, status, retailer number) and shows the top 5 |
| "Closest retailer number in PM Tracker" / "What store am I at in PM Tracker" | Name, address and retailer number of the closest store |
| "Mark this store done in PM Tracker" | Marks the closest store done today. Asks first if you're more than ~1,000 ft away or its location is approximate; saves your spot as its location in that case |
| "Mark a retailer done in PM Tracker" | Asks for the retailer number, confirms the store, marks it done |
| "Start a PM route in PM Tracker" | Asks how many stops (1–9), picks the closest stores that need PM (overdue first), orders them and starts Google Maps |
| "Resume my route in PM Tracker" | Reopens Google Maps with the stops not yet done today |
| "PM status in PM Tracker" | Overdue / never visited / due soon / current counts |

Siri needs the app name in each phrase. For shorter phrases, make a shortcut in the Shortcuts app (e.g. named "PMs near me") that runs the PM Tracker action.

## Notes
- Routes hold up to 9 stops — the most one Google Maps route takes.
- If "Google Maps app" doesn't open with all stops, switch **More › Open routes in** to "Google Maps link".
- Importing PM report spreadsheets (.xlsx) isn't in the native app. Add new stores with **+**, or import a retailer list JSON.
- Data stays on the phone. Back up now and then (**More › Back up now**).
