# Campus Navigation

> A standalone mobile campus navigation application designed to help students and visitors find classrooms, labs, facilities, and other locations across campus.

## Overview

Campus Navigation is a Flutter-based mobile application being developed to provide simple and reliable navigation across a university campus.

The application is designed around indoor campus navigation, including:

- Building and floor navigation
- Classroom and facility search
- Turn-by-turn directions
- Multi-floor routes
- Campus map visualization
- Location/positioning support
- Route guidance between campus locations

The mobile application communicates with a Python Flask backend through REST APIs.

---

## Current Status

🚧 **Under Development**

The current Flutter application includes:

- [x] Flutter project setup
- [x] Android device testing
- [x] Custom Metro Line visual theme and typography
- [x] Search screen with category filters, quick access, and results grouped by building
- [x] Start location picker (the place a QR scan will plug into)
- [x] Route screen: overview (steps and map), guidance mode, arrival screen
- [x] Metro-style route strip with interchange markers for stairs and lifts
- [x] Interactive campus map (schematic, tappable buildings, route line)
- [x] Floor selector and indoor floor plans (Academic Building, pilot)
- [x] Multi-floor route visualization
- [x] Loading, error, and empty states with retry
- [x] Animated route line, page transitions, and animated step guidance
- [x] Haptic feedback on step changes
- [x] Saved places, recent places, and a remembered start location
- [x] Step-free route option (lift instead of stairs)
- [x] Report-a-problem sheet
- [x] Search highlighting and pull-to-refresh
- [x] API service with timeouts and a built-in demo mode
- [x] Destination and route data models
- [ ] Real campus data (GeoJSON, replacing the schematic map)
- [x] Flask backend integration (search, route, estimates, report), real OpenStreetMap route line and floor-plan image
- [x] QR scanning for the start location (camera, with a manual fallback)
- [x] Live GPS guidance outside (follows you, moves to the next step by itself, reroutes when you go off the path); inside: "Next" or scan a sign

## Running the app

Demo mode (default). No backend needed, the app uses built-in campus data:

```bash
flutter pub get
flutter run
```

Against the Flask backend:

```bash
flutter run --dart-define=USE_MOCK=false --dart-define=API_BASE_URL=http://<laptop-ip>:5000
```

- Emulator: use `http://10.0.2.2:5000`
- Real phone: use your laptop's Wi-Fi IP, and keep both on the same network
- Android blocks plain `http://` in release builds, so add HTTPS or a network security config before shipping

## QR codes

A QR code contains the text `campusnav:<node id>`, for example `campusnav:acad_entrance`.
Scanning one sets the start location. A plain node id also works.
`CampusNav-QR-codes.pdf` has a printable code for every node in the demo data.
When the real campus graph exists, generate one code per node id from it.

## Backend contract (live mode)

The app talks to the Flask API in the backend repo; `docs/api.md` there is the reference.

| App feature | Request |
|---|---|
| Search / list places | `GET /api/rooms?q=&limit=50` |
| Route | `GET /api/route?from=<id>&to=<id>[&accessible=1]` |
| Walking-time labels | `POST /api/estimates` |
| Report a problem | `POST /api/report` |

`NavigationRoute.fromBackend` turns the route answer into the app's models. Outdoor legs are drawn on OpenStreetMap
(`LiveCampusMap`), indoor legs on the bundled floor-plan image (`LiveFloorPlan`). Copy new floor images from the backend's
`app/assets/floorplans/` into this repo's `assets/floorplans/`.

---

## Tech Stack

### Mobile Application

- **Flutter**
- **Dart**
- Material 3
- Custom Flutter widgets

### Backend

- **Python**
- **Flask**
- REST API
- SQLite

### Navigation

- Graph-based campus representation
- A* pathfinding
- Multi-floor navigation
- Indoor positioning

---

## Architecture

```text
                    ┌──────────────────────┐
                    │      Flutter App     │
                    │                      │
                    │  Screens             │
                    │  Widgets             │
                    │  Models              │
                    │  API Services        │
                    └──────────┬───────────┘
                               │
                            HTTP/JSON
                               │
                               ▼
                    ┌──────────────────────┐
                    │    Flask Backend     │
                    │                      │
                    │  REST API            │
                    │  Search              │
                    │  Routing             │
                    │  Positioning         │
                    └──────────┬───────────┘
                               │
                    ┌──────────┴───────────┐
                    ▼                      ▼
              Campus Data             A* Routing
                    │                      │
                    └──────────┬───────────┘
                               ▼
                         Route Response
                               │
                               ▼
                    ┌──────────────────────┐
                    │    Flutter UI        │
                    │  Map + Directions    │
                    └──────────────────────┘