import 'dart:async';
import 'package:dragon_wallet/core/app_language.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppLanguage.instance.apply('zh');
  await testMain();
}
