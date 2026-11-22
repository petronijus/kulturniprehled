import 'dart:convert';
import 'dart:typed_data';

/// A scannable code the server found in a ticket (`tickets.codes`, decoded
/// by `apps/api/src/kp_api/domain/ticket_codes.py`). The server re-encodes
/// it, checks the redraw scans back to the printed bytes and sends it as a
/// module bitmap — one pixel per module — which the phone only scales up.
class TicketCode {
  const TicketCode({
    required this.format,
    required this.text,
    required this.page,
    required this.modulesPng,
    required this.modulesWidth,
    required this.modulesHeight,
    this.seat,
  });

  factory TicketCode.fromMap(Map<String, dynamic> map) {
    final String? png = map['modules_png_b64'] as String?;
    return TicketCode(
      format: map['format'] as String,
      text: map['text'] as String,
      page: map['page'] as int,
      modulesPng: png == null ? null : base64Decode(png),
      modulesWidth: map['modules_width'] as int,
      modulesHeight: map['modules_height'] as int,
      seat: map['seat'] as String?,
    );
  }

  /// Parses the JSON stored in `CachedTickets.codesJson`. `null` means the
  /// server has not scanned the ticket yet.
  static List<TicketCode>? listFromJson(String? json) {
    if (json == null) {
      return null;
    }
    return (jsonDecode(json) as List<dynamic>)
        .map((dynamic e) => TicketCode.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  static String? listToJson(List<dynamic>? raw) =>
      raw == null ? null : jsonEncode(raw);

  final String format;
  final String text;
  final int page;

  /// 1-bit PNG, one pixel per module; null when the server could not redraw
  /// the code faithfully — the ticket's PDF is the only way to show it.
  final Uint8List? modulesPng;
  final int modulesWidth;
  final int modulesHeight;

  /// The seat printed on the code's page, in the ticket's own words
  /// ("Přízemí vpravo · Řada 10 · Místo 19"); null when the ticket names
  /// none or the server could not tell which.
  final String? seat;

  bool get isDrawable =>
      modulesPng != null && modulesWidth > 0 && modulesHeight > 0;

  /// Linear barcodes print their digits under the bars, so a gate attendant
  /// can type them in when the scanner gives up.
  bool get isLinear => _linearFormats.contains(format);

  static const Set<String> _linearFormats = <String>{
    'code128',
    'code39',
    'code93',
    'ean13',
    'ean8',
    'upca',
    'upce',
    'itf',
    'codabar',
  };
}
