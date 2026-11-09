import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_hub/widgets/bottom_nav.dart';

void main() {
  testWidgets('bottom navigation exposes all app sections', (tester) async {
    int? selectedIndex;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: BottomNav(
            currentIndex: 0,
            onTap: (index) => selectedIndex = index,
          ),
        ),
      ),
    );

    expect(find.text('Swipe'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('List'), findsOneWidget);

    await tester.tap(find.text('Search'));
    expect(selectedIndex, 1);
  });
}
