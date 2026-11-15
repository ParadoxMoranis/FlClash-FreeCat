enum FreecatFailure {
  invalidHost,
  credentials,
  expired,
  network,
  http,
  invalidResponse,
  decryption,
  decoy,
  invalidProfile,
  storage,
}

final class FreecatException implements Exception {
  final FreecatFailure failure;
  final int? statusCode;

  const FreecatException(this.failure, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'FreecatException(${failure.name})'
      : 'FreecatException(${failure.name}, $statusCode)';
}
