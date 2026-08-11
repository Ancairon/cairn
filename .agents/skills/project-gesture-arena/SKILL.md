# Project Skill: Gesture Arena (Listener vs GestureDetector)

## Trigger

Load this skill before adding any new custom drag/swipe/pan gesture under `lib/features/` — anything tracking raw pointer movement to drive a UI transition (lift, dismiss, swipe-to-navigate, etc.), as opposed to a simple tap/long-press.

## Why this exists

The discovery screen (`lib/features/discovery/discovery_screen.dart`) hit the same class of real, user-reported bug twice during SOW-0003: a custom `GestureDetector`-based drag gesture silently lost Flutter's gesture-arena resolution to a descendant `Scrollable`'s own recognizer, so the custom gesture just stopped responding on any sub-page that scrolled. It happened once for the vertical lift-to-reveal gesture, and again for a swipe-back-to-previous-menu-page gesture. Both were fixed the same way. See `.agents/sow/done/SOW-0003-20260810-discovery-ui-overhaul.md` (Lessons Extracted, Followup mapping) for the incident record.

## The rule

Flutter's gesture arena lets only one recognizer "win" a given pointer sequence when multiple recognizers on the same pointer are competing (e.g. a custom `GestureDetector`'s pan recognizer vs. a `Scrollable`'s built-in scroll recognizer). `GestureDetector` participates in that arena and can lose — which looks like the gesture "randomly not working," specifically on any page that also has a scrollable region. `Listener` (`onPointerDown` / `onPointerMove` / `onPointerUp`) does not participate in arena resolution at all: it observes raw pointer events in parallel with whatever else is handling the same pointer, so it can't lose a fight it never enters.

**Default to `Listener` for any new custom drag/swipe gesture on a screen that contains, or might later contain, a `Scrollable`** — a `ListView`, a horizontally-scrolling chip row, a `PageView`, etc. Only use `GestureDetector`'s drag/pan callbacks (`onPanStart`/`onPanUpdate`/`onHorizontalDragUpdate` and similar) when there's a specific, deliberate reason arena participation is wanted (e.g. you want this gesture to *lose* to a scrollable on purpose). Plain tap/long-press callbacks (`onTap`, `onLongPress`) are unaffected by this — those aren't the pattern that broke, and `GestureDetector` remains the normal choice for them (see e.g. the tap-to-close handler on the discovery card, `lib/features/discovery/discovery_screen.dart:253-254`, or the long-press filter-chip menu in `lib/features/rated_albums/rated_albums_screen.dart:207-208`).

## Working reference: `_SwipeBackPop`

`lib/features/discovery/discovery_screen.dart` has a full-screen swipe-back-to-pop wrapper, `_SwipeBackPop` (private `StatefulWidget`, defined around line 614, paired with `_SwipeBackPopState` immediately after). Its doc comment explains the reasoning directly in code:

> Cupertino's own back gesture only answers to drags starting within the leftmost 20 logical pixels — too narrow to feel reliable, and the user wants this to work from anywhere on the page. A `Listener` (not `GestureDetector`) tracks raw pointer movement regardless of what any descendant Scrollable does with the same pointer.

Implementation (verified current at the time of writing — re-read the file if it's been a while, since it's an ordinary private widget that could be renamed or moved):

```dart
class _SwipeBackPopState extends State<_SwipeBackPop> {
  double _dragAccum = 0;
  static const _triggerDistance = 60.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _dragAccum = 0,
      onPointerMove: (event) => _dragAccum += event.delta.dx,
      onPointerUp: (_) {
        if (_dragAccum > _triggerDistance) Navigator.of(context).maybePop();
      },
      child: widget.child,
    );
  }
}
```

It's used by wrapping any pushed sub-page: `CupertinoPageRoute(builder: (context) => _SwipeBackPop(child: page))` (see the menu's push call sites, e.g. `discovery_screen.dart:97` and the `_MenuHomePage` navigation entries around lines 567-592). The same file's vertical lift-to-reveal gesture uses the same `Listener` pattern directly (`onPointerDown`/`onPointerMove`/`onPointerUp` wired to `_onDragStart`/`_onDragUpdate`/`_onDragEnd`/`_onCardDragEnd`, around lines 227-230 and 249-252).

Reuse or extend `_SwipeBackPop` itself where a full-screen swipe-back is needed elsewhere, rather than re-deriving the same fix from scratch — and reuse the `Listener` pattern (not the specific class) for any other new drag gesture that isn't a back-swipe.

## Don't assume Cupertino's built-in edge swipe-back is "good enough"

`CupertinoPageRoute`'s default back-swipe gesture only responds to drags starting in a fixed-width edge zone — confirmed by reading Flutter's own source, `packages/flutter/lib/src/cupertino/route.dart`, `const double _kBackGestureWidth = 20.0;`. Twenty logical pixels is easy to miss and does not satisfy a "swipe back from anywhere on the screen" requirement. "Widen the hit zone" is not a real fix for that ask — a full-screen `Listener`-based wrapper (as above) is the actual fix this project already applied; don't re-litigate that decision without a concrete reason.

## Same-failure check

Before shipping a new gesture, grep `lib/features/` for other `GestureDetector` drag/pan callbacks (`onPan*`, `onHorizontalDrag*`, `onVerticalDrag*`) that might have the same latent arena-loss bug. As of SOW-0003's close, no other drag-based `GestureDetector` existed in `lib/features/` — the only remaining `GestureDetector` usages are tap/long-press, which are unaffected by this pattern. Re-verify this is still true rather than assuming it, since new screens may have been added since.
