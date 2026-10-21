package org.dragonwallet.dragon_wallet

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyTests {
    @Test fun nativeRecoveryAndWifFormats() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            val address = KeyCodec.address(pk)
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            java.io.File(context.cacheDir, "key-compatibility.json").writeText(
                org.json.JSONObject().put("address", address).put("publicKey",
                    (byteArrayOf(7) + pk).joinToString("") { "%02x".format(it) }).toString())
            assertTrue(address.startsWith("S"))
            for (flag in byteArrayOf(0, 1)) {
                val original = raw + byteArrayOf(flag)
                val decoded = KeyCodec.decodeWif(KeyCodec.wif(original))
                try {
                    assertArrayEquals(original, decoded)
                    val restored = decoded.copyOfRange(0, 1281)
                    try { assertEquals(address, KeyCodec.address(KeyNative.publicKey(restored)!!)) }
                    finally { restored.fill(0) }
                } finally { original.fill(0); decoded.fill(0) }
            }
        } finally { raw.fill(0) }
    }
    @Test fun rejectsForeignChecksumAndMalformedKeys() {
        val raw = KeyNative.generate()!!
        try {
            val wrongNetwork = byteArrayOf(0xef.toByte()) + raw + byteArrayOf(1)
            try { rejects { KeyCodec.decodeWif(KeyCodec.encode(wrongNetwork)) } }
            finally { wrongNetwork.fill(0) }
            val secret = raw + byteArrayOf(1)
            val wif = try { KeyCodec.wif(secret) } finally { secret.fill(0) }
            rejects { KeyCodec.decodeWif(wif.dropLast(1) + if (wif.last() == '1') "2" else "1") }
            rejects { KeyCodec.decodeWif("0".repeat(1750)) }
            rejects { KeyCodec.decodeWif("1".repeat(2000)) }
            raw[1200] = (raw[1200].toInt() xor 1).toByte()
            assertNull(KeyNative.publicKey(raw))
        } finally { raw.fill(0) }
    }
    @Test fun keystoreExportReimportAndTamperDetection() {
        // Requires a recent device credential unlock; CI may run the other two tests independently.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = KeyVault(context)
        val created = if (InstrumentationRegistry.getArguments().getString("awaitUnlock") == "true") {
            val manager = context.getSystemService(android.content.Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            val intent = manager.createConfirmDeviceCredentialIntent("Dragon Wallet 测试", "验证临时测试地址的加密备份与恢复")!!
            context.startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            val deadline = System.currentTimeMillis() + 180000
            var generated: Map<String,String>? = null
            while (generated == null && System.currentTimeMillis() < deadline) {
                try { generated = vault.generateMnemonic() }
                catch (_: android.security.keystore.UserNotAuthenticatedException) { Thread.sleep(1000) }
            }
            checkNotNull(generated) { "Device authentication timed out" }
        } else vault.generateMnemonic()
        val id = created.getValue("id")
        val exported = vault.exportWif(id)
        val recovery = vault.exportMnemonic(id)
        try {
            assertEquals("true", created["has_mnemonic"])
            assertEquals(created + ("backup_type" to "wif"), vault.importWif(exported.toString(Charsets.UTF_8)))
            assertArrayEquals(recovery, vault.exportMnemonic(id))
            val file = java.io.File(context.noBackupFilesDir, "falcon-keys-v1/$id.json")
            val contents = file.readText()
            assertFalse(contents.contains(exported.toString(Charsets.UTF_8).trim()))
            assertFalse(contents.contains(recovery.toString(Charsets.UTF_8).trim()))
            vault.delete(id)
            assertEquals(created, vault.importMnemonic(recovery.toString(Charsets.UTF_8)))
            assertArrayEquals(exported, vault.exportWif(id))
            assertArrayEquals(recovery, vault.exportMnemonic(id))
            vault.delete(id)
            val wifOnly = created + mapOf("has_mnemonic" to "false", "backup_type" to "wif")
            assertEquals(wifOnly, vault.importWif(exported.toString(Charsets.UTF_8)))
            rejects { vault.exportMnemonic(id) }
            val invalidated = org.json.JSONObject(file.readText()).getString("alias")
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(invalidated) }
            rejects { vault.exportWif(id) }
            assertEquals(wifOnly, vault.importWif(exported.toString(Charsets.UTF_8)))
            val record = org.json.JSONObject(file.readText())
            val cipher = android.util.Base64.decode(record.getString("ciphertext"), android.util.Base64.NO_WRAP)
            cipher[0] = (cipher[0].toInt() xor 1).toByte()
            record.put("ciphertext", android.util.Base64.encodeToString(cipher, android.util.Base64.NO_WRAP))
            file.writeText(record.toString())
            rejects { vault.exportWif(id) }
        } finally { exported.fill(0); recovery.fill(0); vault.delete(id) }
    }
    private fun rejects(block: () -> Unit) {
        var rejected = false
        try { block() } catch (_: Exception) { rejected = true }
        assertTrue("invalid input must fail", rejected)
    }
}
