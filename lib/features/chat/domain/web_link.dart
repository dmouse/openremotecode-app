final _unsafeWebUrl = RegExp(
  r'[\s\\\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
);

/// Message destinations are untrusted. Only explicit, absolute web URLs may
/// leave the app; never resolve a path against the local OpenCode workspace.
Uri? parseWebLink(String? value) {
  if (value == null ||
      value.isEmpty ||
      value.length > 4096 ||
      _unsafeWebUrl.hasMatch(value)) {
    return null;
  }
  try {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

final _webUrls = RegExp(r'''https?://[^\s<>"'`]+''', caseSensitive: false);

/// OpenCode's plain-text PR reference. Keep the destination separate from its
/// displayed label, without rewriting stored messages or requiring Markdown.
const pullRequestLinkPattern =
    r'\b(PR[ \t]+#[0-9]{1,20})[ \t]+\((https?://(?:[^\s<>()]|\([^\s<>()]*\))+)\)';
final _pullRequestLinks = RegExp(pullRequestLinkPattern, caseSensitive: false);
typedef MessageWebLink = ({int start, int end, String text, String label});

/// Bounded link spans for literal user prompts; no Markdown interpretation.
Iterable<MessageWebLink> messageWebLinks(String text) sync* {
  final pullRequests = <int, MessageWebLink>{
    for (final match in _pullRequestLinks.allMatches(text))
      if (parseWebLink(match.group(2)) != null)
        match.end - 1 - match.group(2)!.length: (
          start: match.start,
          end: match.end,
          text: match.group(2)!,
          label: match.group(1)!,
        ),
  };
  var count = 0;
  for (final match in _webUrls.allMatches(text)) {
    final pullRequest = pullRequests[match.start];
    if (pullRequest != null) {
      yield pullRequest;
      if (++count >= 64) return;
      continue;
    }
    final raw = match.group(0)!;
    if (raw.length > 4096) continue;
    final extraClosing = {
      for (final pair in {')': '(', ']': '[', '}': '{'}.entries)
        pair.key:
            pair.key.allMatches(raw).length - pair.value.allMatches(raw).length,
    };
    var end = raw.length;
    while (end > 0) {
      final last = raw[end - 1];
      if ('.,;:!?'.contains(last) || (extraClosing[last] ?? 0) > 0) {
        if (extraClosing.containsKey(last)) {
          extraClosing[last] = extraClosing[last]! - 1;
        }
        end--;
      } else {
        break;
      }
    }
    final value = raw.substring(0, end);
    if (parseWebLink(value) == null) continue;
    yield (
      start: match.start,
      end: match.start + value.length,
      text: value,
      label: value,
    );
    if (++count >= 64) return;
  }
}
