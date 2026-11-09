# LocalHub Food Finder

LocalHub is a Flutter mobile app for discovering nearby restaurants, comparing
results on a map, and keeping a personal “must try” food journal. It was built
as a group project for CMSC436 at the University of Maryland.

Group Project with Frazer and Anish

This repository is a cleaned portfolio snapshot. It contains no API keys,
signing keys, user databases, location history, or original university Git
history.

## Implemented features

- Search by city/state or by the map's current coordinates.
- Webscraping from multiple restaurant/travel websites.
- Search by cuisine and combine results
- Display geocoded restaurant markers on an interactive OpenStreetMap map.
- Filter the active result set by minimum rating or distance from the map center.
- Swipe restaurant cards to save or discard suggestions.
- Persist a deduplicated “must try” list in a local SQLite database.
- Add journal notes and a camera photo to saved restaurants.
- Open a restaurant's external page from its journal entry.
- Show loading, empty, image-fallback, and network-error states.

## Technology

- Flutter and Dart
- Provider/ChangeNotifier for application state
- `sqflite` for on-device persistence
- `flutter_map` and OpenStreetMap tiles for mapping
- Nominatim for forward and reverse geocoding
- Yelp Fusion API plus best-effort HTML adapters for restaurant discovery
- `http` and `html` for networking and parsing
- `image_picker` and `url_launcher` for mobile integrations
- Flutter Test and the standard Flutter analyzer/lint configuration

## Architecture

```text
Swipe / Search / List tabs
          |
          v
  RestaurantProvider ----------------> DatabaseHelper -> SQLite
          |
          v
MasterRestaurantService
   |          |           |
   v          v           v
 Yelp   RestaurantJi  TripAdvisor
              \         /
               v       v
        shared NominatimClient
       (identity, queue, cache)
```

`RestaurantProvider` coordinates UI state, filtering, swipe behavior, and
persistence. `MasterRestaurantService` runs the configured discovery adapters
and tolerates an individual source failing. All Nominatim calls share one
app-wide queue, a delay greater than one second, in-flight de-duplication, and
an in-memory response cache. This keeps repeated searches within a session
from generating duplicate geocoding calls without writing a user's searches
or locations to disk.

Technical highlights include asynchronous multi-source aggregation, a
repository-style SQLite helper, Haversine distance filtering, HTML/JSON
parsing with fallbacks, map viewport fitting, and platform integrations for
camera capture and external links.

## Setup

### Prerequisites

- A Flutter SDK compatible with Dart `^3.10.7`
- Android Studio/Android SDK for Android development
- Xcode and CocoaPods for iOS development
- A Yelp Fusion API credential for Yelp-backed results

### Install and run

```bash
git clone https://github.com/vikramvraja-dev/localhub-food-finder.git
cd localhub-food-finder
flutter pub get
cp config.example.json config.local.json
```

Edit `config.local.json`, then run:

```bash
flutter run --dart-define-from-file=config.local.json
```

`config.local.json` is ignored by Git. Do not commit it.

## API and map configuration

| Setting | Required | Purpose |
| --- | --- | --- |
| `YELP_API_KEY` | For Yelp results | Yelp Fusion authorization credential |
| `NOMINATIM_BASE_URL` | Yes | Geocoding service base URL; defaults to the public OSMF instance |
| `NOMINATIM_CONTACT_EMAIL` | Recommended for the public instance | A real, monitored operator contact included in Nominatim identification |

The example file contains only a placeholder Yelp value and an empty contact
field. Supply contact information that you control; this project intentionally
does not invent or publish an address.

### Yelp credential safety

`--dart-define` is configuration, not secret storage. Values compiled into a
Flutter client can be extracted from the application binary. It is acceptable
for local development, but do not distribute a production build containing a
private Yelp credential. A distributed app should call a controlled backend
proxy that stores the key server-side, authenticates clients, rate-limits
requests, and returns only the data the app needs.

### Nominatim and OpenStreetMap usage

The default configuration targets the public OpenStreetMap Foundation
Nominatim instance. Use it only for moderate, user-triggered requests and
follow the current [Nominatim Usage Policy](https://operations.osmfoundation.org/policies/nominatim/).
The app identifies itself, serializes requests across all adapters to remain
below one request per second, caches successful responses in memory, and shows
OpenStreetMap attribution on the map. It does not implement autocomplete or
bulk geocoding. For a distributed or higher-volume app, use an appropriate
provider or controlled proxy and keep `NOMINATIM_BASE_URL` configurable.

Map tiles come from the standard OpenStreetMap tile service. Any deployment
must also comply with the current [Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/),
including visible attribution, identification, caching, and no bulk/offline
tile downloading.

The HTML-based discovery adapters depend on third-party page structures and
may stop working when those sites change. Review each provider's current terms
and access policies before enabling an adapter in a distributed application.

## Validation

```bash
flutter analyze
flutter test
```

The included widget smoke test verifies the app's three-section bottom
navigation. Network-backed behavior requires valid local configuration and
should be tested separately from unit/widget tests.

## Screenshots

No publication-ready screenshots were included in the source project. See
[`docs/screenshots/README.md`](docs/screenshots/README.md) for documented
placeholders and guidance for adding sanitized images.

## Academic and group-project attribution

LocalHub Food Finder was created as a group project for **CMSC436 at the
University of Maryland**. The repository is published with the group's
permission as a portfolio snapshot. Individual ownership should be described
accurately in the contributors table; no claim is made that one person created
the entire application.
