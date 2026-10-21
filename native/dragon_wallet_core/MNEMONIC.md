# Dragon Wallet mnemonic derivation v1

This version is a permanent recovery contract. Never change it for existing
mnemonics. It is not BIP32, Bitcoin key derivation, or a mnemonic feature of the
Dragonchain node. One mnemonic restores one Falcon-512 key and its `dragon1q`
mainnet P2WPKH address. It does not restore address names or unrelated imported keys.

1. Generate 32 bytes with Android `SecureRandom` (256 bits of entropy).
2. Encode using BIP39 English and SHA256 checksum, producing 24 words.
   Import also accepts standard 12, 15, 18 and 21 word English phrases, with
   word-list and checksum validation. Whitespace/case are normalized.
3. Derive the 64-byte BIP39 seed: PBKDF2-HMAC-SHA512, 2048 rounds, NFKD mnemonic
   password, salt `mnemonic`. The passphrase is **empty**; the UI does not support
   an additional passphrase. Do not silently introduce one in future versions.
4. Initialize SHAKE256 with the exact ASCII bytes
   `Dragon Wallet/Falcon-512/mnemonic/v1` (no NUL), followed by all 64 seed bytes.
5. Pass that SHAKE256 stream to the pinned Dragonchain/PQClean Falcon-512 keygen,
   logn=9. Encode f/g/F exactly as the existing 1281-byte Falcon private key,
   header 0x59. This does not replace OS randomness for signing or random keygen.
6. Derive the existing node-compatible public key and HASH160(0x07 || raw_pk),
   then encode witness version 0 with Bech32 HRP `dragon`. WIF uses prefix 0x80
   and compressed flag 0x01, as for existing native keys.

Fixed **public test vector**, never use for funds:

- Entropy: 32 zero bytes.
- Mnemonic: `abandon` repeated 23 times, followed by `art`.
- Address: `dragon1qhfpt5f9ude8yksn479ga32merjg7ks9dgmk6yd`.
- SHA256 of raw 1281-byte private key:
  `fcf3b5f0f2f933f9b4d45535fa01bd7e5fdb70271542e30a20d8cd2de3177628`.

Android instrumentation pins this result, verifies the official BIP39 TREZOR
vector, and covers malformed mnemonics, fresh entropy, deterministic recovery,
WIF recovery and signing. Run the vectors on each supported execution architecture
before releasing changes to the pinned Falcon core/compiler settings.

## Storage and backup

Version 1 encrypted records remain supported (1281 secret bytes + WIF flag).
Version 2 records encrypt the same 1282-byte prefix plus 16/20/24/28/32 entropy
bytes in one AES-GCM payload using the existing authenticated Android Keystore
key. Public metadata includes `mnemonicVersion: 1`; no seed or words are stored
in preferences or sent to Wallet API. The entropy can reproduce the phrase and
key with the fixed rule above. Export verifies the derived public key matches.

The `backupType` public metadata records `wif` or `mnemonic`, according to the
creation/import action. The UI offers only that format's authenticated view action. Reimport
updates this selection even if the same key already exists. Existing records
without this field default to mnemonic if they have entropy, otherwise WIF.

Viewing a mnemonic or WIF requires device authentication. The native method
returns the plaintext to the protected Flutter dialog; an explicit copy button
writes it to the Android clipboard with the sensitive-content flag. The dialog
closes when the app becomes inactive. Import is name-then-paste for both formats;
file import and export have been removed from the method channel. A WIF
does not contain entropy and cannot be converted back into a short mnemonic.
Reimporting WIF over an accessible mnemonic record preserves its entropy; if its
Keystore entry is invalidated, restore from the mnemonic backup instead.

The viewed/copied backup is plaintext; it grants spending access. Mutable
secret buffers are cleared, but JVM/Flutter strings and upstream memory cannot
be guaranteed erased. The private-key screen keeps Android FLAG_SECURE enabled.

## Sources and license

[BIP39 specification](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
is MIT licensed. The bundled English word list is copied verbatim from
[Bitcoin BIPs](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt).
Its SHA256 is `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`,
verified when loading. The pinned Falcon source retains its existing license.
