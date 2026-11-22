// Logic checks run on the build machine: swiftc PMTracker/Models.swift PMTracker/Logic.swift Tests/main.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

// 1. A backup written by the web app (lat null, numeric tab/id, missing fields) decodes.
let web = """
{"type":"pm-tracker-backup","version":1,"appVersion":"1.0.0","exportedAt":"2026-11-20T15:00:00.000Z","state":{
 "schema":1,
 "retailers":{
  "123456":{"id":"123456","name":"CASEY'S #1","address":"100 MAIN ST","city":"OZARK","state":"MO","tab":"600","visits":[{"id":"abc","date":"2026-05-31","note":"ok","at":"2026-05-31T14:00:00.000Z"}],"notes":"gate 1234","lat":37.02,"lng":-93.2,"geo":"exact"},
  "777":{"id":777,"name":"QUIKTRIP","address":"5 ELM","city":"NIXA","tab":610,"visits":[],"lat":null,"lng":null,"geo":"none","archived":true},
  "888":{"name":"NO ID FIELD","address":"","city":"NIXA"}
 },
 "route":{"stops":["123456"],"end":"home","builtAt":null,"start":{"lat":37.2,"lng":-93.3}},
 "settings":{"soonDays":30,"autoLocate":true,"home":{"lat":37.1,"lng":-93.25},"leadDays":14,"mapsMode":"app"},
 "meta":{"createdAt":"2026-10-13T00:00:00.000Z","lastBackupAt":null,"changesSinceBackup":4,"icsExported":{"2026-12-01":["123456"]},"icsExportSeq":{}}
}}
"""
do {
    let b = try JSONDecoder().decode(Backup.self, from: Data(web.utf8))
    let s = b.state
    check(s.retailers.count == 3, "web backup: 3 retailers")
    check(s.retailers["777"]?.archived == true && s.retailers["777"]?.coord == nil && s.retailers["777"]?.tab == "610", "web backup: numeric id/tab, null coords, archived")
    check(s.retailers["888"]?.id == "888", "web backup: missing id filled from key")
    check(s.retailers["123456"]?.visits.first?.date == "2026-05-31" && s.retailers["123456"]?.notes == "gate 1234", "web backup: visits and notes kept")
    check(s.settings.home != nil && s.route.end == "home" && s.settings.routeStops == 5, "web backup: settings and route")
    // Round trip through the native format and back.
    let again = try JSONDecoder().decode(Backup.self, from: JSONEncoder().encode(b))
    check(again.state.retailers.count == 3 && again.state.retailers["123456"]?.coord == Coord(lat: 37.02, lng: -93.2), "native backup round trip")
} catch {
    check(false, "web backup decodes: \(error)")
}

// 2. Dates and status.
check(Day.addMonths("2026-08-31", 6) == "2027-02-28", "Aug 31 + 6 months = Feb 28")
check(Day.addMonths("2026-05-31", 6) == "2026-11-30", "May 31 + 6 months = Nov 30")
check(Day.between("2026-11-22", "2026-12-01") == 9, "days between")
var r = Retailer(id: "1", name: "A", address: "x", city: "y", tab: "600")
check(computeStatus(r, today: "2026-11-22", soonDays: 30).status == .never, "no visits = never")
r.visits = [Visit(date: "2026-05-01", note: "")]
let st = computeStatus(r, today: "2026-11-22", soonDays: 30)
check(st.status == .overdue && st.daysToDue == -21, "visited May 1 = 21 days overdue on Nov 22")
r.visits.append(Visit(date: "2026-11-01", note: ""))
check(computeStatus(r, today: "2026-11-22", soonDays: 30).status == .current, "latest visit wins")

// 3. Route order matches brute force.
func brute(_ pts: [Coord], _ start: Coord, _ end: Coord?) -> Double {
    var best = Double.infinity
    func perm(_ a: [Int], _ rest: [Int]) {
        if rest.isEmpty {
            var d = 0.0, p = start
            for i in a { d += haversineMi(p, pts[i]); p = pts[i] }
            if let end { d += haversineMi(p, end) }
            best = min(best, d)
            return
        }
        for (k, i) in rest.enumerated() { var r2 = rest; r2.remove(at: k); perm(a + [i], r2) }
    }
    perm([], Array(0..<pts.count))
    return best
}
func length(_ order: [Int], _ pts: [Coord], _ start: Coord, _ end: Coord?) -> Double {
    var d = 0.0, p = start
    for i in order { d += haversineMi(p, pts[i]); p = pts[i] }
    if let end { d += haversineMi(p, end) }
    return d
}
var rng = SystemRandomNumberGenerator()
var routeOK = true
for trial in 0..<20 {
    let n = 2 + trial % 7
    let pts = (0..<n).map { _ in Coord(lat: 37 + Double.random(in: 0...0.8, using: &rng), lng: -93.6 + Double.random(in: 0...0.8, using: &rng)) }
    let start = Coord(lat: 37.2, lng: -93.3)
    let end: Coord? = trial % 2 == 0 ? nil : start
    let order = optimizeOrder(pts, start: start, end: end)
    if Set(order) != Set(0..<n) || abs(length(order, pts, start, end) - brute(pts, start, end)) > 1e-6 { routeOK = false }
}
check(routeOK, "route order is optimal for 2-8 stops (20 random cases)")
let big = (0..<20).map { i in Coord(lat: 37 + Double(i % 5) * 0.1, lng: -93 - Double(i / 5) * 0.1) }
check(Set(optimizeOrder(big, start: Coord(lat: 37, lng: -93))) == Set(0..<20), "20-stop heuristic visits every stop once")

// 4. Picking stops: count respected, overdue preferred.
func item(_ id: String, _ lat: Double, _ status: PMStatus) -> Item {
    var x = Retailer(id: id, name: id, address: "", city: "", tab: "")
    x.lat = lat; x.lng = -93.3; x.geo = "exact"
    return Item(r: x, s: StatusInfo(status: status, last: nil, due: nil, daysToDue: status == .overdue ? -5 : nil), d: nil)
}
let cands = (1...12).map { item("s\($0)", 37.2 + Double($0) * 0.01, $0 == 3 ? .overdue : .never) }
check(autoPick(cands, start: Coord(lat: 37.2, lng: -93.3), count: 3).count == 3, "auto-pick returns the requested 3 stops")
check(autoPick(cands, start: Coord(lat: 37.2, lng: -93.3), count: 9).count == 9, "auto-pick returns 9 stops")
check(autoPick(cands, start: Coord(lat: 37.2, lng: -93.3), count: 1).count == 1, "auto-pick returns 1 stop")

// 5. Google Maps links.
var a = Retailer(id: "1", name: "A", address: "100 MAIN ST", city: "OZARK", tab: "")
var m = Retailer(id: "2", name: "B", address: "5 ELM", city: "NIXA", tab: "")
m.lat = 37.05; m.lng = -93.29; m.geo = "manual"
let app = GoogleMaps.appURL([.retailer(a), .retailer(m)])?.absoluteString ?? ""
check(app == "comgooglemaps://?daddr=100%20MAIN%20ST,%20OZARK,%20MO+to:37.05,-93.29&directionsmode=driving", "app link: \(app)")
let webURL = GoogleMaps.webURL([.retailer(a), .retailer(m), .point(Coord(lat: 37.1, lng: -93.25), "Home")], navigate: true)?.absoluteString ?? ""
check(webURL == "https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=37.1,-93.25&waypoints=100%20MAIN%20ST,%20OZARK,%20MO%7C37.05,-93.29&dir_action=navigate", "web link: \(webURL)")

// 6. Spoken retailer numbers.
check(digitsFromSpeech("one two three four five six") == "123456", "spoken digits")
check(digitsFromSpeech("12,345") == "12345", "formatted number")
check(digitsFromSpeech("Retailer 1 2 3 for 5") == "12345", "mixed words and digits")
check(parseCoords("https://www.google.com/maps/@37.2089,-93.2923,15z") == Coord(lat: 37.2089, lng: -93.2923), "coords from a Maps link")

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
