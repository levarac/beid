import 'dart:convert';
import 'package:crypto/crypto.dart';

/// ウォレットアドレスからBLE用のユニークUUIDを生成するユーティリティ
class BleUuidGenerator {
  BleUuidGenerator._();

  /// プレフィックス
  static const String prefix = 'beid';

  /// ウォレットアドレスからBLE用サービスUUIDを生成する
  ///
  /// ウォレットアドレスをSHA256でハッシュし、16バイトのUUID形式に変換する。
  /// これにより、アドレスを直接公開せずに一意の識別子として使用できる。
  static String generateFromWalletAddress(String walletAddress) {
    // アドレスを小文字に正規化
    final normalizedAddress = walletAddress.toLowerCase();

    // SHA256ハッシュを計算
    final bytes = utf8.encode(normalizedAddress);
    final digest = sha256.convert(bytes);

    // 最初の16バイトを取得してUUID形式に変換
    final hashBytes = digest.bytes.sublist(0, 16);

    // UUID v4形式に準拠（バージョンとバリアントビットを設定）
    hashBytes[6] = (hashBytes[6] & 0x0f) | 0x40; // version 4
    hashBytes[8] = (hashBytes[8] & 0x3f) | 0x80; // variant 1

    // UUID形式の文字列に変換
    final hex = hashBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return '$prefix-${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// UUIDがBeid形式かどうかを判定する
  static bool isBeidUuid(String uuid) {
    return uuid.startsWith('$prefix-');
  }
}
