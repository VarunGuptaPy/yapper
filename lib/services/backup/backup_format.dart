import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';

/// The plaintext header on a `.yapbackup` file.
///
/// Everything needed to derive the key again lives here — salt, nonce and the
/// exact KDF parameters. Hard-coding those in the app would make every backup
/// unreadable the day the parameters are tuned, so they travel with the file.
class BackupHeader {
  const BackupHeader({
    required this.salt,
    required this.nonce,
    this.formatVersion = currentFormatVersion,
    this.kdf = 'argon2id',
    this.memoryKb = defaultMemoryKb,
    this.iterations = defaultIterations,
    this.parallelism = defaultParallelism,
    this.cipher = 'aes-256-gcm',
  });

  /// Bumped only for a breaking change to the envelope itself.
  static const currentFormatVersion = 1;

  static const magic = 'YAPBACKUP1\n';

  /// Argon2id at 64 MiB / 3 passes. Measured at roughly half a second on a
  /// laptop, so a couple of seconds on a mid-range phone — fine for an
  /// operation you run occasionally, and expensive enough to make guessing a
  /// passphrase against a stolen file painful.
  static const defaultMemoryKb = 65536;
  static const defaultIterations = 3;
  static const defaultParallelism = 1;

  final int formatVersion;
  final String kdf;
  final int memoryKb;
  final int iterations;
  final int parallelism;
  final String cipher;
  final List<int> salt;
  final List<int> nonce;

  Map<String, dynamic> toJson() => {
        'v': formatVersion,
        'kdf': kdf,
        'm': memoryKb,
        't': iterations,
        'p': parallelism,
        'cipher': cipher,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
      };

  /// magic + uint16 length + JSON.
  Uint8List encode() {
    final json = utf8.encode(jsonEncode(toJson()));
    final magicBytes = utf8.encode(magic);
    final out = BytesBuilder()
      ..add(magicBytes)
      ..add([(json.length >> 8) & 0xFF, json.length & 0xFF])
      ..add(json);
    return out.toBytes();
  }

  /// Reads the header and reports where the ciphertext starts.
  static ({BackupHeader header, int offset}) decode(Uint8List bytes) {
    final magicBytes = utf8.encode(magic);
    if (bytes.length < magicBytes.length + 2) {
      throw const ValidationException('That file is too small to be a backup.');
    }
    for (var i = 0; i < magicBytes.length; i++) {
      if (bytes[i] != magicBytes[i]) {
        throw const ValidationException(
          'That is not a Yap backup file.',
        );
      }
    }

    final lengthOffset = magicBytes.length;
    final jsonLength = (bytes[lengthOffset] << 8) | bytes[lengthOffset + 1];
    final jsonStart = lengthOffset + 2;
    final jsonEnd = jsonStart + jsonLength;
    if (jsonEnd > bytes.length) {
      throw const ValidationException('This backup file is truncated.');
    }

    final Map<String, dynamic> map;
    try {
      map = jsonDecode(utf8.decode(bytes.sublist(jsonStart, jsonEnd)))
          as Map<String, dynamic>;
    } catch (_) {
      throw const ValidationException('This backup file has a damaged header.');
    }

    final version = map['v'];
    if (version is! int || version > currentFormatVersion) {
      throw ValidationException(
        'This backup was written by a newer version of Yap (format $version). '
        'Update the app first.',
      );
    }
    if (map['kdf'] != 'argon2id' || map['cipher'] != 'aes-256-gcm') {
      throw const ValidationException(
        'This backup uses an encryption scheme this version cannot read.',
      );
    }

    return (
      header: BackupHeader(
        formatVersion: version,
        kdf: map['kdf'] as String,
        memoryKb: map['m'] as int,
        iterations: map['t'] as int,
        parallelism: map['p'] as int,
        cipher: map['cipher'] as String,
        salt: base64Decode(map['salt'] as String),
        nonce: base64Decode(map['nonce'] as String),
      ),
      offset: jsonEnd,
    );
  }
}

/// The `manifest.json` inside the encrypted archive.
class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.createdAt,
    required this.noteCount,
    required this.captureCount,
    required this.embeddingsIncluded,
  });

  static const dbEntryName = 'yap.sqlite';
  static const manifestEntryName = 'manifest.json';

  final int schemaVersion;
  final DateTime createdAt;
  final int noteCount;
  final int captureCount;

  /// Embeddings are derived data and dominate the file size, so they are
  /// normally left out and rebuilt after a restore.
  final bool embeddingsIncluded;

  Map<String, dynamic> toJson() => {
        'app': 'yap',
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'noteCount': noteCount,
        'captureCount': captureCount,
        'embeddingsIncluded': embeddingsIncluded,
      };

  static BackupManifest fromJson(Map<String, dynamic> map) => BackupManifest(
        schemaVersion: map['schemaVersion'] as int? ?? 1,
        createdAt:
            DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime(2000),
        noteCount: map['noteCount'] as int? ?? 0,
        captureCount: map['captureCount'] as int? ?? 0,
        embeddingsIncluded: map['embeddingsIncluded'] as bool? ?? false,
      );
}
