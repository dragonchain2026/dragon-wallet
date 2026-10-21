package org.dragonwallet.dragon_wallet

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONArray
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class TransferTests {
    @Test fun sendAllDeductsFeeAndLeavesNoChange() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            for (sender in listOf(KeyCodec.address(pk), KeyCodec.witnessAddress(pk))) {
                val inputs = listOf(coin(pk), coin(pk,"22".repeat(32))).map {
                    it + ("script_pub_key" to Transfer.hex(Transfer.script(sender)))
                }
                val plan = Transfer.prepare("fixture",pk,sender,"546",2,inputs,sender,true)
                assertEquals(2, plan.coins.size)
                assertEquals(2000000L, plan.amount + plan.fee)
                assertEquals(0L, plan.change)
                val signed = Transfer.sign(plan,raw,pk)
                assertEquals(plan.amount.toString(),signed["amount_atomic"])
                val higherFee = Transfer.prepare("fixture",pk,sender,"546",3,inputs,sender,true)
                assertTrue(higherFee.amount < plan.amount)
                val tooMany = (1..10001).map { i -> inputs[0] + ("txid" to "%064x".format(i)) }
                rejects { Transfer.prepare("fixture",pk,sender,"546",2,tooMany,sender,true) }
                rejects { Transfer.prepare("fixture",pk,sender,"546",2,listOf(inputs[0] + ("value_atomic" to "546")),sender,true) }
            }
        } finally { raw.fill(0) }
    }
    @Test fun tenThousandWitnessInputsSerializeAndSign() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            val sender = KeyCodec.witnessAddress(pk)
            val template = coin(pk) + ("script_pub_key" to Transfer.hex(Transfer.script(sender)))
            val inputs = (1..10000).map { i -> template + ("txid" to "%064x".format(i)) }
            for (count in listOf(252,253,10000)) {
                val plan = Transfer.prepare("large-fixture",pk,sender,"546",1,inputs.take(count),sender,true)
                assertEquals(count,plan.coins.size)
                assertEquals(count*1000000L,plan.amount+plan.fee)
                assertEquals(0L,plan.change)
                val worst = Transfer.serialize(plan,List(count){ byteArrayOf() },List(count){ listOf(ByteArray(691),ByteArray(898)) })
                val stripped = Transfer.serialize(plan,List(count){ byteArrayOf() })
                assertEquals(((stripped.size*3L+worst.size+3)/4),plan.fee)
                if (count==10000) {
                    val signed = Transfer.sign(plan,raw,pk)
                    assertEquals(plan.amount.toString(),signed["amount_atomic"])
                    assertEquals(Transfer.hex(Transfer.hash(stripped).reversedArray()),signed["txid"])
                    assertEquals(10000,signed["input_count"])
                }
            }
        } finally { raw.fill(0) }
    }
    @Test fun witnessAddressMatchesReportedNodeAddress() {
        val hash = Transfer.unhex("6b68fffa92beab8feeff451f1a88a4a2f7bcac65")
        assertEquals("dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh", KeyCodec.witnessAddressForHash(hash))
        assertEquals("SX5w7tZdEJtVQbiFzLe3qQVy7aXT59CmUn", KeyCodec.encode(byteArrayOf(63) + hash))
    }
    @Test fun signsWitnessInputsAndExportsPublicFixture() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            val sender = KeyCodec.witnessAddress(pk)
            val inputs = listOf(coin(pk), coin(pk,"22".repeat(32))).map {
                it + ("script_pub_key" to Transfer.hex(Transfer.script(sender)))
            }
            val plan = Transfer.prepare("fixture",pk,sender,"1500000",2,inputs,sender)
            assertTrue(plan.witness)
            val signed = Transfer.sign(plan,raw,pk)
            val bytes = Transfer.unhex(signed["hex"] as String)
            val stripped = Transfer.serialize(plan,List(2) { byteArrayOf() })
            assertEquals(0, bytes[4].toInt()); assertEquals(1,bytes[5].toInt())
            assertNotEquals(Transfer.hex(Transfer.hash(bytes).reversedArray()), signed["txid"])
            assertEquals(Transfer.hex(Transfer.hash(stripped).reversedArray()), signed["txid"])
            assertTrue(plan.fee >= 2 * ((stripped.size*3 + bytes.size + 3)/4))
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            java.io.File(context.cacheDir,"transfer-witness-compatibility.json").writeText(JSONObject()
                .put("signed",JSONObject(signed)).put("inputs",JSONArray(inputs.map { JSONObject(it) })).toString())
            rejects { Transfer.prepare("fixture",pk,sender,"100000",1,inputs,KeyCodec.address(pk)) }
        } finally { raw.fill(0) }
    }
    @Test fun mainnetRecipientScripts() {
        val payload = "11".repeat(20)
        assertEquals("a914${payload}87", Transfer.hex(Transfer.script("sKoe1eYdfZcypGyJTjizagWTakpi5fScmU")))
        assertEquals("0014$payload", Transfer.hex(Transfer.script("dragon1qzyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3h3066r")))
        assertEquals("0020" + "22".repeat(32), Transfer.hex(Transfer.script("dragon1qyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3qt2lhh9")))
        rejects { Transfer.script("Dragon1qzyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3h3066r") }
        rejects { Transfer.script("Tas3vExdmvHHZhkC1z5ByHT3Szd491AdKz") }
    }
    private fun coin(pk: ByteArray, txid: String = "11".repeat(32), value: String = "1000000") = mapOf(
        "txid" to txid, "vout" to 1, "value_atomic" to value,
        "script_pub_key" to Transfer.hex(Transfer.script(KeyCodec.address(pk))), "coinbase" to false, "confirmations" to 10)
    @Test fun signsMultipleInputsAndExportsPublicCompatibilityFixture() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            val inputs = listOf(coin(pk), coin(pk, "22".repeat(32)))
            val recipient = KeyCodec.encode(byteArrayOf(63) + ByteArray(20) { 0x11 })
            val plan = Transfer.prepare("fixture", pk, recipient, "1500000", 2, inputs)
            assertEquals(2, plan.coins.size)
            val signed = Transfer.sign(plan, raw, pk)
            assertEquals(2000000L, plan.amount + plan.fee + plan.change)
            val bytes = Transfer.unhex(signed["hex"] as String)
            assertTrue(plan.fee >= bytes.size * 2)
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            java.io.File(context.cacheDir, "transfer-compatibility.json").writeText(JSONObject()
                .put("signed", JSONObject(signed)).put("inputs", JSONArray(inputs.map { JSONObject(it) })).toString())
        } finally { raw.fill(0) }
    }
    @Test fun rejectsWrongOwnershipImmaturityDuplicatesAndInsufficientFunds() {
        val raw = KeyNative.generate()!!
        try {
            val pk = KeyNative.publicKey(raw)!!
            val address = KeyCodec.address(pk)
            val input = coin(pk)
            fun attempt(items: List<Map<String, Any>>, amount: String = "100000") =
                Transfer.prepare("fixture",pk,address,amount,1,items)
            rejects { attempt(listOf(input + ("script_pub_key" to "76a914"))) }
            rejects { attempt(listOf(input + ("coinbase" to true))) }
            rejects { attempt(listOf(input,input)) }
            rejects { attempt(listOf(input), "1000000") }
            rejects { attempt(listOf(input), "0") }
            rejects { Transfer.script(address.dropLast(1) + if (address.last() == '1') "2" else "1") }
            val noChange = attempt(listOf(input), "998100")
            assertEquals(0L, noChange.change)
            assertEquals(1900L, noChange.fee)
        } finally { raw.fill(0) }
    }
    private fun rejects(action: () -> Unit) {
        var failed = false
        try { action() } catch (_: IllegalArgumentException) { failed = true }
        assertTrue(failed)
    }
}
