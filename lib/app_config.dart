import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  /// A saved selection wins over this default. Shipped builds have no local host.
  static const defaultServer = String.fromEnvironment(
    'REMOTE_SERVER_URL',
    defaultValue: kDebugMode ? 'http://127.0.0.1:8080' : '',
  );

  /// The Google OAuth **web** client ID. Both mobile platforms request an ID token
  /// addressed to it, and the server verifies that same value as the audience, so
  /// this must match one entry in the server's `GOOGLE_OAUTH_AUDIENCES`. It is a
  /// public identifier, not a secret; the client secret belongs to neither side.
  ///
  /// Empty in a build that has not configured it, which hides the Google action
  /// rather than offering a button that cannot work.
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  /// The iOS OAuth client ID. iOS needs its own, and the plugin reads it from
  /// Info.plist when this is empty. Android needs no client ID here: it resolves
  /// its own from the signing certificate registered with Google.
  static const googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );

  /// Google sign-in is offered only where the build can actually complete it.
  static bool get googleSignInConfigured => googleServerClientId.isNotEmpty;
}
