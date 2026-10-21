import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'translations.dart';

class AppLanguage extends ChangeNotifier {
  AppLanguage(
      {Future<String?> Function()? read, Future<void> Function(String)? write})
      : _read = read ??
            (() => SharedPreferencesAsync().getString('dragon.language.v1')),
        _write = write ??
            ((value) => SharedPreferencesAsync()
                .setString('dragon.language.v1', value));
  static AppLanguage instance = AppLanguage();
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  String code = 'en';
  Future<void> initialize() async {
    try {
      apply(await _read() ?? 'en');
    } catch (_) {
      apply('en');
    }
    await _syncNative();
  }

  void apply(String value) {
    code = value == 'zh' ? 'zh' : 'en';
    notifyListeners();
  }

  Future<void> select(String value) async {
    await _write(value);
    apply(value);
    await _syncNative();
  }

  Future<void> _syncNative() async {
    try {
      await const MethodChannel('dragon.wallet/keys')
          .invokeMethod('setLanguage', {'language': code});
    } on MissingPluginException {
      /* Desktop and tests have no native vault. */
    } on PlatformException {
      /* Language remains available without native keys. */
    }
  }
}

String tr(String text, [List<Object?> arguments = const []]) {
  // Native errors may still use the previous address terminology.
  final walletKey = text.replaceAll('地址', '钱包');
  final key = !englishMessages.containsKey(text) &&
          englishMessages.containsKey(walletKey)
      ? walletKey
      : text;
  final template =
      AppLanguage.instance.code == 'en' ? englishMessages[key] ?? text : key;
  return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
    final index = int.parse(match[1]!);
    return index < arguments.length ? '${arguments[index]}' : match[0]!;
  });
}
