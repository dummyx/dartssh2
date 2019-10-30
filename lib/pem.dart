// Copyright 2019 dartssh developers
// Use of this source code is governed by a MIT-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/api.dart' hide Signature;
import 'package:pointycastle/asymmetric/api.dart' as asymmetric;
import 'package:tweetnacl/tweetnacl.dart' as tweetnacl;

import 'package:dartssh/client.dart';
import 'package:dartssh/protocol.dart';
import 'package:dartssh/serializable.dart';
import 'package:dartssh/ssh.dart';

Identity parsePem(String text, {StringFunction getPassword}) {
  const String beginText = '-----BEGIN ',
      endText = '-----END ',
      termText = '-----';
  int beginBegin, beginEnd, endBegin, endEnd;
  if ((beginBegin = text.indexOf(beginText)) == -1) {
    throw FormatException('missing $beginText');
  }
  if ((beginEnd = text.indexOf(termText, beginBegin + beginText.length)) ==
      -1) {
    throw FormatException('missing $termText');
  }
  if ((endBegin = text.indexOf(endText, beginEnd + termText.length)) == -1) {
    throw FormatException('missing $endText');
  }
  if ((endEnd = text.indexOf(termText, endBegin + endText.length)) == -1) {
    throw FormatException('missing $termText');
  }

  String type = text.substring(beginBegin + beginText.length, beginEnd);
  if (type != text.substring(endBegin + endText.length, endEnd)) {
    throw FormatException('type disagreement: $type');
  }

  int start = beginEnd + termText.length, end = endBegin;
  if (start < text.length && text[start] == '\r') start++;
  if (start < text.length && text[start] == '\n') start++;

  int headersEnd = text.indexOf('\n\n', start);
  if (headersEnd == -1 || headersEnd >= end) {
    headersEnd = text.indexOf('\r\n\r\n', start);
  }
  if (headersEnd != -1 && headersEnd < end) {
    throw FormatException('headers not supported');
  }

  String base64text = '';
  for (String line in LineSplitter().convert(text.substring(start, end))) {
    base64text += line.trim();
  }
  Uint8List payload = base64.decode(base64text);

  switch (type) {
    case 'OPENSSH PRIVATE KEY':
      OpenSSHKey openssh = OpenSSHKey()
        ..deserialize(SerializableInput(payload));
      Uint8List privateKey;
      switch (openssh.kdfname) {
        case 'bcrypt':
          OpenSSHBCryptKDFOptions kdfoptions = OpenSSHBCryptKDFOptions()
            ..deserialize(SerializableInput(openssh.kdfoptions));
          int cipherAlgo;
          if (openssh.ciphername == 'aes256-cbc') {
            cipherAlgo = Cipher.AES256_CBC;
          } else {
            throw FormatException('cipher ${openssh.ciphername}');
          }
          privateKey = opensshKeyCrypt(
              false,
              (getPassword != null ? getPassword() : '').codeUnits,
              kdfoptions.salt,
              kdfoptions.rounds,
              openssh.privatekey,
              cipherAlgo);
          break;

        case 'none':
          privateKey = openssh.privatekey;
          break;

        default:
          throw FormatException('kdf ${openssh.kdfname}');
      }
      SerializableInput input = SerializableInput(privateKey);
      OpenSSHPrivateKeyHeader().deserialize(input);
      OpenSSHEd25519PrivateKey ed25519 = OpenSSHEd25519PrivateKey()
        ..deserialize(input);
      Identity ret = Identity()
        ..ed25519 = tweetnacl.Signature.keyPair_fromSecretKey(ed25519.privkey);
      assert(equalUint8List(ret.ed25519.publicKey, ed25519.pubkey));
      return ret;

    case 'RSA PRIVATE KEY':
      RSAPrivateKey rsaPrivateKey = RSAPrivateKey()
        ..deserialize(SerializableInput(payload));
      return Identity()
        ..rsa = asymmetric.RSAPrivateKey(
            rsaPrivateKey.n, rsaPrivateKey.e, rsaPrivateKey.p, rsaPrivateKey.q);

    default:
      throw FormatException('type not supported: $type');
  }
}

/// https://tools.ietf.org/html/rfc3447#appendix-A.1.2
class RSAPrivateKey extends Serializable {
  BigInt version, n, e, d, p, q, exponent1, exponent2, coefficient;

  @override
  int get serializedSize => null;

  /// https://gist.github.com/proteye/982d9991922276ccfb011dfc55443d74
  @override
  void deserialize(SerializableInput input) {
    ASN1Parser asn1Parser = ASN1Parser(input.viewRemaining());
    ASN1Sequence pkSeq = asn1Parser.nextObject();
    version = (pkSeq.elements[0] as ASN1Integer).valueAsBigInteger;
    n = (pkSeq.elements[1] as ASN1Integer).valueAsBigInteger;
    e = (pkSeq.elements[2] as ASN1Integer).valueAsBigInteger;
    d = (pkSeq.elements[3] as ASN1Integer).valueAsBigInteger;
    p = (pkSeq.elements[4] as ASN1Integer).valueAsBigInteger;
    q = (pkSeq.elements[5] as ASN1Integer).valueAsBigInteger;
    exponent1 = (pkSeq.elements[6] as ASN1Integer).valueAsBigInteger;
    exponent2 = (pkSeq.elements[7] as ASN1Integer).valueAsBigInteger;
    coefficient = (pkSeq.elements[8] as ASN1Integer).valueAsBigInteger;
  }

  @override
  void serialize(SerializableOutput output) {}
}

class OpenSSHKey extends Serializable {
  String magic = 'openssh-key-v1', ciphername, kdfname;
  Uint8List kdfoptions, privatekey;
  List<Uint8List> publickeys;
  OpenSSHKey([this.ciphername, this.kdfname, this.kdfoptions, this.privatekey]);

  @override
  int get serializedHeaderSize => 5 * 4 + 15;

  @override
  int get serializedSize =>
      serializedHeaderSize +
      ciphername.length +
      kdfname.length +
      kdfoptions.length +
      privatekey.length +
      publickeys.fold(0, (v, e) => v += e.length);

  @override
  void deserialize(SerializableInput input) {
    Uint8List nullTerminatedMagic = input.getBytes(15);
    magic = String.fromCharCodes(nullTerminatedMagic, 0, 14);
    if (magic != 'openssh-key-v1') throw FormatException('wrong magic: $magic');

    ciphername = deserializeString(input);
    kdfname = deserializeString(input);
    kdfoptions = deserializeStringBytes(input);
    publickeys = List<Uint8List>(input.getUint32());
    for (int i = 0; i < publickeys.length; i++) {
      publickeys[i] = deserializeStringBytes(input);
    }
    privatekey = deserializeStringBytes(input);
  }

  @override
  void serialize(SerializableOutput output) {
    output.addBytes(magic.codeUnits);
    output.addUint8(0);

    serializeString(output, ciphername);
    serializeString(output, kdfname);
    serializeString(output, kdfoptions);
    output.addUint32(publickeys.length);
    for (Uint8List publickey in publickeys) {
      serializeString(output, publickey);
    }
    serializeString(output, privatekey);
  }
}

class OpenSSHPrivateKeyHeader extends Serializable {
  int checkint1 = 0, checkint2 = 0;
  OpenSSHPrivateKeyHeader();

  @override
  int get serializedHeaderSize => 2 * 4;

  @override
  int get serializedSize => serializedHeaderSize;

  @override
  void deserialize(SerializableInput input) {
    checkint1 = input.getUint32();
    checkint2 = input.getUint32();
    if (checkint1 != checkint2) {
      throw FormatException('$checkint1 != $checkint2');
    }
  }

  @override
  void serialize(SerializableOutput output) {
    output.addUint32(checkint1);
    output.addUint32(checkint2);
  }
}

class OpenSSHEd25519PrivateKey extends Serializable {
  String keytype = 'ssh-ed25519', comment;
  Uint8List pubkey, privkey;
  OpenSSHEd25519PrivateKey([this.pubkey, this.privkey, this.comment]);

  @override
  int get serializedHeaderSize => 4 * 4;

  @override
  int get serializedSize =>
      serializedHeaderSize +
      keytype.length +
      pubkey.length +
      privkey.length +
      comment.length;

  @override
  void deserialize(SerializableInput input) {
    keytype = deserializeString(input);
    if (keytype != 'ssh-ed25519') throw FormatException('$keytype');
    pubkey = deserializeStringBytes(input);
    if (pubkey.length != 32) throw FormatException('${pubkey.length}');
    privkey = deserializeStringBytes(input);
    if (privkey.length != 64) throw FormatException('${privkey.length}');
    comment = deserializeString(input);
  }

  @override
  void serialize(SerializableOutput output) {
    serializeString(output, keytype);
    serializeString(output, pubkey);
    serializeString(output, privkey);
    serializeString(output, comment);
  }
}

class OpenSSHBCryptKDFOptions extends Serializable {
  Uint8List salt;
  int rounds;
  OpenSSHBCryptKDFOptions([this.salt, this.rounds]);

  @override
  int get serializedHeaderSize => 2 * 4;

  @override
  int get serializedSize => serializedHeaderSize + salt.length;

  @override
  void deserialize(SerializableInput input) {
    salt = deserializeStringBytes(input);
    rounds = input.getUint32();
  }

  @override
  void serialize(SerializableOutput output) {
    serializeString(output, salt);
    output.addUint32(rounds);
  }
}

Uint8List opensshKeyCrypt(bool forEncryption, Uint8List password,
    Uint8List salt, int rounds, Uint8List input, int cipherAlgo) {
  int keySize = Cipher.keySize(cipherAlgo),
      blockSize = Cipher.blockSize(cipherAlgo);
  Uint8List key = bcryptPbkdf(password, salt, keySize + blockSize, rounds);
  BlockCipher cipher = Cipher.cipher(cipherAlgo);
  cipher.init(
      forEncryption,
      ParametersWithIV(KeyParameter(viewUint8List(key, 0, keySize)),
          viewUint8List(key, keySize, blockSize)));
  return applyBlockCipher(cipher, input);
}

Uint8List bcryptHash(Uint8List pass, Uint8List salt) {
  throw FormatException('bcryptHash not implemented');
}

Uint8List bcryptPbkdf(
    Uint8List password, Uint8List salt, int length, int rounds) {
  throw FormatException('bcryptPbkdf not implemented');
}
