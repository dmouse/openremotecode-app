/// A repository must verify the transcript and derive this code locally.
final class PairingReview {
  const PairingReview({
    required this.pairingId,
    required this.safetyCode,
    required this.expiresAt,
  });

  final String pairingId;
  final String safetyCode;
  final DateTime expiresAt;
}
