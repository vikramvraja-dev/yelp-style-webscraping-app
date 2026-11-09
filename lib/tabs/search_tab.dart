import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:local_hub/restaurant.dart';
import 'package:local_hub/restaurant_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  bool showFilters = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final MapController mapController = MapController();
  final TextEditingController cuisineController = TextEditingController();
  final TextEditingController locationController = TextEditingController();

  double _swipeVolume = 0.5;
  double _minRating = 3.0;

  @override
  void dispose() {
    cuisineController.dispose();
    locationController.dispose();
    mapController.dispose();
    super.dispose();
  }

  void _toggleFilters() {
    setState(() {
      showFilters = !showFilters;
    });
  }

  List<Restaurant> _mappedRestaurants(List<Restaurant> restaurants) {
    return restaurants
        .where((r) => r.latitude != 0 && r.longitude != 0)
        .toList();
  }

  void _fitMapToRestaurants(List<Restaurant> restaurants) {
    final mappedRestaurants = _mappedRestaurants(restaurants);
    if (mappedRestaurants.isEmpty) return;

    if (mappedRestaurants.length == 1) {
      final only = mappedRestaurants.first;
      mapController.move(LatLng(only.latitude, only.longitude), 15.0);
      return;
    }

    final points = mappedRestaurants.map((r) => LatLng(r.latitude, r.longitude)).toList();
    final bounds = LatLngBounds.fromPoints(points);

    mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  Future<void> executeSearch() async {
    final String cuisine = cuisineController.text.trim().isEmpty ? 'restaurants' : cuisineController.text.trim();
    final String location = locationController.text.trim();
    final provider = context.read<RestaurantProvider>();

    if (location.isNotEmpty) {
      await provider.fetchRestaurants(location, cuisine);
      _fitMapToRestaurants(provider.restaurants);
    } else {
      final curCenter = mapController.camera.center;
      await provider.fetchRestaurantsByLocation(curCenter.latitude, curCenter.longitude, cuisine);
      _fitMapToRestaurants(provider.restaurants);
    }
  }

  void _showRestaurantDetails(Restaurant res) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(res.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(res.rating, style: const TextStyle(fontSize: 16, color: Colors.black87)),
              const SizedBox(height: 4),
              Text(res.location, style: const TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final restaurantProvider = context.watch<RestaurantProvider>();
    final restaurants = restaurantProvider.restaurants;

    final List<Marker> restaurantMarkers = restaurants
        .where((r) => r.latitude != 0 && r.longitude != 0)
        .map((res) => Marker(
              point: LatLng(res.latitude, res.longitude),
              width: 50,
              height: 50,
              child: GestureDetector(
                onTap: () => _showRestaurantDetails(res),
                child: const Icon(Icons.location_on, color: Colors.red, size: 40),
              ),
            ))
        .toList();

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildPreferencesDrawer(),
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: const MapOptions(
              initialCenter: LatLng(38.9897, -76.9378),
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'localhub.food.finder',
              ),
              MarkerLayer(markers: restaurantMarkers),
              SimpleAttributionWidget(
                source: const Text('OpenStreetMap contributors'),
                onTap: () => launchUrl(
                  Uri.parse('https://www.openstreetmap.org/copyright'),
                ),
              ),
            ],
          ),
          if (restaurantProvider.isLoading)
            const Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                bottom: false,
                child: LinearProgressIndicator(
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                searchPanel(),
                if (showFilters)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: filterChips(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.red),
            child: Text('Settings & Preferences', style: TextStyle(color: Colors.white, fontSize: 24)),
          ),
          ListTile(
            leading: const Icon(Icons.location_on),
            title: const Text('Default Search Location'),
            subtitle: const Text('College Park, MD'),
            onTap: () {

            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text('Minimum Rating Filter: ${_minRating.toStringAsFixed(1)} Stars'),
          ),
          Slider(
            value: _minRating,
            min: 1.0,
            max: 5.0,
            divisions: 8,
            activeColor: Colors.red,
            onChanged: (value) {
              setState(() => _minRating = value);

            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text('Swipe Sound Volume'),
          ),
          Slider(
            value: _swipeVolume,
            activeColor: Colors.red,
            onChanged: (value) {
              setState(() => _swipeVolume = value);
              context.read<RestaurantProvider>().setVolume(value);
            },
          ),
        ],
      ),
    );
  }

  Widget searchPanel() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: locationController,
              onSubmitted: (_) => executeSearch(),
              decoration: InputDecoration(
                hintText: "City, State or Zip (Leave blank for map area)",
                hintStyle: const TextStyle(fontSize: 14),

                prefixIcon: IconButton(
                  icon: const Icon(Icons.menu, color: Colors.black),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
            const Divider(height: 1, thickness: 1),
            TextField(
              controller: cuisineController,
              onSubmitted: (_) => executeSearch(),
              decoration: InputDecoration(
                hintText: "Search Cuisine (e.g. Sushi, Burgers)",
                hintStyle: const TextStyle(fontSize: 14),
                prefixIcon: IconButton(
                  icon: const Icon(Icons.search, color: Colors.red),
                  onPressed: executeSearch,
                ),
                suffixIcon: IconButton(
                  icon: Icon(Icons.tune, color: showFilters ? Colors.red : Colors.grey),
                  onPressed: _toggleFilters,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget filterChips() {
    final filters = ["4.5+ stars", "4+ stars", "1 mile", "2 miles"];
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ActionChip(
              label: Text(filters[index]),
              backgroundColor: Colors.white,
              shape: const StadiumBorder(side: BorderSide(color: Colors.grey)),
              onPressed: () {
                final provider = context.read<RestaurantProvider>();
                final curCenter = mapController.camera.center;

                switch (index) {
                  case 0: provider.limitByRating(4.5); break;
                  case 1: provider.limitByRating(4.0); break;
                  case 2: provider.limitByLocation(1.0, curCenter.latitude, curCenter.longitude); break;
                  case 3: provider.limitByLocation(2.0, curCenter.latitude, curCenter.longitude); break;
                }
                _fitMapToRestaurants(provider.restaurants);
              },
            ),
          );
        },
      ),
    );
  }
}
