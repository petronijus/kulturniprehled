import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
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
  NotificationService(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  // Notification IDs are stable-by-hash so re-scheduling overwrites the
  // same slot. We collapse the event id (UUID) to a 31-bit int via
  // hashCode — close enough for the int32 id space the plugin uses.
  static int _idForEvent(String eventId, String kind) =>
      ('$kind:$eventId').hashCode & 0x7FFFFFFF;

  static const int _weeklyDigestId = 1; // fixed slot

  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    final String localTzName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(localTzName));

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

  /// Cancels every previously scheduled notification and re-plans from
  /// scratch based on the supplied events. Call this after each sync.
  Future<void> reschedule(List<CachedEventRow> rows) async {
    await initialize();
    await _plugin.cancelAll();

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

    // 1) Weekly digest — next Monday at 09:00 local. Only schedule if
    //    there are events in the seven days starting on that Monday.
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
    if (weekEvents.isNotEmpty) {
      final String body = _digestBody(weekEvents);
      final String? cover = await _fetchCoverToFile(
        weekEvents.first.coverImageUrl,
      );
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
      final String? cover = await _fetchCoverToFile(event.coverImageUrl);

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
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
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
