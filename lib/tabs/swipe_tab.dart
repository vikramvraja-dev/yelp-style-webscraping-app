import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../restaurant_provider.dart';
import 'package:local_hub/restaurant.dart';

class SwipeTab extends StatelessWidget {
  const SwipeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RestaurantProvider>();

    return Column(
      children: [
        Expanded(
          child: _buildBody(provider),
        ),
      ],
    );
  }

  Widget _buildBody(RestaurantProvider provider) {
    // 1. Handle Loading State
    if (provider.isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.red),
            SizedBox(height: 16),
            Text("Scraping local results...",
              style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
          ],
        ),
      );
    }

    // Handle Empty Results
    if (provider.restaurants.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                "No restaurants found.",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text(
                "Try moving the map or searching for a different cuisine in the Search tab.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    // Handle Data State (Success)
    return Stack(
      children: provider.restaurants.asMap().entries.map((entry) {
        int index = entry.key;
        var res = entry.value;

        // Keep the full card stack swipeable so consecutive swipes work.
        // if (index == 0) {
          return Dismissible(
            key: Key(res.id),
            onDismissed: (dir) => provider.handleSwipe(res, dir),
            background: _swipeLabel(Alignment.centerLeft, Colors.green, "SAVE"),
            secondaryBackground: _swipeLabel(Alignment.centerRight, Colors.red, "DISCARD"),
            child: _restaurantCard(res),
          );
        //}
        //return _restaurantCard(res);
      }
      ).toList().reversed.toList(),
    );
  }

  Widget _swipeLabel(Alignment align, Color color, String text) {
    return Container(
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      color: color,
      child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    );
  }

  Widget _restaurantCard(Restaurant res) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 8,
        child: Column(
          children: [
            Expanded(
              child: Image.network(
                res.imageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: Colors.grey[300],
                  child: const Icon(Icons.broken_image, size: 50),
                ),
              ),
            ),
            ListTile(
              title: Text(res.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("${res.rating}\n${res.location}"),
            ),
          ],
        ),
      ),
    );
  }
}
