import 'dart:typed_data';

/// The marker is presentation metadata inside the existing encrypted text prompt.
/// It grants no trust, resource access or native playback capability.
final class VoiceNote {
  VoiceNote({
    required this.id,
    required Uint8List audio,
    required this.transcript,
  }) : audio = Uint8List.fromList(audio).asUnmodifiableView() {
    final parsed = parse(prompt);
    if (audio.isEmpty ||
        audio.length.isOdd ||
        audio.length > 1920000 ||
        parsed?.id != id ||
        parsed?.transcript != transcript) {
      throw const FormatException('Invalid voice note');
    }
  }
  final String id, transcript;
  final Uint8List audio;
  Duration get duration => Duration(milliseconds: audio.length ~/ 32);
  static String formatPrompt(String id, String transcript) =>
      '[Open Remote Code voice note v1: $id]\n$transcript';
  String get prompt => formatPrompt(id, transcript);
  static final _prefix = RegExp(
    r'^\[Open Remote Code voice note v1: ([a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})\]\n',
  );
  static ({String id, String transcript})? parse(String text) {
    final match = _prefix.firstMatch(text);
    if (match == null ||
        text.length > 32000 ||
        text.substring(match.end).trim().isEmpty) {
      return null;
    }
    return (id: match.group(1)!, transcript: text.substring(match.end));
  }
}

/// Workspace-lifetime audio only. No disk cache, server history or offline sync.
final class VoiceNoteMemory {
  final _notes = <(String, String, String, String), VoiceNote>{};
  void add(String connector, String project, String session, VoiceNote note) {
    _notes[(connector, project, session, note.id)] = note;
    while (_notes.length > 8) {
      _notes.remove(_notes.keys.first);
    }
  }

  VoiceNote? find(
    String connector,
    String project,
    String session,
    String id,
  ) => _notes[(connector, project, session, id)];
  void clear({String? connector}) => connector == null
      ? _notes.clear()
      : _notes.removeWhere((key, _) => key.$1 == connector);
  void retainConnectors(Set<String> ids) =>
      _notes.removeWhere((key, _) => !ids.contains(key.$1));
}
