import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'core/address.dart';
import 'core/app_language.dart';

class ScanTransferPage extends StatefulWidget {
  const ScanTransferPage({super.key});

  @override
  State<ScanTransferPage> createState() => _ScanTransferPageState();
}

class _ScanTransferPageState extends State<ScanTransferPage> {
  bool completed = false;
  String? message;

  void detect(BarcodeCapture capture) {
    if (completed || !mounted) return;
    final addresses = <String>{};
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode || barcode.rawValue == null) {
        continue;
      }
      try {
        addresses.add(normalizeAddress(barcode.rawValue!));
      } on FormatException {
        // Never display untrusted QR contents (which may contain secrets).
      }
    }
    if (addresses.length == 1) {
      completed = true;
      Navigator.of(context).pop(addresses.single);
      return;
    }
    final next = addresses.length > 1
        ? tr('检测到多个收款钱包，请只对准一个二维码')
        : tr('无效的收款二维码，请扫描 Dragonchain 主网钱包');
    if (next != message) setState(() => message = next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('扫码转账'))),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: MobileScanner(
                  onDetect: detect,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        error.errorCode ==
                                MobileScannerErrorCode.permissionDenied
                            ? tr('相机权限未开启，请在系统设置中允许相机权限后重新扫码，也可返回手动填写钱包')
                            : tr('无法使用相机，请返回重试或手动填写收款钱包'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tr('请对准收款二维码，识别后返回转账页面'), textAlign: TextAlign.center),
                    if (message != null) ...[
                      const SizedBox(height: 8),
                      Text(message!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(tr('返回手动填写')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
