import 'package:flutter/material.dart';
import "restaurant.dart";
import 'package:intl/intl.dart';
import 'database_helper.dart';
import 'dart:math' as math;

class RestaurantProvider extends ChangeNotifier {
  final MasterRestaurantService _apiService = MasterRestaurantService();

  List<Restaurant> _mustTryList = [];
  List<Restaurant> get mustTryList => _mustTryList;

  //List<Restaurant> _displayedRestaurants = [];
  //List<Restaurant> get displayedRestaurants => _displayedRestaurants;

  List<Restaurant> restaurantsList = [];
  List<Restaurant> get restaurants => restaurantsList;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  RestaurantProvider() {
    loadMustTryList();
  }

  List<Restaurant> _deduplicateRestaurants(List<Restaurant> restaurants) {
    final seenIds = <String>{};
    return restaurants
        .where((restaurant) => seenIds.add(restaurant.id))
        .toList();
  }

  //loads musttrylist
  Future<void> loadMustTryList() async {
    _mustTryList = _deduplicateRestaurants(
      await DatabaseHelper.instance.getUserMustTryList(),
    );
    notifyListeners();
  }

  bool isRestaurantInMustTryList(String restaurantId) {
    return _mustTryList.any((restaurant) => restaurant.id == restaurantId);
  }

  Future<bool> addRestaurant(Restaurant restaurant) async {
    if (isRestaurantInMustTryList(restaurant.id)) {
      return false;
    }

    await DatabaseHelper.instance.addRestaurant(restaurant);

    // Add to top of list
    _mustTryList.insert(0, restaurant);
    notifyListeners();
    return true;
  }

  Future<void> removeRestaurant(String restaurantId) async {
    await DatabaseHelper.instance.removeRestaurant(restaurantId);
    _mustTryList.removeWhere((r) => r.id == restaurantId);
    notifyListeners();
  }

  // API call for locations based on a city-name String and a search term
  Future<void> fetchRestaurants(String location, String cuisine) async {
    _isLoading = true;
    notifyListeners();

    restaurantsList = await _apiService.getRestaurants(
      location: location,
      term: cuisine,
    );
    _isLoading = false;
    notifyListeners();
  }

  //filter chip helper, limits resteraunts by rating
  void limitByRating(double minRating) {
    restaurantsList = restaurantsList.where((restaurant) {
      final match = RegExp(r'\d+(\.\d+)?').firstMatch(restaurant.rating);
      final numberString = match?.group(0) ?? '0';

      double rating = double.tryParse(numberString) ?? 0.0;

      return rating >= minRating;
    }).toList();

    notifyListeners();
  }

  //filter chip helper method. filters everything from resteraunt list
  void limitByLocation(double maxDist, double userLat, double userLng) {
    restaurantsList = restaurantsList.where((restaurant) {
      double distanceInMiles = _calculateDistance(
        userLat,
        userLng,
        restaurant.latitude,
        restaurant.longitude,
      );
      return distanceInMiles <= maxDist;
    }).toList();

    notifyListeners();
  }

  //API call for locations based on Coordinates and a search term
  Future<void> fetchRestaurantsByLocation(
    double lat,
    double lng,
    String cuisine,
  ) async {
    _isLoading = true;
    notifyListeners();

    restaurantsList = await _apiService.getRestaurantsByLocation(
      latitude: lat,
      longitude: lng,
      term: cuisine,
    );

    _isLoading = false;
    notifyListeners();
  }

  // Example method for the swipe action
  /*void removeRestaurant(String id) {
    restaurantsList.removeWhere((restaurant) => restaurant.id == id);
    notifyListeners();
  }*/

  Future<void> handleSwipe(Restaurant restaurant, DismissDirection direction) async {
    restaurantsList.removeWhere((r) => r.id == restaurant.id);
    notifyListeners();

    if (direction == DismissDirection.startToEnd) {
      DateTime now = DateTime.now();
      String formattedDate = DateFormat.yMMMMd().format(now);

      restaurant.dateAdded = formattedDate;
      addRestaurant(restaurant);
    }
  }

  Future<void> loadRestaurants() async {
    _mustTryList = _deduplicateRestaurants(
      await DatabaseHelper.instance.getUserMustTryList(),
    );
    notifyListeners(); // Tell the UI to update!
  }

  // 5. The Math Helpers (Hidden away in the provider)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadiusMiles = 3958.8;
    double dLat = _degreesToRadians(lat2 - lat1);
    double dLon = _degreesToRadians(lon2 - lon1);
    lat1 = _degreesToRadians(lat1);
    lat2 = _degreesToRadians(lat2);
    double a =
        math.pow(math.sin(dLat / 2), 2) +
        math.pow(math.sin(dLon / 2), 2) * math.cos(lat1) * math.cos(lat2);
    double c = 2 * math.asin(math.sqrt(a));
    return earthRadiusMiles * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  Future<void> addJournalImage(String id, String imagePath) async {
    final index = _mustTryList.indexWhere((res) => res.id == id);
    if (index != -1) {
      _mustTryList[index].localImagePath = imagePath;

      await DatabaseHelper.instance.updateRestaurantImage(id, imagePath);

      notifyListeners();
    }
  }

  void setVolume(double volume) {
    print("Swipe volume set to: $volume");
    notifyListeners();
  }

  Future<void> updateJournalNotes(String id, String notes) async {
    final index = _mustTryList.indexWhere((res) => res.id == id);
    if (index != -1) {
      _mustTryList[index].notes = notes;

      await DatabaseHelper.instance.updateRestaurantNotes(id, notes);

      notifyListeners();
    }
  }
}

/* final List<Restaurant> _sampleData = [
    Restaurant(id: '1', name: "Bob's Burger Joint", rating: "⭐⭐⭐⭐ (4.5)", location: "College Park, MD", imageUrl: "https://picsum.photos/id/292/600/400"),
    Restaurant(id: '2', name: "Pizza Paradiso", rating: "⭐⭐⭐⭐⭐ (5.0)", location: "Washington, DC", imageUrl: "https://picsum.photos/id/429/600/400"),
    Restaurant(id: '3', name: "Taco Stand", rating: "⭐⭐⭐ (3.0)", location: "Bethesda, MD", imageUrl: "https://picsum.photos/id/431/600/400"),
  List<Restaurant> _searchResults = [];
  final List<Restaurant> _mustTryList = [];

  RestaurantProvider() {
    _searchResults = List.from(_sampleData);
  }

  List<Restaurant> get searchResults => _searchResults;
  List<Restaurant> get mustTryList => _mustTryList;
  ];*/
/*
  void triggerManualScrape() {
    _searchResults = List.from(_sampleData);
    notifyListeners();
  }

}*/
