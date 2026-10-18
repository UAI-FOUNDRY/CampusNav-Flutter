# Campus Navigation

> A mobile app that helps students and visitors find classrooms, labs, offices and facilities at Universal AI University, Karjat, with walking directions outdoors and floor by floor inside the main building.

## Overview

Campus Navigation is a Flutter app backed by a Python Flask API. Pick where you are, search for a place, and the app shows the shortest walking route: outside on a satellite or street map, inside on the floor plans of the ground, first and second floors. During navigation it follows you by GPS outside and guides you step by step inside.

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
- **Use my location**: GPS start, matched to the nearest campus spot, with clear messages when location is off, not allowed, too weak or off campus
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

### Live guidance
- **Outside, by GPS:** the person icon follows you along the path, the map turns so the way ahead points up, the next step starts by itself as you reach each turn, the distance counts down, and a new route is found if you go off the path
- **At the building door** GPS switches off (it is not accurate indoors)
- **Inside:** tap Next as you walk, or scan the QR code on a sign to jump to that point of the route
- A full-screen card for every stairs / lift moment ("Take the stairs up to floor 1"), confirmed with "I'm on floor 1"
- GPS only runs during guidance and stops when you end it, arrive or reach the door

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
- [ ] Indoor positioning without QR codes

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

### Permissions (Android)
- **Camera:** scanning QR codes
- **Location (while using the app):** "Use my location" and live guidance
- `android:usesCleartextTraffic="true"` allows plain `http://` to the laptop during development. Remove it once the backend runs on HTTPS.

### Testing live guidance outside
GPS needs no network, but routes come from the backend. If the backend runs on the laptop:
1. Open the route and tap **Start navigation** while still on the laptop's Wi-Fi.
2. Turn on mobile data so the map background keeps loading.
3. Walk. Following, steps and arrival work without the laptop; only rerouting and new routes need it.

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
    location_service.dart       GPS permission, one-off fix, live position stream
    route_tracker.dart          snaps GPS fixes onto the route, step positions
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
    start_location_sheet.dart   "Where are you now?"
    place_card.dart, state_views.dart, ...
```

### Tuning live guidance
- `navigation_screen.dart`: arrive radius at a turn (about 10 m), off-route distance (25 m for three fixes), ignored backward GPS wobble (8 m), reroute at most every 15 s
- `live_route_map.dart`: how fast the map turns (`0.45` s), how far ahead it looks (15 m), how low you sit on screen (`0.22` of the height)
- `zoomable_view.dart`: rotation threshold (15 degrees, 35 while zooming)

---

## Known limitations

- GPS is not accurate indoors, so inside the building guidance is by Next or QR signs
- The backend runs on a laptop: rerouting and new routes need the phone to reach it
- Map tiles (Esri World Imagery, OpenStreetMap) are free for light use with attribution; check their terms or use a keyed provider before a public launch
- Demo mode's schematic map is not part of the live app and has not had the accessibility pass

---

## Tech stack

**Mobile app:** Flutter, Dart, Material 3, `flutter_map` + `latlong2` (maps), `geolocator` (GPS), `mobile_scanner` (QR), `shared_preferences` (saved data and the offline map), `http`.

**Backend:** Python, Flask, REST API, A* routing over a campus graph built from GeoJSON (outdoor paths) and one JSON file per floor (indoor corridors and rooms).

**Positioning:** GPS outdoors (snapped to the path), QR codes indoors.

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
