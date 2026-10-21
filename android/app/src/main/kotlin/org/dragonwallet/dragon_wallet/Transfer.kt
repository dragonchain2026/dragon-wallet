package org.dragonwallet.dragon_wallet

import java.io.ByteArrayOutputStream
import java.math.BigInteger

/** Mainnet P2PKH/P2WPKH Falcon inputs; mainnet P2PKH/P2SH/witness-v0 recipients. */
object Transfer {
    const val MAX_INPUTS = 10000
    private const val MAX_MONEY = 21000000L * 100000000L
    private const val MAX_FEE = 100000000L
    fun hex(bytes: ByteArray): String {
        val digits = "0123456789abcdef"
        val chars = CharArray(bytes.size * 2)
        bytes.forEachIndexed { i, byte -> val v = byte.toInt() and 255; chars[i*2] = digits[v ushr 4]; chars[i*2+1] = digits[v and 15] }
        return String(chars)
    }
    fun unhex(text: String): ByteArray {
        require(text.length % 2 == 0 && text.matches(Regex("[0-9a-fA-F]*"))) { "交易数据无效" }
        return text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
    fun hash(bytes: ByteArray) = KeyCodec.sha256(KeyCodec.sha256(bytes))
    fun script(address: String): ByteArray {
        require(address.length in 14..90) { "主网收款地址无效" }
        if (address.lowercase().startsWith("dragon1")) {
            require(address == address.lowercase() || address == address.uppercase()) { "地址不能混用大小写" }
            val text = address.lowercase()
            val values = text.substring(7).map { "qpzry9x8gf2tvdw0s3jn54khce6mua7l".indexOf(it) }
            require(values.size >= 7 && values.none { it < 0 } && values[0] == 0) { "仅支持主网 witness v0 地址" }
            var checksum = 1
            val generators = intArrayOf(0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3)
            for (v in "dragon".map { it.code shr 5 } + listOf(0) + "dragon".map { it.code and 31 } + values) {
                val top = checksum ushr 25
                checksum = ((checksum and 0x1ffffff) shl 5) xor v
                for (i in 0..4) if ((top ushr i) and 1 != 0) checksum = checksum xor generators[i]
            }
            require(checksum == 1) { "收款地址校验和错误" }
            var bits = 0; var accumulator = 0
            val program = ByteArrayOutputStream()
            for (v in values.subList(1, values.size - 6)) {
                accumulator = ((accumulator shl 5) or v) and 0xfff; bits += 5
                if (bits >= 8) { bits -= 8; program.write((accumulator ushr bits) and 255) }
            }
            require(bits < 5 && ((accumulator shl (8-bits)) and 255) == 0 && program.size() in listOf(20,32)) { "收款地址长度无效" }
            return byteArrayOf(0, program.size().toByte()) + program.toByteArray()
        }
        val alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        var number = BigInteger.ZERO
        for (c in address) {
            val digit = alphabet.indexOf(c)
            require(digit >= 0) { "收款地址字符无效" }
            number = number.multiply(BigInteger.valueOf(58)).add(BigInteger.valueOf(digit.toLong()))
        }
        val raw = number.toByteArray()
        val bytes = ByteArray(address.takeWhile { it == '1' }.length) + if (raw[0] == 0.toByte()) raw.drop(1).toByteArray() else raw
        require(bytes.size == 25 && bytes[0].toInt() in listOf(63,125)) { "仅支持 Dragonchain 主网地址" }
        require(KeyCodec.encode(bytes.copyOf(21)) == address) { "收款地址校验和错误" }
        val payload = bytes.copyOfRange(1,21)
        return if (bytes[0].toInt() == 63) unhex("76a914") + payload + unhex("88ac") else unhex("a914") + payload + unhex("87")
    }
    data class Coin(val txid: String, val vout: Long, val value: Long)
    data class Plan(val keyId: String, val sender: String, val recipient: String, val amount: Long,
                    val fee: Long, val change: Long, val rate: Long, val coins: List<Coin>,
                    val ownScript: ByteArray, val recipientScript: ByteArray) {
        val witness: Boolean get() = ownScript.size == 22 && ownScript[0] == 0.toByte()
        fun summary(): Map<String, Any> = mapOf("sender" to sender, "recipient" to recipient,
            "amount_atomic" to amount.toString(), "fee_atomic" to fee.toString(), "change_atomic" to change.toString(),
            "input_count" to coins.size, "fee_rate" to rate)
    }
    fun prepare(keyId: String, pk: ByteArray, recipient: String, amountText: String, rate: Long,
                inputs: List<Map<*, *>>, senderAddress: String? = null, sendAll: Boolean = false): Plan {
        require(amountText.matches(Regex("[0-9]{1,16}"))) { "金额无效" }
        val amount = amountText.toLong()
        require(amount in 546..MAX_MONEY) { "金额须至少为 0.00000546" }
        require(rate in 1..1000) { "手续费率须为 1–1000 最小单位/字节" }
        val sender = senderAddress ?: KeyCodec.address(pk)
        require(sender == KeyCodec.address(pk) || sender == KeyCodec.witnessAddress(pk)) { "付款地址不属于当前私钥" }
        val own = script(sender); val destination = script(recipient)
        require(inputs.size <= MAX_INPUTS) { "输入数量过多" }
        val candidates = inputs.map { input ->
            require(input["script_pub_key"] == hex(own)) { "待花费输出不属于当前地址" }
            val confirmations = (input["confirmations"] as Number).toInt()
            require(confirmations >= 1 && (input["coinbase"] == false || confirmations >= 100)) { "输出尚未成熟" }
            val txid = input["txid"] as String
            val vout = (input["vout"] as Number).toLong()
            val value = (input["value_atomic"] as String).toLong()
            require(txid.matches(Regex("[0-9a-f]{64}")) && vout in 0..0xffffffffL && value in 1..MAX_MONEY) { "输出数据无效" }
            Coin(txid, vout, value)
        }.sortedByDescending { it.value }
        require(candidates.map { "${it.txid}:${it.vout}" }.distinct().size == candidates.size) { "输出重复" }
        if (sendAll) {
            require(candidates.size <= MAX_INPUTS) { "输出数量超过单笔限制，无法一次全部转出" }
            var sum = 0L
            for (coin in candidates) sum = Math.addExact(sum, coin.value)
            require(sum <= MAX_MONEY) { "输入总额无效" }
            val stripped = 10 + (if (candidates.size >= 253) 2 else 0) + candidates.size * 41 + 9 + destination.size
            val vsize = if (own.size == 22) (stripped * 4 + 2 + candidates.size * 1596 + 3) / 4
                else 10 + (if (candidates.size >= 253) 2 else 0) + candidates.size * 1638 + 9 + destination.size
            val fee = rate * vsize
            require(fee in 1..MAX_FEE) { "手续费超过单笔上限 1 Dragonchain" }
            require(sum - fee >= 546) { "余额不足以支付手续费和最小转账金额" }
            return Plan(keyId, sender, recipient, sum - fee, fee, 0, rate, candidates, own, destination)
        }
        var total = 0L
        val selected = mutableListOf<Coin>()
        for (coin in candidates.take(MAX_INPUTS)) {
            total = Math.addExact(total, coin.value)
            require(total <= MAX_MONEY) { "输入总额无效" }
            selected.add(coin)
            // Worst-case Falcon signature (690+hashtype), 898-byte chain public key,
            // canonical PUSHDATA2, and CompactSize script length: 1638 bytes/input.
            val witness = own.size == 22
            val stripped = 10 + (if (selected.size >= 253) 2 else 0) + selected.size * 41 + 9 + destination.size
            val vsize = if (witness) (stripped * 4 + 2 + selected.size * 1596 + 3) / 4
                else 10 + (if (selected.size >= 253) 2 else 0) + selected.size * 1638 + 9 + destination.size
            val noChangeFee = rate * vsize
            val withChangeFee = noChangeFee + rate * (9 + own.size)
            if (total < amount + noChangeFee) continue
            val change = if (total - amount - withChangeFee >= 546) total - amount - withChangeFee else 0
            val fee = total - amount - change
            require(fee in 1..MAX_FEE) { "手续费超过单笔上限 1 Dragonchain" }
            return Plan(keyId, sender, recipient, amount, fee, change, rate, selected.toList(), own, destination)
        }
        throw IllegalArgumentException("可用余额不足以支付金额及手续费（单笔最多 10000 个输入）")
    }
    private fun ByteArrayOutputStream.le(value: Long, bytes: Int) { for (i in 0 until bytes) write((value ushr (8*i)).toInt() and 255) }
    private fun ByteArrayOutputStream.compact(value: Int) {
        if (value < 253) write(value) else { write(253); le(value.toLong(),2) }
    }
    private fun ByteArrayOutputStream.vector(bytes: ByteArray) { compact(bytes.size); write(bytes) }
    fun serialize(plan: Plan, scripts: List<ByteArray>, witnesses: List<List<ByteArray>>? = null): ByteArray {
        require(scripts.size == plan.coins.size)
        val out = ByteArrayOutputStream()
        out.le(2,4)
        if (witnesses != null) { require(witnesses.size == plan.coins.size); out.write(byteArrayOf(0,1)) }
        out.compact(plan.coins.size)
        plan.coins.forEachIndexed { i, coin ->
            out.write(unhex(coin.txid).reversedArray()); out.le(coin.vout,4)
            out.vector(scripts[i]); out.le(0xffffffffL,4)
        }
        out.compact(if (plan.change > 0) 2 else 1)
        out.le(plan.amount,8); out.vector(plan.recipientScript)
        if (plan.change > 0) { out.le(plan.change,8); out.vector(plan.ownScript) }
        if (witnesses != null) for (stack in witnesses) {
            out.compact(stack.size)
            for (item in stack) out.vector(item)
        }
        out.le(0,4)
        return out.toByteArray()
    }
    fun digest(plan: Plan, input: Int, cached: List<ByteArray>? = null): ByteArray {
        if (!plan.witness) return hash(serialize(plan,
            plan.coins.indices.map { if (it == input) plan.ownScript else byteArrayOf() }) + byteArrayOf(1,0,0,0))
        val common = cached ?: witnessHashes(plan)
        val coin = plan.coins[input]
        val out = ByteArrayOutputStream()
        out.le(2,4); out.write(common[0]); out.write(common[1])
        out.write(unhex(coin.txid).reversedArray()); out.le(coin.vout,4)
        out.vector(unhex("76a914") + plan.ownScript.copyOfRange(2,22) + unhex("88ac"))
        out.le(coin.value,8); out.le(0xffffffffL,4); out.write(common[2])
        out.le(0,4); out.le(1,4)
        return hash(out.toByteArray())
    }
    private fun witnessHashes(plan: Plan): List<ByteArray> {
        val prevouts = ByteArrayOutputStream(); val sequences = ByteArrayOutputStream()
        for (coin in plan.coins) {
            prevouts.write(unhex(coin.txid).reversedArray()); prevouts.le(coin.vout,4)
            sequences.le(0xffffffffL,4)
        }
        val outputs = ByteArrayOutputStream()
        outputs.le(plan.amount,8); outputs.vector(plan.recipientScript)
        if (plan.change > 0) { outputs.le(plan.change,8); outputs.vector(plan.ownScript) }
        return listOf(hash(prevouts.toByteArray()), hash(sequences.toByteArray()), hash(outputs.toByteArray()))
    }
    private fun push(bytes: ByteArray): ByteArray {
        require(bytes.size in 256..2048)
        return byteArrayOf(0x4d, (bytes.size and 255).toByte(), (bytes.size ushr 8).toByte()) + bytes
    }
    fun sign(plan: Plan, raw: ByteArray, pk: ByteArray): Map<String, Any> {
        require(KeyCodec.address(pk) == plan.sender || KeyCodec.witnessAddress(pk) == plan.sender) { "签名地址不匹配" }
        require(plan.witness || plan.coins.size <= 4000) { "交易超过节点签名操作限制" }
        val common = if (plan.witness) witnessHashes(plan) else null
        val signatures = plan.coins.indices.map { index ->
            val signature = KeyNative.sign(raw, digest(plan,index,common)) ?: error("本地签名失败")
            signature + byteArrayOf(1)
        }
        val publicKey = byteArrayOf(7) + pk
        val scripts = signatures.map { if (plan.witness) byteArrayOf() else push(it) + push(publicKey) }
        val stripped = serialize(plan, scripts)
        val bytes = if (plan.witness) serialize(plan, scripts, signatures.map { listOf(it, publicKey) }) else stripped
        val vsize = (stripped.size * 3 + bytes.size + 3) / 4
        check(plan.fee >= plan.rate * vsize)
        return plan.summary() + mapOf("hex" to hex(bytes), "txid" to hex(hash(stripped).reversedArray()))
    }
}
