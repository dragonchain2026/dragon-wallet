import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'address.dart';

class VaultKey {
  VaultKey(Map<Object?, Object?> value)
      : id = value['id'] as String,
        hasMnemonic = value['has_mnemonic'] == 'true',
        mnemonicBackup = value['backup_type'] == 'mnemonic' ||
            (value['backup_type'] == null && value['has_mnemonic'] == 'true'),
        address = normalizeAddress(value['address'] as String),
        legacyAddress = value['legacy_address'] == null
            ? null
            : normalizeAddress(value['legacy_address'] as String);
  final String id;
  final bool hasMnemonic;
  final bool mnemonicBackup;
  final String address;
  final String? legacyAddress;
  bool owns(String? candidate) => candidate != null && candidate == address;
}

class KeyVault {
  static const channel = MethodChannel('dragon.wallet/keys');
  Future<void> lockSettings() => channel.invokeMethod('lockSettings');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<void> secure(bool enabled) =>
      channel.invokeMethod('secure', {'enabled': enabled});
  Future<List<VaultKey>> list() async {
    final values =
        await channel.invokeListMethod<Map<Object?, Object?>>('list');
    return (values ?? []).map(VaultKey.new).toList();
  }

  Future<VaultKey> generate() async =>
      VaultKey((await channel.invokeMapMethod<Object?, Object?>('generate'))!);
  Future<VaultKey> generateMnemonic() async => VaultKey(
      (await channel.invokeMapMethod<Object?, Object?>('generateMnemonic'))!);
  Future<VaultKey> importWif(String text) async => VaultKey((await channel
      .invokeMapMethod<Object?, Object?>('import', {'wif': text}))!);
  Future<VaultKey> importMnemonic(String text) async =>
      VaultKey((await channel.invokeMapMethod<Object?, Object?>(
          'importMnemonic', {'mnemonic': text}))!);
  Future<String> viewSecret(VaultKey key) async =>
      (await channel.invokeMethod<String>(
          key.mnemonicBackup ? 'viewMnemonic' : 'viewWif', {'id': key.id}))!;
  Future<void> copySecret(String text) =>
      channel.invokeMethod('copySecret', {'text': text});
  Future<void> delete(VaultKey key) =>
      channel.invokeMethod('delete', {'id': key.id});
}
