import 'dart:convert';

abstract final class ConnectionName {
  static String parse(String input) {
    final name = input.trim();
    if (name.isEmpty) throw const FormatException('Enter a name.');
    if (utf8.encode(name).length > 64) {
      throw const FormatException('Name is too long. Use a shorter name.');
    }
    return name;
  }
}
