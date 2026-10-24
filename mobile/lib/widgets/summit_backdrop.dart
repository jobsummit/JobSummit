import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'motion.dart';

/// How much of the mountain each screen shows below the status bar: all of it
/// with the moon or sun on Today, half on Jobs, the whole climb (with your exams on
/// its trail) on My exams, none on Agenda and Practice. Switching tabs slides it between these.
abstract final class SummitHeights {
  static const full = 236.0;
  static const today = full;
  static const jobs = 150.0;
  static const exams = 214.0;
  static const agenda = 0.0;
  static const practice = 0.0;

  static const privateRoles = 206.0;
  static const privateApplications = 118.0;
  static const privateProfile = 168.0;

  /// The Govt tabs, in order: Today, Jobs, My exams, Agenda, Practice.
  static const govtTabs = [today, jobs, exams, agenda, practice];

  /// The Private tabs: Roles, Applications, Profile.
  static const privateTabs = [privateRoles, privateApplications, privateProfile];
}

/// Where things sit on the scene: points in its 348 × 300 design space, placed on
/// a screen [width] wide with [visible] px of mountain under a [topInset] status
/// bar (the scene is bottom-aligned, so a shorter view shows its lower part).
abstract final class SummitScene {
  /// The trail's stops, foot to summit: Applied, Admit card, Exam, Answer key,
  /// Result (at the peak). A switchback across the paper layers.
  static const stops = [
    Offset(36, 262),
    Offset(132, 238),
    Offset(244, 212),
    Offset(140, 152),
    Offset(180, 98),
  ];

  static Offset place(Offset design, {required double width, required double topInset, required double visible}) {
    final scene = topInset + SummitHeights.full;
    return Offset(design.dx * width / 348, topInset + visible - scene + design.dy * scene / 300);
  }

  /// The trail in design space: a smooth line through the stops, each bend
  /// leaning towards the next stop (so it stays on the mountain).
  static Path trail() {
    final trail = Path()..moveTo(stops.first.dx, stops.first.dy);
    for (var i = 1; i < stops.length; i++) {
      final a = stops[i - 1], b = stops[i];
      trail.quadraticBezierTo(a.dx + (b.dx - a.dx) * 0.7, a.dy, b.dx, b.dy);
    }
    return trail;
  }

  /// Everything under the ridge lines (the far, middle and front layers together).
  static bool onMountain(Offset design) =>
      SummitPainter.farPath().contains(design) ||
      SummitPainter.midPath().contains(design) ||
      SummitPainter.frontPath().contains(design);
}

/// The paper-cut Summit behind the screens: a moon (dark) or sun (light) over three
/// layers of paper mountains with soft shadows, and paper waves above the bottom
/// bar. [height] is how much shows under the status bar; a new value slides the
/// mountains up out of sight or back down (instantly with "Remove animations").
/// [orb] shows the moon or sun (Today); it fades on the other tabs.
class SummitBackdrop extends StatelessWidget {
  const SummitBackdrop({super.key, required this.height, this.waves = true, this.orb = true});

  final double height;
  final bool waves;
  final bool orb;

  static const duration = Duration(milliseconds: 520);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final colors = SummitColors.of(AppPalette.current);
    final still = motionOff(context);
    final sceneHeight = top + SummitHeights.full;
    SummitPainter part({bool sky = false, double orb = 0, bool ridges = false}) =>
        SummitPainter(colors, sceneHeight: sceneHeight, sky: sky, orb: orb, ridges: ridges);
    // Painted once, in layers of their own; switching tabs only slides them (and
    // fades the moon), so no frame has to repaint the mountains.
    final scene = SizedBox(
      height: sceneHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: CustomPaint(painter: part(sky: true))),
          AnimatedOpacity(
            opacity: orb ? 1 : 0,
            duration: still ? Duration.zero : duration,
            curve: Curves.easeInOutCubic,
            child: RepaintBoundary(child: CustomPaint(painter: part(orb: 1))),
          ),
          RepaintBoundary(child: CustomPaint(painter: part(ridges: true))),
        ],
      ),
    );
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: height),
            duration: still ? Duration.zero : duration,
            curve: Curves.easeInOutCubic,
            child: scene,
            // Bottom of the scene at [top] + h: everything above slides out of sight.
            builder: (context, h, child) => Transform.translate(offset: Offset(0, h - SummitHeights.full), child: child),
          ),
        ),
        if (waves)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 72,
            child: IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _WavesPainter(colors)))),
          ),
      ],
    );
  }
}

/// The scene's colours, from a palette.
@immutable
class SummitColors {
  const SummitColors({
    required this.sky,
    required this.far,
    required this.mid,
    required this.front,
    required this.shadow,
    required this.snow,
    required this.orb,
    required this.stars,
    required this.wave1,
    required this.wave2,
  });

  final Color sky;
  final Color far;
  final Color mid;
  final Color front;
  final Color shadow;
  final Color snow;
  final Color orb; // the moon, or the sun
  final Color? stars; // night only
  final Color wave1;
  final Color wave2;

  // Equal colours: no repaint when the screen around the scene rebuilds.
  @override
  bool operator ==(Object other) =>
      other is SummitColors &&
      other.sky == sky &&
      other.far == far &&
      other.mid == mid &&
      other.front == front &&
      other.shadow == shadow &&
      other.snow == snow &&
      other.orb == orb &&
      other.stars == stars &&
      other.wave1 == wave1 &&
      other.wave2 == wave2;

  @override
  int get hashCode => Object.hash(sky, far, mid, front, shadow, snow, orb, stars, wave1, wave2);

  factory SummitColors.of(Palette p) {
    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    if (p.isLight) {
      return SummitColors(
        sky: mix(p.background, Colors.white, 0.6),
        far: mix(p.background, p.periwinkle, 0.22),
        mid: mix(p.background, p.periwinkle, 0.10),
        front: p.background,
        shadow: p.textPrimary.withValues(alpha: 0.10),
        snow: Colors.white,
        orb: p.sky,
        stars: null,
        wave1: mix(p.background, p.sky, 0.2),
        wave2: mix(p.background, p.sky, 0.38),
      );
    }
    return SummitColors(
      sky: mix(p.background, p.surface, 0.35),
      far: mix(p.background, p.outline, 0.75),
      mid: mix(p.background, p.surfaceVariant, 0.55),
      front: p.background,
      shadow: Colors.black.withValues(alpha: 0.35),
      snow: p.textPrimary,
      orb: p.sky,
      stars: p.textPrimary,
      wave1: mix(p.background, p.surface, 0.75),
      wave2: mix(p.background, p.surfaceVariant, 0.7),
    );
  }
}

/// Drawn in a 348 × 300 design space stretched to the scene, bottom-aligned in the
/// visible box: a shorter box shows only the lower part (the sky leaves first).
class SummitPainter extends CustomPainter {
  SummitPainter(this.c, {required this.sceneHeight, this.orb = 1, this.sky = true, this.ridges = true});

  final SummitColors c;
  final double sceneHeight;

  /// 0..1: how much the moon or sun shows.
  final double orb;

  /// Which parts to paint: the backdrop puts each in a layer of its own.
  final bool sky;
  final bool ridges;

  /// Where the moon or sun sits: low on the right, rising from behind the far
  /// ridge, below the title row's chips and avatar.
  static const orbCentre = Offset(240, 128);

  static Path farPath() => Path()
    ..moveTo(0, 190)
    ..lineTo(60, 130)
    ..lineTo(110, 170)
    ..lineTo(180, 96)
    ..lineTo(240, 150)
    ..lineTo(300, 112)
    ..lineTo(348, 150)
    ..lineTo(348, 300)
    ..lineTo(0, 300)
    ..close();

  static Path snowPath() => Path()
    ..moveTo(180, 96)
    ..lineTo(196, 112)
    ..lineTo(188, 112)
    ..lineTo(176, 104)
    ..close();

  static Path midPath() => Path()
    ..moveTo(0, 232)
    ..cubicTo(40, 200, 70, 184, 100, 196)
    ..cubicTo(130, 208, 160, 162, 200, 160)
    ..cubicTo(240, 158, 262, 200, 300, 190)
    ..cubicTo(322, 184, 340, 178, 348, 180)
    ..lineTo(348, 300)
    ..lineTo(0, 300)
    ..close();

  static Path frontPath() => Path()
    ..moveTo(0, 270)
    ..cubicTo(60, 244, 120, 288, 180, 264)
    ..cubicTo(240, 240, 300, 278, 348, 258)
    ..lineTo(348, 300)
    ..lineTo(0, 300)
    ..close();

  static const _stars = [Offset(40, 56), Offset(110, 36), Offset(170, 66), Offset(320, 40), Offset(214, 22)];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    final sx = size.width / 348, sy = sceneHeight / 300, dy = size.height - sceneHeight;
    final night = c.stars != null;
    // A round moon on any screen: placed in the scene, sized in screen pixels.
    if (orb > 0) {
      final centre = Offset(orbCentre.dx * sx, dy + orbCentre.dy * sy);
      canvas.drawCircle(centre, 44 * sx, Paint()..color = c.orb.withValues(alpha: (night ? 0.10 : 0.18) * orb));
      canvas.drawCircle(centre, 30 * sx, Paint()..color = c.orb.withValues(alpha: orb));
    }
    if (!sky && !ridges) return;
    canvas.save();
    // Bottom-align the full scene in the visible box.
    canvas.translate(0, dy);
    canvas.scale(sx, sy);

    if (sky) {
      canvas.drawRect(const Rect.fromLTWH(0, 0, 348, 300), Paint()..color = c.sky);
      if (night) {
        final star = Paint()..color = c.stars!.withValues(alpha: 0.8);
        for (final s in _stars) {
          canvas.drawCircle(s, 1.4, star);
        }
      }
    }

    if (ridges) {
      final shadow = Paint()..color = c.shadow;
      void layer(Path p, Color color, double drop) {
        canvas.drawPath(p.shift(Offset(0, drop)), shadow);
        canvas.drawPath(p, Paint()..color = color);
      }

      layer(farPath(), c.far, 7);
      canvas.drawPath(snowPath(), Paint()..color = c.snow);
      layer(midPath(), c.mid, 7);
      layer(frontPath(), c.front, 6);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SummitPainter old) =>
      old.c != c || old.sceneHeight != sceneHeight || old.orb != orb || old.sky != sky || old.ridges != ridges;
}

class _WavesPainter extends CustomPainter {
  _WavesPainter(this.c);

  final SummitColors c;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 348, size.height / 80);
    canvas.drawPath(
      Path()
        ..moveTo(0, 30)
        ..cubicTo(60, 6, 120, 44, 180, 24)
        ..cubicTo(240, 4, 300, 34, 348, 18)
        ..lineTo(348, 80)
        ..lineTo(0, 80)
        ..close(),
      Paint()..color = c.wave1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 56)
        ..cubicTo(70, 38, 130, 66, 200, 50)
        ..cubicTo(260, 36, 310, 58, 348, 46)
        ..lineTo(348, 80)
        ..lineTo(0, 80)
        ..close(),
      Paint()..color = c.wave2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.c != c;
}
