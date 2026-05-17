import 'package:flutter/material.dart';

/// Three-cell row used on the agenda card and event detail header.
/// Layout: [leading text] ─── [center text] ─── [trailing text].
class DateRow extends StatelessWidget {
  const DateRow({
    super.key,
    required this.leading,
    required this.center,
    required this.trailing,
    this.color = Colors.black,
  });

  final String leading;
  final String center;
  final String trailing;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      fontFamily: 'StackSansNotch',
      fontWeight: FontWeight.w600,
      fontSize: 12,
      color: color,
      letterSpacing: 0.48,
      height: 1.2,
    );
    return Row(
      children: <Widget>[
        Text(leading, style: style),
        const SizedBox(width: 8),
        Expanded(child: _Hairline(color: color)),
        const SizedBox(width: 8),
        Text(center, style: style),
        const SizedBox(width: 8),
        Expanded(child: _Hairline(color: color)),
        const SizedBox(width: 8),
        Text(trailing, style: style),
      ],
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(height: 1, color: color);
}
