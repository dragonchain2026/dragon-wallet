/// Boundary for a future audited Dragonchain native wallet implementation.
/// This interface intentionally provides no fake signing or key generation.
abstract interface class WalletCore {
  Future<String> publicKeyToAddress(List<int> publicKey);
  Future<List<int>> signTransaction(List<int> unsignedTransaction);
}

class WalletCoreUnavailable implements WalletCore {
  const WalletCoreUnavailable();

  @override
  Future<String> publicKeyToAddress(List<int> publicKey) => Future.error(
      UnsupportedError('Native Falcon-512 compatibility not verified'));

  @override
  Future<List<int>> signTransaction(List<int> unsignedTransaction) =>
      Future.error(UnsupportedError(
          'Transaction signing disabled until node verification'));
}
