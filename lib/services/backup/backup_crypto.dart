import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/errors.dart';
import 'backup_format.dart';

/// Argon2id + AES-256-GCM, as plain top-level functions so they can be handed
/// to `compute` and run off the UI thread (SPEC.md §3).

class EncryptRequest {
  const EncryptRequest({required this.passphrase, required this.plaintext});

  final String passphrase;
  final Uint8List plaintext;
}

class DecryptRequest {
  const DecryptRequest({required this.passphrase, required this.fileBytes});

  final String passphrase;
  final Uint8List fileBytes;
}

Future<SecretKey> _deriveKey(String passphrase, BackupHeader header) {
  return Argon2id(
    parallelism: header.parallelism,
    memory: header.memoryKb,
    iterations: header.iterations,
    hashLength: 32,
  ).deriveKeyFromPassword(password: passphrase, nonce: header.salt);
}

/// Produces a complete `.yapbackup` payload: plaintext header, ciphertext, MAC.
Future<Uint8List> encryptBackup(EncryptRequest request) async {
  final algorithm = AesGcm.with256bits();
  final random = SecretKeyData.random(length: 28).bytes;
  final header = BackupHeader(
    salt: random.sublist(0, 16),
    nonce: random.sublist(16, 28),
  );

  final key = await _deriveKey(request.passphrase, header);
  final box = await algorithm.encrypt(
    request.plaintext,
    secretKey: key,
    nonce: header.nonce,
  );

  final out = BytesBuilder()
    ..add(header.encode())
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return out.toBytes();
}

/// Reverses [encryptBackup].
///
/// A wrong passphrase surfaces as a MAC failure, which is also what a tampered
/// or truncated file looks like — the message says so rather than claiming the
/// file is corrupt.
Future<Uint8List> decryptBackup(DecryptRequest request) async {
  final decoded = BackupHeader.decode(request.fileBytes);
  final header = decoded.header;

  const macLength = 16;
  final body = request.fileBytes.sublist(decoded.offset);
  if (body.length < macLength) {
    throw const ValidationException('This backup file is truncated.');
  }

  final cipherText = body.sublist(0, body.length - macLength);
  final mac = Mac(body.sublist(body.length - macLength));

  final key = await _deriveKey(request.passphrase, header);
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: header.nonce, mac: mac),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const ValidationException(
      'Wrong passphrase, or this file has been altered since it was made.',
    );
  }
}
