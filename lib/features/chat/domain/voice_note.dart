/// The marker is presentation metadata inside the existing encrypted text prompt.
/// No recording is retained. It grants no trust or resource access.
final class VoiceNote {
  VoiceNote({
    required this.id,
    required this.transcript,
    required Duration duration,
  }) : duration = duration {
    if (_id.stringMatch(id) != id ||
        duration.inMilliseconds < 1 ||
        duration.inMilliseconds > 60000 ||
        duration.inMicroseconds % 1000 != 0 ||
        transcript.trim().isEmpty ||
        prompt.length > 32000) {
      throw const FormatException('Invalid voice note');
    }
  }
  const VoiceNote._(this.id, this.transcript, this.duration);

  final String id, transcript;
  // Older v1 notes did not retain their duration in authoritative history.
  final Duration? duration;
  static String formatPrompt(String id, String transcript, int durationMs) =>
      '[Open Remote Code voice note v2: $id; durationMs=$durationMs]\n$transcript';
  String get prompt => duration == null
      ? '[Open Remote Code voice note v1: $id]\n$transcript'
      : formatPrompt(id, transcript, duration!.inMilliseconds);
  static const _uuid =
      r'[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}';
  static final _id = RegExp('^$_uuid\$');
  static final _prefix = RegExp(
    '^\\[Open Remote Code voice note v(1|2): ($_uuid)(; durationMs=([1-9][0-9]{0,4}))?\\]\\n',
  );
  static VoiceNote? parse(String text) {
    if (text.length > 32000) return null;
    final match = _prefix.firstMatch(text);
    if (match == null) return null;
    final legacy = match.group(1) == '1';
    final ms = int.tryParse(match.group(4) ?? '');
    if (legacy ? ms != null : ms == null || ms > 60000) return null;
    final transcript = text.substring(match.end);
    if (transcript.trim().isEmpty) return null;
    return VoiceNote._(
      match.group(2)!,
      transcript,
      legacy ? null : Duration(milliseconds: ms!),
    );
  }
}
