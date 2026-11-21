import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Locks an authenticated application area after a period without user input.
class SessionIdleGuard extends StatefulWidget {
  static final ValueNotifier<int> _globalActivitySequence = ValueNotifier<int>(
    0,
  );

  /// Lets the app-level overlay listener reset the active session timer.
  static void notifyGlobalActivity() {
    _globalActivitySequence.value++;
  }

  const SessionIdleGuard({
    required this.child,
    required this.onTimeout,
    this.idleTimeout = const Duration(minutes: 15),
    super.key,
  });

  final Widget child;
  final FutureOr<void> Function() onTimeout;
  final Duration idleTimeout;

  @override
  State<SessionIdleGuard> createState() => _SessionIdleGuardState();
}

class _SessionIdleGuardState extends State<SessionIdleGuard>
    with WidgetsBindingObserver {
  Timer? _idleTimer;
  DateTime _lastActivityAt = DateTime.now();
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    SessionIdleGuard._globalActivitySequence.addListener(_recordActivity);
    _armTimer(widget.idleTimeout);
  }

  @override
  void didUpdateWidget(covariant SessionIdleGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.idleTimeout != widget.idleTimeout) {
      _armTimer(widget.idleTimeout);
    }
  }

  void _armTimer(Duration duration) {
    _idleTimer?.cancel();
    if (_expired) return;
    if (duration <= Duration.zero) {
      unawaited(_expire());
      return;
    }
    _idleTimer = Timer(duration, () => unawaited(_expire()));
  }

  void _recordActivity() {
    if (_expired) return;
    _lastActivityAt = DateTime.now();
    _armTimer(widget.idleTimeout);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _recordActivity();
    }
    return false;
  }

  Future<void> _expire() async {
    if (_expired || !mounted) return;
    _expired = true;
    _idleTimer?.cancel();
    try {
      await widget.onTimeout();
    } catch (error, stackTrace) {
      debugPrint('Session idle timeout handler failed: $error\n$stackTrace');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _expired) return;
    final elapsed = DateTime.now().difference(_lastActivityAt);
    _armTimer(widget.idleTimeout - elapsed);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    SessionIdleGuard._globalActivitySequence.removeListener(_recordActivity);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _recordActivity(),
      onPointerMove: (_) => _recordActivity(),
      onPointerSignal: (PointerSignalEvent _) => _recordActivity(),
      child: widget.child,
    );
  }
}
