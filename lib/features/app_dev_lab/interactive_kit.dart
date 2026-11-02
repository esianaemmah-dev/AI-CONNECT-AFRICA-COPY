import 'package:flutter/services.dart' show rootBundle;

/// Motion and interaction for the App Builder's phone templates: tabs,
/// hearts, a working cart, search, "+ Add", bottom-bar screens, dark mode,
/// count-up numbers and growing bars (assets/templates/apps/interactive_kit.*).
/// Offline, no libraries; the project scaffold splits it out like any
/// inline CSS/JS.
const kInteractiveKitMarker = 'data-otic-kit';

String? _css;
String? _js;

/// [html] with the kit added before `</body>`, once.
Future<String> withInteractiveKit(String html) async {
  if (html.contains(kInteractiveKitMarker)) return html;
  final close = html.toLowerCase().lastIndexOf('</body>');
  if (close < 0) return html;
  try {
    _css ??= await rootBundle.loadString(
      'assets/templates/apps/interactive_kit.css',
    );
    _js ??= await rootBundle.loadString(
      'assets/templates/apps/interactive_kit.js',
    );
  } catch (_) {
    return html;
  }
  final kit =
      '<style $kInteractiveKitMarker>\n$_css\n</style>\n'
      '<script $kInteractiveKitMarker>\n$_js\n</script>\n';
  return html.substring(0, close) + kit + html.substring(close);
}
