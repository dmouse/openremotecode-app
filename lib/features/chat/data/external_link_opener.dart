import 'package:url_launcher/url_launcher.dart';

import '../domain/web_link.dart';

/// Native navigation is separate from rendering. Rendering never calls this;
/// the UI requests it only after the user reviews a destination and taps Open.
final class ExternalLinkOpener {
  const ExternalLinkOpener({this.launch = _launchExternal});
  final Future<bool> Function(Uri) launch;

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<bool> open(String? destination) async {
    final uri = parseWebLink(destination);
    if (uri == null) return false;
    try {
      return await launch(uri).timeout(const Duration(seconds: 10));
    } catch (_) {
      return false;
    }
  }
}
