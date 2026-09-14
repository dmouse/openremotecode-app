import '../auth/auth_repository.dart';

/// Form rules and the verification commands for a pending account.
final class VerifyEmailViewModel {
  VerifyEmailViewModel({required this.auth});
  final AuthRepository auth;

  bool get isBusy => auth.isBusy;
  String? get error => auth.error;
  String? get email => auth.pendingVerification?.email;

  /// Mirrors the server's thirty-second cooldown. This is a courtesy only — the
  /// server stays authoritative and rejects an early resend regardless.
  static const resendCooldown = Duration(seconds: 30);

  Future<bool> submit(String code) => auth.submitVerificationCode(code);
  Future<bool> resend() => auth.resendVerificationCode();

  String? validateCode(String? input) {
    final code = input?.trim() ?? '';
    if (code.isEmpty) return 'Enter the six-digit code.';
    if (code.length != 6 || !RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      return 'The code is six digits.';
    }
    return null;
  }
}
