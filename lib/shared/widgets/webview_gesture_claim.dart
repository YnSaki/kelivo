import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A WebView gesture recognizer that eagerly accepts every pointer and
/// trackpad pan/zoom sequence, so the WebView never loses a gesture to an
/// enclosing `Scrollable`.
///
/// The vendored `webview_windows` `Webview` forwards pointer events to the
/// native side through a passive `Listener` — which does not take part in the
/// gesture arena — while the enclosing chat list's drag recognizer races the
/// same events. Without an immediate accept the list wins and the HTML
/// underneath never scrolls (Android) or the gesture goes to both (Windows
/// touch input).
class WebviewEagerGestureRecognizer extends EagerGestureRecognizer {
  /// Recognizer set for platform WebViews that should own every gesture, fit
  /// for [WebViewWidget.gestureRecognizers]. Uses the foundation `Factory`
  /// type that webview_flutter expects.
  static Set<Factory<OneSequenceGestureRecognizer>> get recognizers => {
    Factory<OneSequenceGestureRecognizer>(WebviewEagerGestureRecognizer.new),
  };

  @override
  String get debugDescription => 'eager-webview';

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
    stopTrackingPointer(event.pointer);
  }
}

/// Wraps a platform WebView so wheel signals and touch/trackpad drags over it
/// never reach the enclosing `Scrollable`.
///
/// `webview_windows` renders via a texture and forwards wheel deltas to the
/// native side through a passive `Listener`, so the same `PointerScrollEvent`
/// keeps bubbling to the message list's `Scrollable` and scrolls both (issue
/// #706 follow-up). [Listener.onPointerSignal] registers a no-op with the
/// [PointerSignalResolver] first — the resolver only runs the first
/// registration, which is the deepest widget in the hierarchy — and the eager
/// recognizer below claims drags on touch and trackpad input. The WebView
/// itself is unaffected: it still receives every forwarded event.
class WebviewScrollClaim extends StatelessWidget {
  const WebviewScrollClaim({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (PointerSignalEvent _) {},
        );
      },
      child: RawGestureDetector(
        gestures: {
          WebviewEagerGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<WebviewEagerGestureRecognizer>(
                WebviewEagerGestureRecognizer.new,
                (WebviewEagerGestureRecognizer _) {},
              ),
        },
        child: child,
      ),
    );
  }
}
