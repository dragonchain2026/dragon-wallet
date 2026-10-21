# Local Falcon key management

Android uses `dragon_keys_jni` to generate Falcon-512 private keys and recover
public keys from imported WIF. Mnemonic wallets use BIP39 English mnemonics with a
versioned Falcon derivation; see [the recovery contract](MNEMONIC.md). Local
transaction signing is available through the Android wallet. `dragon_key_check` signs a fixed, non-transaction challenge
only to verify that an imported/generated key actually works.

## Source and encoding

The vendored Falcon and RIPEMD-160 files come from Dragonchain commit
`e94c7595a532e3ddb6d9c187926f17e484962191`; original SHA-256 digests are in
`vendor/dragonchain/provenance.json`. Copyright notices remain in the files;
the Dragonchain MIT license is in `vendor/dragonchain/COPYING`, and Falcon's MIT
license is embedded in its headers. Local adaptations are:

- `pqclean.cpp`: check all three OS entropy return values instead of ignoring failure.
- `crypto/common.h`: a small portable implementation of the endian helpers needed
  by the unchanged RIPEMD-160 implementation.
- `src/system_random.cpp`: read the OS CSPRNG (`/dev/urandom`); no fallback seed.

Private keys contain exactly 1281 bytes, starting with `0x59`. Raw public keys
contain 897 bytes, starting with `0x09`. Dragonchain's serialized public key is
`0x07 || raw_public_key` (898 bytes). The app's P2WPKH address is Bech32 with HRP
`dragon`, witness version 0, and the 20-byte RIPEMD160(SHA256(serialized_public_key)).
The equivalent legacy P2PKH address is retained internally for migrating old selections.
WIF is Base58Check of
`0x80 || private_key || optional_0x01`; both reference formats are accepted and
the compression marker is preserved. Newly generated keys include the marker.
No BIP32, Bitcoin/secp256k1 private key, or testnet import is supported.

Import checks the WIF checksum/network/length, canonical polynomial encodings,
the full NTRU relation, both reference key-generation norm bounds, and a local
sign/verify roundtrip. A malformed F cannot pass merely by deriving a public key
from f and g.

## Storage and backup viewing

Android owns the encrypted private keys. Pasted imports and authenticated backup
viewing cross the local Flutter method channel; no secret is sent to Wallet API.
Each record is AES-256-GCM encrypted using an independent Android Keystore key
requiring recent device authentication. The public key is authenticated as AAD.
Records reside in the app's no-backup directory, and Android app backup is disabled.
Import atomically replaces that record with a fresh wrapping key, allowing recovery
from a lost/invalidated Keystore entry without altering other addresses.

Generate/import/view/delete each require the system credential confirmation.
The private-key screen sets FLAG_SECURE; private input is obscured, excludes IME
learning, and is cleared on submit/background/disposal. The authenticated dialog
shows WIF or mnemonic according to the wallet's backup type. An explicit copy
button writes the full content to the Android clipboard with the sensitive flag.
The dialog closes when the app becomes inactive. File import/export has been removed.

Owned native/JVM byte buffers are cleared where possible. Managed Strings,
BigInteger internals and upstream temporary buffers cannot be guaranteed to be
erased; this is not a claim of full memory sanitization or an external security audit.
Removing device credentials, clearing app data or uninstalling can invalidate
local storage; users must retain their WIF backups. Falcon operations are software,
not hardware Falcon signing. Android P2PKH and P2WPKH transfer signing uses SIGHASH_ALL,
canonical PUSHDATA2, version 2 and final sequences; change returns to the signing address.
P2WPKH uses BIP143 (including each input's amount), witness serialization, virtual-byte
fee estimation, and a transaction ID computed without witnesses. The app displays only
`dragon1q` P2WPKH addresses for local keys. The local configured API is trusted for UTXO values and availability. No private key
is sent to that API. Real funded transaction broadcasting remains untested.

## Verification

`cmake -S native/dragon_wallet_core -B build/native -DDRAGON_BUILD_KEY_TESTS=ON`,
then build and run CTest on Linux; the same executable runs on the Android emulator
when cross-compiled with the Android NDK. It covers recovery, independent generation,
known RIPEMD output, malformed/truncated keys and buffer cleanup.

Android instrumentation tests in `dragon-wallet/android/app/src/androidTest` cover
JNI, both WIF formats, invalid inputs, encrypted storage, export/reimport, lost
wrapping-key recovery and tamper detection. The Keystore test requires a recently
authenticated emulator lock screen; use disposable generated test keys only.

`TransferTests` uses ephemeral in-memory keys and synthetic outpoints; no lock-screen
changes or saved user keys are required. It covers multiple inputs, fee bounds,
ownership, maturity, duplicates, insufficient funds and mainnet recipient scripts.
A synthetic two-input signed transaction was independently verified by the local
mainnet node using `signrawtransaction(hex, prevtxs, [], "ALL")`: the explicit empty
key list prevents node-wallet signing. Existing signatures passed standard script
flags, and modifying an output failed verification. This check does not broadcast.
