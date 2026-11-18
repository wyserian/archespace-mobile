import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/shared/config/build_info.dart';

/// Global error handling:
///
///  * [installErrorHandling] routes framework errors through [_report] and
///    replaces Flutter's default red error box with a friendly widget for
///    build/layout failures.
///  * [reportZoneError] handles uncaught async errors; pass it as the
///    `runZonedGuarded` handler in `main`.
///
/// No crash reporter is used. Errors are printed only in debug builds: in a
/// release build the system log is readable over USB, and an error can hold
/// user content. "Copy error details" copies a redacted [errorReport].
void installErrorHandling() {
  ErrorWidget.builder = (details) => _FriendlyError(details: details);
  FlutterError.onError = (details) {
    if (kDebugMode) FlutterError.presentError(details);
    _report(details.exception, details.stack);
  };
}

/// `runZonedGuarded` error handler for uncaught async errors.
void reportZoneError(Object error, StackTrace stack) => _report(error, stack);

void _report(Object error, StackTrace? stack) {
  if (!kDebugMode) return;
  debugPrint('[ArcheSpace] Uncaught error: $error');
  if (stack != null) debugPrint(stack.toString());
}

const _maxMessage = 300;
const _maxFrames = 12;
const _maxLine = 200;

// Order matters: whole values first, then what could sit inside them. Same
// rules as the web's errorReport.js.
final List<(RegExp, String Function(Match))> _rules = [
  (RegExp(r'arc1:[A-Za-z0-9+/=._-]+'), (_) => '[encrypted]'),
  (
    RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'),
    (_) => '[token]',
  ),
  // A URL keeps only its file name (and line:column), never its host or query.
  (
    RegExp(r'''\b[a-z][a-z0-9+.-]*://[^\s)'"`]+''', caseSensitive: false),
    (m) {
      final name = m[0]!.split(RegExp('[?#]')).first.split('/').last;
      return name.isEmpty ? '[url]' : name;
    },
  ),
  (
    RegExp(r'''[^\s@()<>'"`]+@[^\s@()<>'"`]+\.[A-Za-z]{2,}\b(?![:/])'''),
    (_) => '[email]',
  ),
  (
    RegExp(
      r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
      caseSensitive: false,
    ),
    (_) => '[id]',
  ),
  // Quoted text is usually data (a parse error quotes what it read).
  (RegExp(r'''"[^"\n]*"|'[^'\n]*'|`[^`\n]*`'''), (_) => '"…"'),
  (RegExp(r'[A-Za-z0-9+/_=-]{32,}'), (_) => '[redacted]'),
];

/// [text] with anything personal or secret replaced.
@visibleForTesting
String redactErrorText(String text) =>
    _rules.fold(text, (out, rule) => out.replaceAllMapped(rule.$1, rule.$2));

String _cap(String text, int max) =>
    text.length > max ? '${text.substring(0, max)}…' : text;

/// A plain-text report of [error], safe to paste into an email.
String errorReport(Object error, StackTrace? stack, {DateTime? now}) {
  final frames = (stack?.toString() ?? '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.startsWith('#'))
      .take(_maxFrames)
      .map((l) => _cap(redactErrorText(l), _maxLine))
      .toList();
  final type = _cap(redactErrorText(error.runtimeType.toString()), 60);
  return [
    'ArcheSpace error report',
    'App: ${Platform.operatingSystem} ${BuildInfo.appVersion} '
        '(${BuildInfo.buildHash})',
    'Time: ${(now ?? DateTime.now()).toUtc().toIso8601String()}',
    'OS: ${_cap(redactErrorText(Platform.operatingSystemVersion), _maxLine)}',
    'Error: $type: ${_cap(redactErrorText(error.toString()), _maxMessage)}',
    if (frames.isNotEmpty) ...['Stack:', ...frames],
  ].join('\n');
}

/// A friendly stand-in for Flutter's red error widget when a widget fails to
/// build. Rendered without assuming any inherited widgets (Theme/Directionality)
/// exist above it, so it's safe even for high-level failures. The error is
/// shown only in debug builds; "Copy error details" copies a redacted report.
class _FriendlyError extends StatefulWidget {
  const _FriendlyError({required this.details});

  final FlutterErrorDetails details;

  @override
  State<_FriendlyError> createState() => _FriendlyErrorState();
}

class _FriendlyErrorState extends State<_FriendlyError> {
  String? _note;

  Future<void> _copy() async {
    String note;
    try {
      await Clipboard.setData(
        ClipboardData(
          text: errorReport(widget.details.exception, widget.details.stack),
        ),
      );
      note = 'Copied - paste it into an email to support';
    } catch (_) {
      note = "Couldn't copy the details.";
    }
    if (mounted) setState(() => _note = note);
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFB0B0B0);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF121212),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: Color(0xFFEF6B6B)),
            const SizedBox(height: 16),
            const Text(
              'Something went wrong',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This screen ran into a problem. Go back and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 14),
            ),
            const SizedBox(height: 12),
            Semantics(
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copy,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_rounded, size: 15, color: muted),
                      SizedBox(width: 6),
                      Text(
                        'Copy error details',
                        style: TextStyle(
                          color: muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_note != null)
              Text(
                _note!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            if (kDebugMode) ...[
              const SizedBox(height: 16),
              Text(
                widget.details.exceptionAsString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFEF6B6B), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
