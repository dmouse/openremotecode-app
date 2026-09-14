/// The server's Crockford alphabet excludes I, L, O, and U.
final class PairingCode {
  const PairingCode._(this.value);

  final String value;

  static PairingCode parse(String input) {
    final compact = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!RegExp(r'^[0-9A-HJ-KM-NP-TV-Z]{8}$').hasMatch(compact)) {
      throw const FormatException(
        'Enter the 8-character code shown in OpenCode.',
      );
    }
    return PairingCode._('${compact.substring(0, 4)}-${compact.substring(4)}');
  }
}
