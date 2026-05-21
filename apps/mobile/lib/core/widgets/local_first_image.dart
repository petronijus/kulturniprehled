import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/sync/offline_cache_service.dart';

/// `Image` that consults the local CachedImages table first. If the URL
/// has been downloaded by [OfflineCacheService.refresh] (or any other
/// path), we render directly from disk — works fully offline. If not,
/// fall back to a live network fetch so past events and brand-new
/// covers still render before the next sync.
///
/// Resolves once on mount (and whenever the URL changes). We do **not**
/// listen on the cache for live swaps: in practice [refresh] runs on
/// sync, well before the user reaches the screen. Stale-while-revalidate
/// is good enough here.
class LocalFirstImage extends ConsumerStatefulWidget {
  const LocalFirstImage({
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.frameBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.fallback,
    super.key,
  });

  final String imageUrl;
  final BoxFit fit;
  final ImageFrameBuilder? frameBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;
  // Rendered when [imageUrl] is empty. Distinct from [errorBuilder],
  // which fires on a *failed* render.
  final Widget? fallback;

  @override
  ConsumerState<LocalFirstImage> createState() => _LocalFirstImageState();
}

class _LocalFirstImageState extends ConsumerState<LocalFirstImage> {
  late Future<File?> _resolveLocal;

  @override
  void initState() {
    super.initState();
    _resolveLocal = _lookup(widget.imageUrl);
  }

  @override
  void didUpdateWidget(covariant LocalFirstImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _resolveLocal = _lookup(widget.imageUrl);
    }
  }

  Future<File?> _lookup(String url) async {
    if (url.isEmpty) return null;
    final KpDatabase db = ref.read(kpDatabaseProvider);
    final CachedImageRow? row = await db.findCachedImage(
      OfflineCacheService.urlHash(url),
    );
    if (row == null) return null;
    final File file = File(row.localPath);
    if (!await file.exists()) return null;
    return file;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl.isEmpty) {
      return widget.fallback ?? const SizedBox.shrink();
    }
    return FutureBuilder<File?>(
      future: _resolveLocal,
      builder: (BuildContext context, AsyncSnapshot<File?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Brief — local DB lookup. Render the network fetch path early
          // so the user doesn't see a flicker into a placeholder.
          return _network();
        }
        final File? cached = snapshot.data;
        if (cached != null) {
          return Image.file(
            cached,
            fit: widget.fit,
            frameBuilder: widget.frameBuilder,
            errorBuilder: widget.errorBuilder,
          );
        }
        return _network();
      },
    );
  }

  Widget _network() {
    return Image.network(
      widget.imageUrl,
      fit: widget.fit,
      frameBuilder: widget.frameBuilder,
      loadingBuilder: widget.loadingBuilder,
      errorBuilder: widget.errorBuilder,
    );
  }
}
