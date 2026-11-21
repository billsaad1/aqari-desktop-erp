import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/session_idle_guard.dart';

void main() {
  testWidgets('expires an idle session after the configured timeout', (
    tester,
  ) async {
    var expirations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionIdleGuard(
          idleTimeout: const Duration(seconds: 5),
          onTimeout: () => expirations++,
          child: const Scaffold(body: Text('ERP')),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 4));
    expect(expirations, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(expirations, 1);
  });

  testWidgets('mouse input resets the idle timer', (tester) async {
    var expirations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionIdleGuard(
          idleTimeout: const Duration(seconds: 5),
          onTimeout: () => expirations++,
          child: const Scaffold(body: Text('نشاط')),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('نشاط'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(expirations, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(expirations, 1);
  });
}
