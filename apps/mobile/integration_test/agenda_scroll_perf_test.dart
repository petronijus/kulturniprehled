import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kp_mobile/core/sensors/tilt_provider.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/agenda_screen.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/sync/offline_cache_service.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';

/// Scroll benchmark for the agenda: a realistic season (covers served from
/// the offline image cache, several events per month) scrolled down and back
/// up while the tilt sensor jitters the way a hand-held phone does.
/// Run with `just perf-agenda <device>`; each report lands in
/// `build/<reportKey>.json`. Watch the raster percentiles: the agenda's cost
/// is GPU-side (difference-blend layers, covers), the build phase is small.

const int _eventCount = 36;
const int _coverEdgePx = 960;

class _IdleSyncController extends SyncController {
  @override
  SyncState build() => const SyncState();

  @override
  Future<void> pullChanges({int batchSize = 500}) async {}
}

/// Hand-held phone: a slow sway plus sensor noise and tremor, fed through
/// the production smoother at the sensor's UI rate.
TiltSmoother _handHeldTilt() {
  final TiltSmoother tilt = TiltSmoother();
  final math.Random random = math.Random(7);
  int tick = 0;
  double noise() => 0.1 * (random.nextDouble() - 0.5);
  _timers.add(
    Timer.periodic(const Duration(milliseconds: 16), (_) {
      tick++;
      tilt.addSample(
        0.15 * math.sin(tick / 40) + noise(),
        9.81 + 0.15 * math.cos(tick / 55) + noise(),
      );
    }),
  );
  _cleanups.add(tilt.dispose);
  return tilt;
}

final List<Timer> _timers = <Timer>[];
final List<void Function()> _cleanups = <void Function()>[];

/// A photo-like cover (smooth gradients plus grain) at the size the ingest
/// skill uploads, encoded once and reused under several URLs so every card
/// decodes its own copy, as with real covers.
Future<Uint8List> _coverBytes(int seed) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Rect rect = Rect.fromLTWH(0, 0, 960, 960);
  final math.Random random = math.Random(seed);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, <Color>[
        Color(0xFF000000 | random.nextInt(0xFFFFFF)),
        Color(0xFF000000 | random.nextInt(0xFFFFFF)),
      ]),
  );
  final Paint grain = Paint();
  for (int i = 0; i < 4000; i++) {
    grain.color = Color(random.nextInt(0x40FFFFFF));
    canvas.drawCircle(
      Offset(random.nextDouble() * 960, random.nextDouble() * 960),
      random.nextDouble() * 6,
      grain,
    );
  }
  final ui.Image image = await recorder.endRecording().toImage(
    _coverEdgePx,
    _coverEdgePx,
  );
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

Future<List<CachedEventRow>> _seed(KpDatabase db) async {
  final Directory dir = await Directory.systemTemp.createTemp('kp_perf');
  _cleanups.add(() => dir.deleteSync(recursive: true));
  final List<Uint8List> covers = <Uint8List>[
    for (int s = 0; s < 4; s++) await _coverBytes(s),
  ];
  const List<String> titles = <String>[
    'Mahler: Symfonie č. 9',
    'PJ Harvey',
    'Sokolov',
    'Rusalka',
    'Bachovy suity',
    'Kraftwerk 3-D',
    'Strakonický dudák',
    'Fallen Leaves',
  ];
  const List<String> categories = <String>[
    'concert',
    'theatre',
    'cinema',
    'exhibition',
  ];
  final DateTime start = DateTime.now().toUtc().add(const Duration(days: 2));
  final List<CachedEventRow> rows = <CachedEventRow>[];
  for (int i = 0; i < _eventCount; i++) {
    final String url = 'https://images.example.com/cover-$i.png';
    final String? cover = i % 7 == 6 ? null : url;
    if (cover != null) {
      final File file = File('${dir.path}/cover-$i.png');
      await file.writeAsBytes(covers[i % covers.length]);
      await db.upsertCachedImage(
        CachedImagesCompanion.insert(
          urlHash: OfflineCacheService.urlHash(cover),
          sourceUrl: cover,
          localPath: file.path,
          downloadedAt: DateTime.now().toUtc(),
        ),
      );
    }
    final DateTime startsAt = start.add(Duration(days: i * 5, hours: i % 3));
    rows.add(
      CachedEventRow(
        id: 'evt-$i',
        workspaceId: 'ws-1',
        title: titles[i % titles.length],
        category: categories[i % categories.length],
        startsAt: startsAt,
        venueTimezone: 'Europe/Prague',
        status: 'planned',
        source: 'manual',
        coverImageUrl: cover,
        version: 1,
        updatedAt: startsAt,
        cachedAt: startsAt,
      ),
    );
  }
  return rows;
}

Future<void> _scrollPass(WidgetTester tester, Finder list, double dy) async {
  for (int i = 0; i < 6; i++) {
    await tester.timedDrag(
      list,
      Offset(0, dy),
      const Duration(milliseconds: 450),
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(() async => initializeDateFormatting('cs'));
  tearDownAll(() {
    for (final Timer t in _timers) {
      t.cancel();
    }
    for (final void Function() cleanup in _cleanups) {
      cleanup();
    }
  });

  testWidgets('agenda scrolls within the frame budget', (tester) async {
    final KpDatabase db = KpDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final List<CachedEventRow> rows =
        await tester.runAsync(() => _seed(db)) as List<CachedEventRow>;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kpDatabaseProvider.overrideWith((ref) => db),
          agendaProvider.overrideWith(
            (ref) => Stream<List<CachedEventRow>>.value(rows),
          ),
          syncControllerProvider.overrideWith(_IdleSyncController.new),
          tiltListenableProvider.overrideWith((ref) => _handHeldTilt()),
        ],
        child: const MaterialApp(home: AgendaScreen()),
      ),
    );
    // Let covers decode and the title blur-ins finish before measuring.
    await Future<void>.delayed(const Duration(seconds: 4));

    final Finder list = find.byType(Scrollable).first;
    await binding.watchPerformance(() async {
      await _scrollPass(tester, list, -900);
      await _scrollPass(tester, list, 900);
    }, reportKey: 'agenda_scroll');

    // The live test binding draws every vsync even when nothing changed, so
    // this measures what one frame of a still agenda costs, not whether the
    // screen goes idle (TiltSmoother's tests cover that).
    await binding.watchPerformance(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
    }, reportKey: 'agenda_static');
  });
}
