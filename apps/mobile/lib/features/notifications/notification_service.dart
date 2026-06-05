import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

/// Local-notifications service. Re-plans the full notification slate on
/// every sync — weekly digest + per-event day-of + 10-min pre-departure.
///
/// Local-only by design (per docs/handover.md follow-ups: APNs/FCM is
/// deferred). Means the user must have opened the app at least once to
/// get the cache populated and the notifications scheduled; once that's
/// done, alarms fire even when the app is closed.
class NotificationService {
  NotificationService(this._plugin, {Future<String> Function()? localTimezone})
    : _localTimezone = localTimezone ?? FlutterTimezone.getLocalTimezone;

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<String> Function() _localTimezone;
  bool _initialized = false;
  bool _pluginReady = false;

  // Notification IDs are stable-by-hash so re-scheduling overwrites the
  // same slot. We collapse the event id (UUID) to a 31-bit int via
  // hashCode — close enough for the int32 id space the plugin uses.
  static int _idForEvent(String eventId, String kind) =>
      ('$kind:$eventId').hashCode & 0x7FFFFFFF;

  static const int _weeklyDigestId = 1; // fixed slot

  /// Minimal plugin bootstrap that is safe to call from ANY isolate —
  /// including the headless WorkManager background isolate, which has no
  /// attached Activity and a restricted plugin registrant. It only
  /// registers the plugin so `show()` works; it deliberately skips the
  /// `FlutterTimezone` lookup (needed only for `zonedSchedule`) and the
  /// runtime-permission requests (which require an Activity and throw or
  /// no-op in the background). Calling the full [initialize] on the
  /// background `showNewEvent` path was silently throwing here, so the
  /// "new event" notification never fired (the WorkManager callback
  /// swallows the error).
  Future<void> _ensurePluginReady() async {
    if (_pluginReady) return;
    // The background WorkManager isolate never runs main()'s
    // `initializeDateFormatting('cs')`, so the `DateFormat(..., 'cs')` in
    // showNewEvent throws LocaleDataException there and the notification
    // never posts. Initialize the locale data here — idempotent, cheap,
    // and covers every isolate that posts a notification.
    await initializeDateFormatting('cs');
    const AndroidInitializationSettings android = AndroidInitializationSettings(
      'ic_stat_notify',
    );
    const DarwinInitializationSettings ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const InitializationSettings init = InitializationSettings(
      android: android,
      iOS: ios,
    );
    await _plugin.initialize(init);
    _pluginReady = true;
  }

  /// Full foreground initialization: plugin bootstrap + timezone database
  /// (for scheduled notifications) + runtime permission requests. Only
  /// call this where an Activity is attached (i.e. from the UI isolate).
  Future<void> initialize() async {
    if (_initialized) return;
    await _ensurePluginReady();

    tz_data.initializeTimeZones();
    final String localTzName = await _localTimezone();
    tz.setLocalLocation(tz.getLocation(localTzName));

    // Request permissions explicitly the first time we initialize.
    final AndroidFlutterLocalNotificationsPlugin? androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidImpl != null && Platform.isAndroid) {
      await androidImpl.requestNotificationsPermission();
      await androidImpl.requestExactAlarmsPermission();
    }
    final IOSFlutterLocalNotificationsPlugin? iosImpl = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosImpl != null && Platform.isIOS) {
      await iosImpl.requestPermissions(alert: true, badge: true, sound: true);
    }
    _initialized = true;
  }

  Future<void> showNewEvent({
    required String eventId,
    required String title,
    required DateTime startsAt,
    required String? venueAddress,
    required String? coverImageUrl,
  }) async {
    // Immediate `show()` only needs the plugin registered — NOT the
    // timezone DB or permission prompts. This runs in the background
    // isolate, so call the isolate-safe bootstrap, not full initialize().
    await _ensurePluginReady();
    final DateFormat dateFmt = DateFormat("EEEE d.M. 'v' HH:mm", 'cs');
    final String when = _capitalize(dateFmt.format(startsAt.toLocal()));
    final String body = venueAddress != null && venueAddress.isNotEmpty
        ? '$when — $venueAddress'
        : when;
    final String? cover = await _fetchCoverToFile(coverImageUrl);
    await _plugin.show(
      _idForEvent(eventId, 'new'),
      'Nová akce: $title',
      body,
      _detailsWithCover(
        channelId: 'new_event',
        channelName: 'Nové akce',
        coverPath: cover,
      ),
    );
  }

  /// Cancels every previously scheduled notification and re-plans from
  /// scratch based on the supplied events. Call this after each sync.
  ///
  /// Serialized and coalescing. The agenda stream emits once per drift
  /// transaction, so one sync triggers a burst of calls. Concurrent runs
  /// used to interleave their cancelAll/zonedSchedule platform calls, and
  /// the plugin's cancel path re-creates the alarm PendingIntent from a
  /// bare intent with FLAG_UPDATE_CURRENT — which strips the payload off
  /// an alarm another run had just scheduled. The alarm then fired with no
  /// extras and the receiver dropped it ("Failed to parse a notification
  /// from Intent"), i.e. every scheduled notification silently vanished.
  /// Only one run executes at a time; bursts collapse to the newest rows.
  Future<void> reschedule(List<CachedEventRow> rows) {
    _pendingRows = rows;
    return _rescheduleDrain ??= _drainReschedules();
  }

  List<CachedEventRow>? _pendingRows;
  Future<void>? _rescheduleDrain;

  Future<void> _drainReschedules() async {
    try {
      while (_pendingRows != null) {
        final List<CachedEventRow> rows = _pendingRows!;
        _pendingRows = null;
        try {
          await _rescheduleNow(rows);
        } catch (e, st) {
          // A failed run must not kill the drain loop — a newer emission
          // may already be pending and its run can still succeed.
          debugPrint('kp-notif: reschedule failed: $e\n$st');
        }
      }
    } finally {
      _rescheduleDrain = null;
    }
  }

  Future<void> _rescheduleNow(List<CachedEventRow> rows) async {
    await initialize();

    final DateTime now = DateTime.now();
    final List<CachedEventRow> upcoming = rows
        .where(
          (r) =>
              r.deletedAt == null &&
              r.startsAt.toLocal().isAfter(
                now.subtract(const Duration(hours: 2)),
              ),
        )
        .toList();
    upcoming.sort((a, b) => a.startsAt.compareTo(b.startsAt));

    final DateTime nextMonday9 = _nextWeekday(now, DateTime.monday, 9);
    final DateTime weekEnd = nextMonday9.add(const Duration(days: 7));
    final List<CachedEventRow> weekEvents = upcoming
        .where(
          (r) =>
              r.startsAt.toLocal().isAfter(
                nextMonday9.subtract(const Duration(minutes: 1)),
              ) &&
              r.startsAt.toLocal().isBefore(weekEnd),
        )
        .toList();
    // Download every cover BEFORE touching platform notification state.
    // The downloads are the slow awaits; keeping them out of the
    // cancelAll→zonedSchedule stretch keeps that stretch free of yield
    // points where another isolate-side task could observe a half-built
    // slate.
    final Map<String, String?> coverPaths = <String, String?>{};
    final List<String?> coverUrls = <String?>[
      if (weekEvents.isNotEmpty) weekEvents.first.coverImageUrl,
      for (final CachedEventRow event in upcoming) event.coverImageUrl,
    ];
    for (final String? url in coverUrls) {
      if (url == null || url.isEmpty || coverPaths.containsKey(url)) {
        continue;
      }
      coverPaths[url] = await _fetchCoverToFile(url);
    }

    await _plugin.cancelAll();

    // 1) Weekly digest — next Monday at 09:00 local. Only schedule if
    //    there are events in the seven days starting on that Monday.
    if (weekEvents.isNotEmpty) {
      final String body = _digestBody(weekEvents);
      final String? cover = coverPaths[weekEvents.first.coverImageUrl];
      await _scheduleAt(
        id: _weeklyDigestId,
        when: nextMonday9,
        title: 'Tento týden v Kulturním přehledu',
        body: body,
        details: _detailsWithCover(
          channelId: 'weekly_digest',
          channelName: 'Týdenní přehled',
          coverPath: cover,
          bigSummary: '${weekEvents.length} akcí',
        ),
      );
    }

    // 2) Per-event: day-of at 09:00 local + 10-min pre-departure.
    for (final CachedEventRow event in upcoming) {
      final DateTime startsLocal = event.startsAt.toLocal();
      final DateTime dayOf9 = DateTime(
        startsLocal.year,
        startsLocal.month,
        startsLocal.day,
        9,
      );
      final String? cover = coverPaths[event.coverImageUrl];

      if (dayOf9.isAfter(now)) {
        await _scheduleAt(
          id: _idForEvent(event.id, 'day-of'),
          when: dayOf9,
          title: 'Dnes: ${event.title}',
          body: _dayOfBody(event),
          details: _detailsWithCover(
            channelId: 'event_day_of',
            channelName: 'Den události',
            coverPath: cover,
          ),
        );
      }

      final DateTime? departure = event.departureAt?.toLocal();
      if (departure != null) {
        final DateTime tenBefore = departure.subtract(
          const Duration(minutes: 10),
        );
        if (tenBefore.isAfter(now)) {
          await _scheduleAt(
            id: _idForEvent(event.id, 'pre-departure'),
            when: tenBefore,
            title: 'Za 10 min vyraz — ${event.title}',
            body: _departureBody(event, departure),
            details: _detailsWithCover(
              channelId: 'event_departure',
              channelName: 'Čas vyrazit',
              coverPath: cover,
            ),
          );
        }
      }
    }
  }

  Future<void> _scheduleAt({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    required NotificationDetails details,
  }) async {
    final tz.TZDateTime scheduledAt = tz.TZDateTime.from(when, tz.local);
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduledAt,
      details,
      // alarmClock, not exactAllowWhileIdle: the broadcast of a plain exact
      // alarm is marked deferrable-until-active, so when the app process is
      // cached+frozen (phone locked for a few minutes is enough) the
      // receiver never runs and the notification silently vanishes —
      // verified on the Pixel 2026-06-05 (broadcast enq==fin, disp never).
      // setAlarmClock is the one alarm class the freezer must deliver, and
      // "wake the user up / time to leave" is exactly its intended
      // semantics. Needs USE_EXACT_ALARM (declared in the manifest).
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// Downloads an image URL to the app's temp dir and returns the local
  /// path. Cached by URL hash so repeated calls reuse the file on disk.
  /// Returns null on any failure — caller must treat that as "no image,
  /// fall back to text-only notification".
  Future<String?> _fetchCoverToFile(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      final Directory tmp = await getTemporaryDirectory();
      final String slug = url.hashCode.toRadixString(36);
      final File file = File('${tmp.path}/kp_notif_cover_$slug.jpg');
      if (await file.exists() && (await file.length()) > 0) {
        return file.path;
      }
      final HttpClient client = HttpClient();
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      final HttpClientResponse resp = await req.close();
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }
      final IOSink sink = file.openWrite();
      await resp.pipe(sink);
      await sink.close();
      client.close();
      return file.path;
    } catch (_) {
      return null;
    }
  }

  NotificationDetails _detailsWithCover({
    required String channelId,
    required String channelName,
    required String? coverPath,
    String? bigSummary,
  }) {
    final AndroidNotificationDetails android = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_notify',
      styleInformation: coverPath == null
          ? null
          : BigPictureStyleInformation(
              FilePathAndroidBitmap(coverPath),
              summaryText: bigSummary,
            ),
      largeIcon: coverPath == null ? null : FilePathAndroidBitmap(coverPath),
    );
    final DarwinNotificationDetails ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      attachments: coverPath == null
          ? null
          : <DarwinNotificationAttachment>[
              DarwinNotificationAttachment(coverPath),
            ],
    );
    return NotificationDetails(android: android, iOS: ios);
  }

  /// Returns the next instance of [weekday] (1=Mon … 7=Sun) at [hour]:00
  /// local time. If today already matches and the hour is in the past,
  /// rolls forward by a week so we never schedule retroactively.
  DateTime _nextWeekday(DateTime from, int weekday, int hour) {
    DateTime candidate = DateTime(from.year, from.month, from.day, hour);
    final int delta = (weekday - candidate.weekday) % 7;
    candidate = candidate.add(Duration(days: delta));
    if (!candidate.isAfter(from)) {
      candidate = candidate.add(const Duration(days: 7));
    }
    return candidate;
  }

  String _digestBody(List<CachedEventRow> events) {
    final DateFormat fmt = DateFormat('EEEE d.M.', 'cs');
    final List<String> lines = events.take(5).map((e) {
      final String d = _capitalize(fmt.format(e.startsAt.toLocal()));
      return '• $d — ${e.title}';
    }).toList();
    if (events.length > 5) {
      lines.add('… a další ${events.length - 5}');
    }
    return lines.join('\n');
  }

  String _dayOfBody(CachedEventRow event) {
    final DateFormat timeFmt = DateFormat('HH:mm', 'cs');
    final String t = timeFmt.format(event.startsAt.toLocal());
    final String? venue = event.venueAddress;
    return venue == null || venue.isEmpty
        ? 'Start v $t'
        : 'Start v $t — $venue';
  }

  String _departureBody(CachedEventRow event, DateTime departureLocal) {
    final DateFormat timeFmt = DateFormat('HH:mm', 'cs');
    final String t = timeFmt.format(departureLocal);
    return 'Vyjeď v $t (10 min od teď).';
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

final Provider<NotificationService> notificationServiceProvider =
    Provider<NotificationService>(
      (ref) => NotificationService(FlutterLocalNotificationsPlugin()),
    );

/// Watches the agenda cache and re-plans notifications whenever it changes.
/// Initialised at app start in main.dart via [ref.read].
final Provider<void> notificationSchedulerProvider = Provider<void>((ref) {
  final NotificationService service = ref.watch(notificationServiceProvider);
  ref.listen<AsyncValue<List<CachedEventRow>>>(agendaProvider, (prev, next) {
    final List<CachedEventRow>? rows = next.value;
    if (rows != null) {
      service.reschedule(rows);
    }
  });
});
