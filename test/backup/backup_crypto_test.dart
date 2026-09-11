import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/services/backup/backup_crypto.dart';
import 'package:yapapp/services/backup/backup_format.dart';

void main() {
  // Argon2id at the shipping parameters takes a moment even on a laptop.
  const slow = Timeout(Duration(minutes: 3));

  Uint8List payload(String text) => Uint8List.fromList(utf8.encode(text));

  group('round trip', () {
    test('decrypts back to exactly the same bytes', () async {
      final clear = payload('mera ek idea hai — time loop movie');
      final sealed = await encryptBackup(
        EncryptRequest(passphrase: 'correct horse battery', plaintext: clear),
      );

      final back = await decryptBackup(
        DecryptRequest(passphrase: 'correct horse battery', fileBytes: sealed),
      );

      expect(back, clear);
    }, timeout: slow);

    test('survives binary content, not just text', () async {
      final clear = Uint8List.fromList(
        List.generate(4096, (i) => (i * 31) % 256),
      );
      final sealed = await encryptBackup(
        EncryptRequest(passphrase: 'passphrase one', plaintext: clear),
      );
      final back = await decryptBackup(
        DecryptRequest(passphrase: 'passphrase one', fileBytes: sealed),
      );
      expect(back, clear);
    }, timeout: slow);

    test('the same input twice produces different files', () async {
      final clear = payload('same content');
      final a = await encryptBackup(
        EncryptRequest(passphrase: 'pass', plaintext: clear),
      );
      final b = await encryptBackup(
        EncryptRequest(passphrase: 'pass', plaintext: clear),
      );

      expect(a, isNot(b),
          reason: 'a fresh salt and nonce each time must change the output');
    }, timeout: slow);

    test('the plaintext never appears in the file', () async {
      final secret = 'Ritu Sharma does video editing';
      final sealed = await encryptBackup(
        EncryptRequest(passphrase: 'pass', plaintext: payload(secret)),
      );
      expect(utf8.decode(sealed, allowMalformed: true), isNot(contains(secret)));
    }, timeout: slow);
  });

  group('rejects', () {
    late Uint8List sealed;

    setUpAll(() async {
      sealed = await encryptBackup(
        EncryptRequest(passphrase: 'the right one', plaintext: payload('data')),
      );
    });

    test('the wrong passphrase', () async {
      await expectLater(
        decryptBackup(
          DecryptRequest(passphrase: 'the wrong one', fileBytes: sealed),
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('Wrong passphrase'))),
      );
    }, timeout: slow);

    test('a passphrase differing by one character', () async {
      await expectLater(
        decryptBackup(
          DecryptRequest(passphrase: 'the right On', fileBytes: sealed),
        ),
        throwsA(isA<ValidationException>()),
      );
    }, timeout: slow);

    test('an empty passphrase', () async {
      await expectLater(
        decryptBackup(DecryptRequest(passphrase: '', fileBytes: sealed)),
        throwsA(isA<ValidationException>()),
      );
    }, timeout: slow);

    test('a file whose ciphertext was altered', () async {
      final tampered = Uint8List.fromList(sealed);
      // Flip a bit well past the header.
      tampered[tampered.length - 20] ^= 0x01;

      await expectLater(
        decryptBackup(
          DecryptRequest(passphrase: 'the right one', fileBytes: tampered),
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('altered'))),
      );
    }, timeout: slow);

    test('a truncated file', () async {
      final cut = Uint8List.fromList(sealed.sublist(0, sealed.length - 8));
      await expectLater(
        decryptBackup(
          DecryptRequest(passphrase: 'the right one', fileBytes: cut),
        ),
        throwsA(isA<ValidationException>()),
      );
    }, timeout: slow);

    test('a file that is not a backup at all', () async {
      await expectLater(
        decryptBackup(DecryptRequest(
          passphrase: 'x',
          fileBytes: payload('just some random file contents'),
        )),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('not a Yap backup'))),
      );
    });

    test('an empty file', () async {
      await expectLater(
        decryptBackup(
          DecryptRequest(passphrase: 'x', fileBytes: Uint8List(0)),
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('header', () {
    test('round-trips its parameters', () {
      final header = BackupHeader(
        salt: List.generate(16, (i) => i),
        nonce: List.generate(12, (i) => i * 2),
      );
      final decoded = BackupHeader.decode(
        Uint8List.fromList([...header.encode(), 1, 2, 3]),
      );

      expect(decoded.header.salt, header.salt);
      expect(decoded.header.nonce, header.nonce);
      expect(decoded.header.memoryKb, BackupHeader.defaultMemoryKb);
      expect(decoded.header.iterations, BackupHeader.defaultIterations);
      expect(decoded.offset, header.encode().length);
    });

    test('is readable plaintext, so a future version can diagnose a file', () {
      final header = BackupHeader(salt: const [1], nonce: const [2]);
      final text = utf8.decode(header.encode(), allowMalformed: true);
      expect(text, startsWith('YAPBACKUP1'));
      expect(text, contains('argon2id'));
      expect(text, contains('aes-256-gcm'));
    });

    test('refuses a newer format version', () {
      final header = BackupHeader(
        salt: const [1],
        nonce: const [2],
        formatVersion: 99,
      );
      expect(
        () => BackupHeader.decode(header.encode()),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('newer version'))),
      );
    });

    test('refuses an unknown cipher', () {
      final header = BackupHeader(
        salt: const [1],
        nonce: const [2],
        cipher: 'rot13',
      );
      expect(
        () => BackupHeader.decode(header.encode()),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
