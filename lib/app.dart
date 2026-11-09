import 'package:flutter/material.dart';
import 'tabs/list_tab.dart';
import 'tabs/search_tab.dart';
import 'tabs/swipe_tab.dart';
import 'widgets/bottom_nav.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int _currentIndex = 0;

  final List<Widget> _tabs = const [
    SwipeTab(),
    SearchTab(),
    ListTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _tabs[_currentIndex],
        bottomNavigationBar: BottomNav(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
        ),
      ),
    );
  }
}