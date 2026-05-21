import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';

/// Proactively materialises everything a user might want to look at when
/// they're offline at a venue: cover images, venue images, and ticket
/// binaries for every event that has not yet started. Run after every
/// successful `pullChanges()` so the local disk catches up with whatever
/// the server just told us about.
///
/// Idempotent: every download is keyed by URL hash / ticket id, and we
/// skip anything already on disk. Failures are swallowed per-item — the
/// next sync gets another chance.
class OfflineCacheService {
  OfflineCacheService(this._ref);

  final Ref _ref;

  /// SHA-1 of the source URL — stable, deterministic, collision-proof
  /// for our scale. Used as the primary key in CachedImages and as the
  /// on-disk filename, so different MinIO objects always get distinct
  /// files and the same URL reused across events shares one cached file.
  static String urlHash(String url) =>
      sha1.convert(utf8.encode(url)).toString();

  Future<void> refresh() async {
    final KpDatabase db = _ref.read(kpDatabaseProvider);
    final List<CachedEventRow> upcoming = await db.watchUpcomingEvents();
    if (upcoming.isEmpty) {
      return;
    }

    final Set<String> imageUrls = <String>{};
    for (final CachedEventRow event in upcoming) {
      final String? cover = event.coverImageUrl;
      if (cover != null && cover.isNotEmpty) imageUrls.add(cover);
      final String? venue = event.venueImageUrl;
      if (venue != null && venue.isNotEmpty) imageUrls.add(venue);
    }
    for (final String url in imageUrls) {
      await _ensureImageCached(url);
    }

    final List<String> upcomingIds = upcoming
        .map((CachedEventRow e) => e.id)
        .toList();
    final List<CachedTicketRow> tickets = await db.ticketsForEventIds(
      upcomingIds,
    );
    for (final CachedTicketRow ticket in tickets) {
      await _ensureTicketCached(ticket);
    }
  }

  Future<File?> _ensureImageCached(String url) async {
    final KpDatabase db = _ref.read(kpDatabaseProvider);
    final String hash = urlHash(url);
    final CachedImageRow? existing = await db.findCachedImage(hash);
    if (existing != null) {
      final File current = File(existing.localPath);
      if (await current.exists()) {
        return current;
      }
      // Row points at a file that's gone (cache wipe, OS purge). Treat as
      // a miss; the upsert below will overwrite it.
    }

    final File destination = await _imageFileFor(hash, url);
    try {
      final Dio raw = Dio(BaseOptions(responseType: ResponseType.bytes));
      final Response<List<int>> resp = await raw.get<List<int>>(url);
      final List<int>? bytes = resp.data;
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      await destination.writeAsBytes(bytes, flush: true);
      await db.upsertCachedImage(
        CachedImagesCompanion.insert(
          urlHash: hash,
          sourceUrl: url,
          localPath: destination.path,
          sizeBytes: Value<int?>(await destination.length()),
          downloadedAt: DateTime.now(),
        ),
      );
      return destination;
    } catch (_) {
      return null;
    }
  }

  Future<File?> _ensureTicketCached(CachedTicketRow ticket) async {
    final KpDatabase db = _ref.read(kpDatabaseProvider);
    final CachedTicketFileRow? existing = await db.findTicketFile(ticket.id);
    if (existing != null) {
      final File current = File(existing.localPath);
      if (await current.exists()) {
        return current;
      }
    }

    try {
      final KpClient client = _ref.read(kpClientProvider);
      final Response<dynamic> meta = await client.dio.get<dynamic>(
        '/v1/tickets/${ticket.id}/url',
      );
      final String downloadUrl =
          (meta.data! as Map<String, dynamic>)['download_url'] as String;

      final Directory appDir = await getApplicationDocumentsDirectory();
      final Directory ticketsDir = Directory(p.join(appDir.path, 'tickets'));
      if (!await ticketsDir.exists()) {
        await ticketsDir.create(recursive: true);
      }
      final File destination = File(
        p.join(ticketsDir.path, '${ticket.id}.bin'),
      );

      // Bypass the auth interceptor — presigned URLs already carry the
      // SigV4 signature, and the MinIO host does not honour our JWT.
      final Dio raw = Dio(BaseOptions(responseType: ResponseType.bytes));
      final Response<List<int>> download = await raw.get<List<int>>(
        downloadUrl,
      );
      final List<int>? bytes = download.data;
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      await destination.writeAsBytes(bytes, flush: true);

      await db.upsertTicketFile(
        CachedTicketFilesCompanion.insert(
          ticketId: ticket.id,
          localPath: destination.path,
          mimeType: ticket.mimeType,
          sizeBytes: Value<int?>(await destination.length()),
          hashSha256: const Value<String?>(null),
          downloadedAt: DateTime.now(),
        ),
      );
      return destination;
    } catch (_) {
      return null;
    }
  }

  Future<File> _imageFileFor(String hash, String sourceUrl) async {
    final Directory appDir = await getApplicationDocumentsDirectory();
    final Directory imagesDir = Directory(p.join(appDir.path, 'event_images'));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    return File(p.join(imagesDir.path, '$hash${_extensionFromUrl(sourceUrl)}'));
  }

  String _extensionFromUrl(String url) {
    final String pathOnly = Uri.parse(url).path;
    final int dot = pathOnly.lastIndexOf('.');
    if (dot < 0 || pathOnly.length - dot > 5) {
      return '.bin';
    }
    return pathOnly.substring(dot).toLowerCase();
  }
}

final Provider<OfflineCacheService> offlineCacheServiceProvider =
    Provider<OfflineCacheService>(OfflineCacheService.new);
