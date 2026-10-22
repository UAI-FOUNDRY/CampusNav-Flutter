# Campus Navigation

> A mobile app that helps students and visitors find classrooms, labs, offices and facilities at Universal AI University, Karjat, with walking directions outdoors and floor by floor inside the main building.

## Overview

Campus Navigation is a Flutter app backed by a Python Flask API. Pick where you are, search for a place, and the app shows the shortest walking route: outside on a satellite or street map, inside on the floor plans of the ground, first and second floors. During navigation the arrow follows you like Google Maps, outside and inside: GPS, your steps and turns, the barometer for floors and the compass, blended into one smooth position along the route.

The route lines and places are coloured like metro lines, one colour per kind of place (classrooms blue, labs purple, food red, offices teal ...).

---

## Features

### Search and places
- Every searchable place on campus (130+), loaded once from the backend and searchable offline
- Category filters (Labs, Study, Halls, Food, Sports, Admin, Facilities, Washrooms, Hostel), quick access, saved and recent places
- "Inside the Library" shown for places that sit inside another place
- Walking-time labels from your current start
- Helpful empty search with suggestions

### Where you start
- Start picker with every place and named spot (lifts, staircases, lobbies, side doors), grouped by area and floor, with search, recent and popular starts
- **Use my location**: GPS for a few seconds (the sharpest fixes averaged), the floor from the barometer and, on Android, the Wi-Fi networks around; every campus spot, inside and outside, is scored. Outside with a sharp fix it starts right there. Inside (GPS is ±15-40 m there, several rooms fit) it asks **"Where exactly are you?"** with the few spots on your floor that fit, and that answer teaches the app the room's Wi-Fi and the floor for next time
- Clear messages when location is off, not allowed, too weak or off campus
- **Scan a QR code** on a signboard for an exact start
- The start can be changed from Home, the route screen and the map's place card

### Maps
- **Outdoors:** satellite or street map, pins in each place's colour with its category icon
- **Indoors:** all three floor plans with a floor switch, dots for every room, names when zoomed in
- Full-screen map with a pull-up list of places, search across floors and a colour legend that doubles as a filter
- Tap a place to see its card, then **Directions** (no accidental routes on crowded plans)
- Gestures like Google Maps: pinch to zoom, two-finger twist to rotate (with a threshold so pinching does not turn the map), fling, double-tap zoom, double-tap-and-drag one-finger zoom, two-finger tap to zoom out, compass to turn back north-up
- Lines and markers keep their size when zoomed

### Routes
- Overview with the metro-style step strip, outdoor map and one floor plan per floor of the route, opened zoomed onto the route
- Full-screen route map with Outside / Ground / Floor 1 ... tabs
- Step-free option per route (lifts instead of stairs), shown only where it matters; if a place has no step-free way in, the normal route stays and the app says so
- Report-a-problem sheet

### Floor detection on every phone
Every phone uses the best sensor it has, and they back each other up:

| How | Phones | When |
|---|---|---|
| Barometer (air pressure) | most mid and high-end phones, all iPhones since the 6 | stairs and lifts, and the exact floor once it has a reference |
| Steps on the stairs (accelerometer) | every phone | a floor change on the route's stairs: the card closes when the bar is full (24 steps a floor to begin with), earlier on dog-leg stairs after a full turn (gyroscope) or when your walking rhythm is back to normal; climbing is slower than walking, so the rhythm also teaches the app how many steps your stairs have |
| Lift felt starting and stopping (accelerometer) | every phone | a floor change in the route's lift: the start push and the stop push give the speed and the time, so the height (nothing integrated twice). The card closes when the lift stops; if one push was missed, from the other one (or when the lift must have arrived at the speed felt); at the latest as you walk out. Simulated on whole trips with a fidgeting hand: at the stop about 90 % of the time (100 % with a calm hand) |
| Wi-Fi fingerprints | Android | "Use my location", and a wrong-floor check every 40 s inside |
| QR sign at each stairs / lift landing | every phone | exact floor and position, one scan (`python tools/generate_qr.py --floors` in the backend prints the 17 landing stickers) |
| Last known floor and spot | every phone | "Use my location" lists where you arrived / picked / scanned in the last 15 minutes first, and the floor as a hint for 20 minutes |
| "I'm on floor N" button | every phone | always there as the last word |

**"Use my location" is quick:** GPS starts when the "Where are you?" sheet opens, so the fixes are ready when you tap; it stops as soon as a fix is good enough (two sharp fixes, ±15 m after 3 s, ±30 m after 5 s, 8 s at most).

### Live guidance (inside and outside)
- **The arrow moves the moment you walk**, every frame, like Google Maps: your steps (raw accelerometer, so every phone, also budget ones without a gyroscope) give your speed, GPS (outside) your position on the path, and a small filter blends them, so there is no waiting for the next GPS fix and no jumping back
- **Outside:** GPS keeps you on the path (fixes that disagree too much are ignored, a run of them re-syncs), the map turns so the way ahead points up, a new route is found if you go off the path
- **Inside:** your steps move you along the route (no Next button needed) and every corner you take (gyroscope, or the compass on phones without one) is matched to the route's corners, which corrects the distance; the step length is learned as you walk (from GPS speed outside, from corners inside) and remembered
- **Floors:** at the stairs / lift a full-screen card shows the way and **closes by itself when you reach the floor** (with a progress bar while you climb); taking the stairs somewhere else shows "You seem to be on floor 2" with a new route from there
- **Compass:** a beam shows which way you face; standing still facing away from the route, the app says "Turn around" / "Turn left"
- Scan a sign to jump to that point of the route exactly; Next / Back still work at any time
- The round button next to Next opens a small menu (sensors, scan a sign, pause): auto-follow is never switched off by one stray tap
- Tap the status line for the **sensor sheet**: what every sensor reads, the floor reference, and "Simulate the walk" for testing at a desk
- Sensors and GPS only run during guidance and stop when you end it or arrive

### Reliability and access
- Errors say what happened (offline, server slow, no route, off campus, place not found) and offer the right fix
- The campus map is saved on the phone and only downloaded again when it changes; the app still browses and searches offline
- Deep links: a poster QR like `campusnav://campus/to/library` opens straight on the route
- Screen-reader labels (TalkBack), 44 px touch targets, at least 12 px text, "reduce motion" respected, colour never the only clue

---

## Current status

- [x] Flutter app, tested on Android
- [x] Metro Line theme, Atkinson Hyperlegible font, colour per kind of place
- [x] Flask backend integration (graph, search, route, estimates, report)
- [x] Real campus data: outdoor paths and all three floors of the main building
- [x] Search, filters, saved / recent places and trips
- [x] Start picker with every place, GPS start and QR scanning
- [x] Outdoor map (satellite / street) and indoor floor plans with rotation and zoom
- [x] Route overview, full-screen route map, step-free routes
- [x] Live GPS guidance outside, with heading-up map and rerouting
- [x] Indoor guidance by Next or scanning a sign, floor-change cards
- [x] Offline cache of the campus map, deep links
- [x] Accessibility pass (TalkBack labels, touch targets, reduce motion)
- [ ] Backend deployed online (it runs on a laptop for now; see below)
- [ ] Dark mode
- [x] Indoor positioning without QR codes (steps, turns, barometer floors, Wi-Fi fingerprints learned from confirmed spots)

---

## Running the app

Demo mode (default). No backend needed; the app uses built-in demo data:

```bash
flutter pub get
flutter run
```

Against the Flask backend:

```bash
flutter pub get
flutter run --dart-define=USE_MOCK=false --dart-define=API_BASE_URL=http://<laptop-ip>:5000
```

- Emulator: use `http://10.0.2.2:5000`
- Real phone: use the laptop's Wi-Fi IP, with phone and laptop on the same network
- `API_BASE_URL` is fixed when the app is built, so changing it means running `flutter run` again
- After adding assets, packages or changing a widget's type, do a full restart, not a hot reload

### Permissions
- **Camera:** scanning QR codes
- **Location (while using the app):** "Use my location" and live guidance
- **Wi-Fi state (Android):** "Use my location" compares the Wi-Fi networks around with fingerprints of known spots (needs location on, like any Wi-Fi scan)
- **Motion & Fitness (iOS):** steps, turns and air pressure (`NSMotionUsageDescription`); Android needs no permission for these sensors
- `android:usesCleartextTraffic="true"` allows plain `http://` to the laptop during development. Remove it once the backend runs on HTTPS.

### Testing live guidance
GPS and the sensors need no network, but routes come from the backend. If the backend runs on the laptop:
1. Open the route and tap **Start navigation** while still on the laptop's Wi-Fi.
2. Turn on mobile data so the map background keeps loading.
3. Walk. Following, steps, floors and arrival work without the laptop; only rerouting and new routes need it.

At a desk: start navigation, tap the status line above the buttons and switch on **Simulate the walk** (it walks the
route at 1.3 m/s and takes the stairs / lift by itself). The same sheet shows every sensor reading.

On the stairs, hold the phone as usual: the card shows the climb and closes on the new floor. If your phone has no
barometer (some cheaper Android phones), tap "I'm on floor N" as before.

Deploying the backend (the backend repo has a `render.yaml` for Render) removes this limit.

---

## QR codes and links

**Start codes** on signboards contain `campusnav:<node id>`, for example `campusnav:gate_main`. Scanning one in the app sets the start; during guidance it jumps to that point of the route. A plain node id also works. Generate them with `tools/generate_qr.py` in the backend repo.

**Poster links** open the app on a route:

```text
campusnav://campus/to/<place id>                 directions to a place
campusnav://campus/to/<place id>?from=<node id>  ... from a given start
campusnav://campus/from/<node id>                set the start only
```

They work from the phone's camera app and from the in-app scanner. To test without printing:

```bash
adb shell am start -a android.intent.action.VIEW -d "campusnav://campus/to/library"
```

---

## Backend contract (live mode)

The app talks to the Flask API in the backend repo (`UAI-FOUNDRY/Campus-Navigation`); `docs/api.md` there is the reference.

- `GET /api/graph`: every place, node and floor in one answer. Saved on the phone and re-checked with `If-None-Match` (a 304 when nothing changed).
- `GET /api/rooms?q=&limit=50`: typo-tolerant search while typing.
- `GET /api/route?from=<id>&to=<id>[&accessible=1]`: a route from a place or node id.
- `GET /api/route?from_lat=..&from_lng=..&to=<id>`: a route from a GPS position (snapped to the nearest path; `422 off_campus` beyond 150 m).
- `POST /api/estimates`: walking minutes to many places at once.
- `POST /api/report`: "Report a problem".
- `GET /api/floors`: floor list, used only with older backends without `/api/graph`.

`NavigationRoute.fromBackend` turns the route answer into the app's models. Outdoor legs are drawn on the map (`LiveCampusMap`), indoor legs on the bundled floor plans (`LiveFloorPlan`). Copy new floor images from the backend's `app/assets/floorplans/` into this repo's `assets/floorplans/` (`ground.png`, `first.png`, `second.png`).

---

## Project structure

```text
lib/
  main.dart                     app start, deep-link routes
  data/                         demo data, start points, deep-link parsing
  models/                       destination, route, start point, floor info
  services/
    api_service.dart            every backend call, offline cache, error kinds
    location_service.dart       GPS permission and the precise position stream
    spot_locator.dart           "Use my location": GPS + floor + Wi-Fi, ranks every spot
    route_tracker.dart          the whole route in metres (outside + every floor), corners, rides
    live_guide.dart             live guidance engine: GPS, steps, turns, floors, compass
    position_filter.dart        the Kalman filter along the route
    motion_sensors.dart         step and turn detectors, compass
    floor_barometer.dart        floors from air pressure, weather-corrected reference
    wifi_fingerprints.dart      Wi-Fi fingerprints (Android scan channel in MainActivity.kt)
  state/app_state.dart          saved places, recents, start point
  theme/                        colours (one per kind of place), type, styles
  screens/
    home_screen.dart            search
    live_map_screen.dart        Map tab (outdoors / indoors)
    navigation_screen.dart      route overview, guidance, arrival
    route_map_screen.dart       full-screen route map
    scan_screen.dart            QR scanner
    deep_link_screen.dart       opens campusnav:// links
  widgets/
    live_route_map.dart         outdoor map, follow / heading-up camera
    floor_plan_viewer.dart      full-size floor plan with zoom buttons
    live_floor_plan.dart        floor picture, route, dots, labels
    zoomable_view.dart          pinch / rotate / fling / double-tap gestures
    start_location_sheet.dart   "Where are you now?" and "Where exactly are you?"
    sensor_sheet.dart           what every sensor reads, floor calibration, simulate walk
    place_card.dart, state_views.dart, ...
```

### Tuning live guidance
The numbers were tuned by simulating walks on real routes of this campus (gate to Everest, gate to the Innovation Lab
by stairs, lobby to the AR/VR lab by lift ...) with realistic sensor noise: the arrow stays within about 2 to 5 m
inside (90 % of the time) and 2 to 4 m outside, never steps backwards, and the stairs / lift card closed by itself
on every simulated ride.
- `services/floor_barometer.dart`: `metresPerFloor` (4 m; measure the building and change it, the app also learns it on every ride)
- `services/live_guide.dart`: default step length 0.72 m (learned and saved), climb detection (0.06 hPa in 5 s), how close a climb must be to the route's stairs (40 m), turn matching (45 degree turns, 60 degree tolerance)
- `services/spot_locator.dart`: how long "Use my location" listens to GPS (up to 10 s) and when it is sure enough not to ask
- `navigation_screen.dart`: off-route reroute at most every 15 s
- `live_route_map.dart`: how fast the map turns (`0.45` s), how far ahead it looks (15 m), how low you sit on screen (`0.22` of the height)
- `zoomable_view.dart`: rotation threshold (15 degrees, 35 while zooming)

---

## Known limitations

- Inside, position comes from steps and turns: it drifts a few percent between corners. Corners, floor changes, signs and Next correct it; with a step length far from yours it may need "I've arrived" on short indoor routes
- GPS alone cannot name a room indoors: "Use my location" asks there until the Wi-Fi has learned the room (Android). iPhones cannot scan Wi-Fi, so on iPhone it always asks indoors (scan a sign for an exact start)
- The exact floor needs a recent reference (outside next to the building, the door, a ride, a sign or a picked spot), corrected for the weather with the free Open-Meteo forecast. Floor *changes* on the route's stairs / lift need no reference
- Phones without a barometer or gyroscope fall back to the "I'm on floor N" button and to steps without corner matching
- The backend runs on a laptop: rerouting and new routes need the phone to reach it
- Map tiles (Esri World Imagery, OpenStreetMap) are free for light use with attribution; check their terms or use a keyed provider before a public launch
- Demo mode's schematic map is not part of the live app and has not had the accessibility pass

---

## Tech stack

**Mobile app:** Flutter, Dart, Material 3, `flutter_map` + `latlong2` (maps), `geolocator` (GPS), `sensors_plus` (steps, turns, air pressure), `dchs_motion_sensors` (compass), `mobile_scanner` (QR), `shared_preferences` (saved data and the offline map), `http`.

**Backend:** Python, Flask, REST API, A* routing over a campus graph built from GeoJSON (outdoor paths) and one JSON file per floor (indoor corridors and rooms).

**Positioning:** GPS outdoors, steps + gyroscope turns indoors, barometer floors, compass heading, Wi-Fi fingerprints for "Use my location" (Android), QR codes as exact checkpoints, all blended along the route by a Kalman filter.

---

## Architecture

```text
                    ┌──────────────────────────┐
                    │        Flutter App       │
                    │  Screens · Widgets       │
                    │  Models · Services       │
                    │  GPS · QR · offline map  │
                    └────────────┬─────────────┘
                                 │  HTTP / JSON
                                 ▼
                    ┌──────────────────────────┐
                    │       Flask Backend      │
                    │  /api/graph  /api/rooms  │
                    │  /api/route  /api/...    │
                    └────────────┬─────────────┘
                                 │
                   ┌─────────────┴─────────────┐
                   ▼                           ▼
           Campus graph                   A* routing
   (GeoJSON paths + floor files)    (outdoor + indoor, step-free)
                   │                           │
                   └─────────────┬─────────────┘
                                 ▼
                          Route response
                     (legs, steps, polyline)
                                 │
                                 ▼
                    ┌──────────────────────────┐
                    │        Flutter UI        │
                    │  map / floor plans,      │
                    │  live guidance           │
                    └──────────────────────────┘
```
