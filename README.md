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
- [x] "Simulate walk" demo mode and haptic feedback on step changes
- [x] Saved places, recent places, and a remembered start location
- [x] Step-free route option (lift instead of stairs)
- [x] Report-a-problem sheet
- [x] Search highlighting and pull-to-refresh
- [x] API service with timeouts and a built-in demo mode
- [x] Destination and route data models
- [ ] Real campus data (GeoJSON, replacing the schematic map)
- [ ] Flask backend integration (needs the real JSON contract)
- [x] QR scanning for the start location (camera, with a manual fallback)
- [ ] Real-time positioning (guidance is simulated with a "Next step" button)

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

## Backend contract the app expects

`GET /api/search?q=` returns a list (an empty `q` returns everything):

```json
[{"id": "ai_lab", "name": "AI Lab", "building": "Academic Building", "floor": 2, "type": "lab"}]
```

`POST /api/route` with `{"start": "gate_main", "destination": "ai_lab", "step_free": false}` returns:

```json
{
  "distance_meters": 170,
  "estimated_minutes": 2.8,
  "steps": [
    {"type": "start", "title": "You are here", "instruction": "Main Gate", "floor": 0},
    {"type": "walk", "title": "Walk straight", "instruction": "Walk 42 m to Main Junction", "distance": 42, "floor": 0},
    {"type": "stairs", "title": "Take the stairs", "instruction": "Go up to floor 2", "distance": 20, "floor": 2},
    {"type": "arrive", "title": "AI Lab", "instruction": "Your destination", "floor": 2}
  ],
  "path": [[500, 640], [500, 520]]
}
```

`POST /api/report` with `{"start": "...", "destination": "...", "reason": "...", "details": "..."}`
answers with any 2xx status (the body can be empty).

Step `type` is one of: start, walk, turn_left, turn_right, enter, stairs, lift, arrive.
The app also accepts `distance` / `duration` as alternative key names.

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
                    │  REST API             │
                    │  Search              │
                    │  Routing              │
                    │  Positioning          │
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
                    │  Map + Directions     │
                    └──────────────────────┘