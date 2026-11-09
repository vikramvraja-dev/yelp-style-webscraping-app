import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'restaurant_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    ChangeNotifierProvider(
      create: (context) => RestaurantProvider(),
      child: const MyApp(),
    ),
  );
}
