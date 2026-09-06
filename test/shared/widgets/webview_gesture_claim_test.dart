import 'package:Cuplivo/shared/widgets/webview_gesture_claim.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wrapped WebView forwards pointer events to the native side through a
/// passive `Listener`, so without the claim every wheel signal and touch drag
/// also reaches the enclosing `Scrollable` — the chat list scrolls alongside
/// the HTML (Windows) or eats the drag entirely (Android). These cases pin
/// the claim behavior: over the WebView only the HTML scrolls, never the list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness({required Widget child}) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 200, child: Text('top')),
            SizedBox(height: 300, child: child),
            const SizedBox(height: 800, child: Text('bottom')),
          ],
        ),
      ),
    );
  }

  Future<void> pumpClaim(WidgetTester tester, {required bool claim}) async {
    await tester.pumpWidget(
      harness(
        child: claim
            ? WebviewScrollClaim(
                child: Container(color: const Color(0xFF00FF00)),
              )
            : Container(color: const Color(0xFF00FF00)),
      ),
    );
    await tester.pump();
  }

  ScrollableState listState(WidgetTester tester) {
    return tester.state<ScrollableState>(find.byType(Scrollable).first);
  }

  testWidgets('wheel over the claim never scrolls the outer list', (
    tester,
  ) async {
    await pumpClaim(tester, claim: true);
    final target = find.byType(WebviewScrollClaim);
    final center = tester.getCenter(target);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();

    expect(listState(tester).position.pixels, 0);
  });

  testWidgets('wheel without the claim scrolls the outer list', (tester) async {
    await pumpClaim(tester, claim: false);
    final center = tester.getCenter(find.byType(Container));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();

    expect(listState(tester).position.pixels, greaterThan(0));
  });

  testWidgets('drag over the claim never drags the outer list', (tester) async {
    await pumpClaim(tester, claim: true);
    await tester.drag(find.byType(WebviewScrollClaim), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(listState(tester).position.pixels, 0);
  });

  testWidgets('drag without the claim drags the outer list', (tester) async {
    await pumpClaim(tester, claim: false);
    await tester.drag(find.byType(Container), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(listState(tester).position.pixels, greaterThan(0));
  });
}
