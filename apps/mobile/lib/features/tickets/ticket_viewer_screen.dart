import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';

// Displays a downloaded ticket. The bytes never reach the API process —
// `GET /v1/tickets/{id}/url` returns a short-lived presigned URL that the
// app fetches directly from MinIO. After the first download we keep the
// file under path_provider/tickets/<ticket-id>.bin and record it in
// CachedTicketFiles so subsequent opens (and offline use at the venue!)
// hit local disk only.
//
// Image MIMEs render inline. PDFs are stored but not rendered yet — adding
// a PDF view widget needs an extra native plugin and is on the M7 backlog.

class TicketViewerScreen extends ConsumerStatefulWidget {
  const TicketViewerScreen({required this.ticketId, super.key});

  final String ticketId;

  @override
  ConsumerState<TicketViewerScreen> createState() => _TicketViewerScreenState();
}

class _TicketViewerScreenState extends ConsumerState<TicketViewerScreen> {
  File? _file;
  String? _mime;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final File file = await _ensureLocalFile();
      final CachedTicketRow? meta = await ref
          .read(kpDatabaseProvider)
          .findTicket(widget.ticketId);
      if (!mounted) {
        return;
      }
      setState(() {
        _file = file;
        _mime = meta?.mimeType;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<File> _ensureLocalFile() async {
    final KpDatabase db = ref.read(kpDatabaseProvider);
    final CachedTicketFileRow? cached = await db.findTicketFile(
      widget.ticketId,
    );
    if (cached != null) {
      final File existing = File(cached.localPath);
      if (await existing.exists()) {
        return existing;
      }
    }

    final KpClient client = ref.read(kpClientProvider);
    final Response<dynamic> meta = await client.dio.get<dynamic>(
      '/v1/tickets/${widget.ticketId}/url',
    );
    final String downloadUrl =
        (meta.data! as Map<String, dynamic>)['download_url'] as String;

    final Directory appDir = await getApplicationDocumentsDirectory();
    final Directory ticketsDir = Directory(p.join(appDir.path, 'tickets'));
    if (!await ticketsDir.exists()) {
      await ticketsDir.create(recursive: true);
    }
    final File destination = File(
      p.join(ticketsDir.path, '${widget.ticketId}.bin'),
    );
    // Bypass the auth interceptor — presigned URLs already carry the
    // SigV4 signature, and the MinIO host does not honour our JWT.
    final Dio raw = Dio(BaseOptions(responseType: ResponseType.bytes));
    final Response<List<int>> download = await raw.get<List<int>>(downloadUrl);
    await destination.writeAsBytes(download.data!, flush: true);

    final CachedTicketRow? ticket = await db.findTicket(widget.ticketId);
    await db.upsertTicketFile(
      CachedTicketFilesCompanion.insert(
        ticketId: widget.ticketId,
        localPath: destination.path,
        mimeType: ticket?.mimeType ?? 'application/octet-stream',
        sizeBytes: Value<int?>(await destination.length()),
        hashSha256: const Value<String?>(null),
        downloadedAt: DateTime.now(),
      ),
    );
    return destination;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lístek')),
      body: _build(),
    );
  }

  Widget _build() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 80),
            const SizedBox(height: 16),
            Text(
              'Lístek se nepodařilo stáhnout:\n$_error',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    final File? file = _file;
    if (file == null) {
      return const Center(child: Text('Lístek není dostupný.'));
    }
    if (_mime?.startsWith('image/') ?? false) {
      return InteractiveViewer(child: Center(child: Image.file(file)));
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.picture_as_pdf_outlined, size: 80),
          const SizedBox(height: 16),
          Text(
            'PDF lístek je stažený v zařízení '
            '(${(_file?.lengthSync() ?? 0) ~/ 1024} kB), '
            'ale prohlížeč PDF přijde v M7.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            file.path,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
