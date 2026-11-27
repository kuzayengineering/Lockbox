import 'dart:async';

import 'package:flutter/material.dart';

/// Google Photos–style fast scroller: on long lists (more than
/// [kFastScrollScreens] screens), a handle appears at the right edge while
/// scrolling. Drag it to jump through the list; a bubble shows where you are
/// (e.g. the date). Shorter lists keep the normal thin scroll bar.
const kFastScrollScreens = 5;

class FastScroller extends StatefulWidget {
  const FastScroller({super.key, required this.builder, this.labelFor});

  /// Builds the scroll view; it must use the given controller.
  final Widget Function(BuildContext context, ScrollController controller) builder;

  /// The label for a scroll position (e.g. the date heading there), or null.
  final String? Function(double offset)? labelFor;

  @override
  State<FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<FastScroller> {
  final _controller = ScrollController();
  bool _long = false;
  bool _shown = false;
  bool _dragging = false;
  double _dragTop = 0;
  Timer? _hide;

  static const _thumbHeight = 52.0;
  static const _thumbWidth = 40.0;

  @override
  void dispose() {
    _hide?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool _isLong(ScrollMetrics m) =>
      m.maxScrollExtent > (kFastScrollScreens - 1) * m.viewportDimension;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final long = _isLong(n.metrics);
    if (long != _long) setState(() => _long = long);
    if (long && (n is ScrollUpdateNotification || n is ScrollStartNotification)) {
      if (!_shown) setState(() => _shown = true);
      _scheduleHide();
    }
    return false;
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && !_dragging) setState(() => _shown = false);
    });
  }

  /// Space at the bottom kept clear of the phone's navigation buttons
  /// (the list itself runs underneath them).
  double _bottomInset = 0;

  double _track(double viewport) =>
      (viewport - _thumbHeight - _bottomInset).clamp(1.0, double.infinity);

  double _thumbTop(double viewport) {
    if (_dragging) return _dragTop;
    if (!_controller.hasClients) return 0;
    final p = _controller.position;
    if (p.maxScrollExtent <= 0) return 0;
    return (p.pixels / p.maxScrollExtent).clamp(0.0, 1.0) * _track(viewport);
  }

  void _dragTo(double top, double viewport) {
    final track = _track(viewport);
    _dragTop = top.clamp(0.0, track);
    final p = _controller.position;
    _controller.jumpTo(_dragTop / track * p.maxScrollExtent);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _bottomInset = MediaQuery.paddingOf(context).bottom + 8;
    return LayoutBuilder(builder: (context, box) {
      final viewport = box.maxHeight;
      return Stack(children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Scrollbar(
            controller: _controller,
            // The thin bar only for short lists; long ones get the handle.
            notificationPredicate: (n) => n.depth == 0 && !_long,
            child: widget.builder(context, _controller),
          ),
        ),
        if (_long)
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final top = _thumbTop(viewport);
              final label = _dragging && widget.labelFor != null && _controller.hasClients
                  ? widget.labelFor!(_controller.offset)
                  : null;
              return Positioned(
                top: top,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_shown,
                  child: AnimatedOpacity(
                    opacity: _shown ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (label != null)
                        Container(
                          margin: const EdgeInsets.only(right: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                          ),
                          child: Text(label,
                              style: TextStyle(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                        ),
                      GestureDetector(
                        key: const ValueKey('fast-scroll-handle'),
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: (_) {
                          _hide?.cancel();
                          setState(() {
                            _dragging = true;
                            _dragTop = _thumbTop(viewport);
                          });
                        },
                        onVerticalDragUpdate: (d) => _dragTo(_dragTop + d.delta.dy, viewport),
                        onVerticalDragEnd: (_) {
                          setState(() => _dragging = false);
                          _scheduleHide();
                        },
                        onVerticalDragCancel: () {
                          setState(() => _dragging = false);
                          _scheduleHide();
                        },
                        child: Container(
                          width: _thumbWidth,
                          height: _thumbHeight,
                          decoration: BoxDecoration(
                            color: _dragging ? scheme.primary : scheme.surfaceContainerHighest,
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(26)),
                            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
                          ),
                          child: Icon(Icons.unfold_more,
                              color: _dragging ? scheme.onPrimary : scheme.onSurface),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
      ]);
    });
  }
}
