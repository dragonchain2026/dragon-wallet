import 'app_language.dart';
import 'package:crypto/crypto.dart';

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

/// Validates checksums and the network before any address is stored or queried.
String normalizeAddress(String input) {
  final address = input.trim();
  if (address.length < 14 || address.length > 90) {
    throw FormatException(tr("请输入有效的 Dragonchain 主网钱包"));
  }
  if (address.toLowerCase().startsWith('dragon1')) {
    if (address != address.toLowerCase() && address != address.toUpperCase()) {
      throw FormatException(tr("钱包不能混用大小写"));
    }
    final normalized = address.toLowerCase();
    final split = normalized.lastIndexOf('1');
    final hrp = normalized.substring(0, split);
    final values = normalized
        .substring(split + 1)
        .split('')
        .map(_charset.indexOf)
        .toList();
    final expanded = [
      ...hrp.codeUnits.map((c) => c >> 5),
      0,
      ...hrp.codeUnits.map((c) => c & 31),
    ];
    if (hrp != 'dragon' ||
        values.length < 7 ||
        values.contains(-1) ||
        _polymod([...expanded, ...values]) != 1 ||
        values.first != 0) {
      throw FormatException(tr("钱包校验失败，仅支持主网 witness v0 钱包"));
    }
    var bits = 0;
    var accumulator = 0;
    final program = <int>[];
    for (final value in values.sublist(1, values.length - 6)) {
      accumulator = ((accumulator << 5) | value) & 0xfff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        program.add((accumulator >> bits) & 255);
      }
    }
    if (bits >= 5 ||
        ((accumulator << (8 - bits)) & 255) != 0 ||
        (program.length != 20 && program.length != 32)) {
      throw FormatException(tr("无效的 witness 钱包长度"));
    }
    return normalized;
  }
  var number = BigInt.zero;
  for (final char in address.split('')) {
    final digit = _alphabet.indexOf(char);
    if (digit < 0) {
      throw FormatException(tr("无效的钱包字符"));
    }
    number = number * BigInt.from(58) + BigInt.from(digit);
  }
  final bytes = <int>[];
  while (number > BigInt.zero) {
    bytes.insert(0, (number & BigInt.from(255)).toInt());
    number >>= 8;
  }
  for (final char in address.split('')) {
    if (char != '1') {
      break;
    }
    bytes.insert(0, 0);
  }
  if (bytes.length != 25 || (bytes.first != 63 && bytes.first != 125)) {
    throw FormatException(tr("仅支持 Dragonchain 主网钱包"));
  }
  final checksum =
      sha256.convert(sha256.convert(bytes.sublist(0, 21)).bytes).bytes;
  for (var i = 0; i < 4; i++) {
    if (bytes[21 + i] != checksum[i]) {
      throw FormatException(tr("钱包校验和错误"));
    }
  }
  return address;
}

int _polymod(List<int> values) {
  var checksum = 1;
  const generators = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];
  for (final value in values) {
    final top = checksum >> 25;
    checksum = ((checksum & 0x1ffffff) << 5) ^ value;
    for (var i = 0; i < 5; i++) {
      if (((top >> i) & 1) != 0) {
        checksum ^= generators[i];
      }
    }
  }
  return checksum;
}

String formatAmount(BigInt atomic, {bool signed = false}) {
  final magnitude = atomic.abs().toString().padLeft(9, '0');
  final whole = magnitude.substring(0, magnitude.length - 8);
  final fraction = magnitude
      .substring(magnitude.length - 8)
      .replaceFirst(RegExp(r'0+$'), '');
  final sign = atomic.isNegative
      ? '-'
      : signed && atomic > BigInt.zero
          ? '+'
          : '';
  return '$sign$whole${fraction.isEmpty ? '' : '.$fraction'}';
}
