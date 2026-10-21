import 'package:flutter_test/flutter_test.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'wallet_test.dart' show MemoryStore, address;

const second = 'dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh';
const third = 'sKoe1eYdfZcypGyJTjizagWTakpi5fScmU';

class FailingStore extends MemoryStore {
  bool fail = true;
  @override
  Future<void> write(String input) async {
    if (fail) throw StateError('write failed');
    await super.write(input);
  }
}

void main() {
  test(
      'names number sequentially, survive restart and preserve renamed imports',
      () async {
    final storage = MemoryStore();
    WalletController create() => WalletController(
        api: WalletApi(), store: MemoryStore(), namesStore: storage);
    final wallet = create();
    await Future.wait([
      wallet.ensureNames([address]),
      wallet.ensureNames([second])
    ]);
    expect(wallet.nameFor(address), '钱包1');
    expect(wallet.nameFor(second), '钱包2');
    await wallet.renameAddress(address, '  节点地址  ');
    await wallet.ensureNames([address]);
    expect(wallet.nameFor(address), '节点地址');
    await wallet.forget();
    wallet.dispose();
    final restored = create();
    await restored.loadNames();
    expect(restored.nameFor(address), '节点地址');
    expect(restored.suggestedName, '钱包3');
    await restored.ensureNames([third]);
    expect(restored.nameFor(third), '钱包3');
    restored.dispose();
  });
  test('failed persistence does not consume default number', () async {
    final storage = FailingStore();
    final wallet = WalletController(
        api: WalletApi(), store: MemoryStore(), namesStore: storage);
    await expectLater(wallet.ensureNames([address]), throwsStateError);
    expect(wallet.suggestedName, '钱包1');
    storage.fail = false;
    await wallet.ensureNames([address]);
    expect(wallet.nameFor(address), '钱包1');
    for (final invalid in ['', '   ', 'a' * 33, 'a\nb']) {
      expect(
          () => wallet.renameAddress(address, invalid), throwsFormatException);
    }
    wallet.dispose();
  });
}
