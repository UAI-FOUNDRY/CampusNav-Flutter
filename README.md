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
- [x] Custom Metro Line visual theme
- [x] Custom typography
- [x] Home screen
- [x] Destination cards
- [x] Destination search
- [x] Local search filtering
- [x] Navigation route screen
- [x] Route visualization component
- [x] Navigation between screens
- [x] API service foundation
- [x] Destination and route data models
- [ ] Interactive campus map
- [ ] Floor selector
- [ ] Real campus data
- [ ] Flask backend integration
- [ ] Real A* route calculation
- [ ] Real-time positioning
- [ ] QR-based positioning
- [ ] Multi-floor route visualization

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