package org.dragonwallet.dragon_wallet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.KeyguardManager
import android.content.Intent
import android.view.WindowManager
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var english = true
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var vault: KeyVault
    private var pending: MethodChannel.Result? = null
    private var operation: (() -> Any?)? = null
    private var transfer: Pair<String, Transfer.Plan>? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        vault = KeyVault(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dragon.wallet/keys").setMethodCallHandler { call, result ->
            if (call.method == "setLanguage") {
                english = call.argument<String>("language") != "zh"
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "secure") {
                if (call.argument<Boolean>("enabled") == true) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                result.success(null)
                return@setMethodCallHandler
            }
            if (pending != null) { result.error("busy", "请先完成当前操作", null); return@setMethodCallHandler }
            pending = result
            when (call.method) {
                "lockSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_SECURITY_SETTINGS))
                        pending = null; result.success(null)
                    } catch (_: Exception) { finishError("settings", "无法打开系统安全设置") }
                }
                "list" -> execute { vault.list() }
                "prepareTransfer", "quoteTransfer" -> execute {
                    if (call.method == "prepareTransfer") transfer = null
                    val id = call.argument<String>("id") ?: ""
                    val sendAll = call.argument<Boolean>("send_all") == true
                    // A truncated API page may still spend all of its selected inputs.
                    // Transfer.prepare enforces MAX_INPUTS; Flutter explains the partial amount.
                    val plan = Transfer.prepare(id, vault.publicKey(id), call.argument<String>("recipient") ?: "",
                        call.argument<String>("amount_atomic") ?: "", call.argument<Number>("fee_rate")?.toLong() ?: 0,
                        call.argument<List<Map<*, *>>>("utxos") ?: emptyList(), call.argument<String>("sender"), sendAll)
                    val ticket = java.util.UUID.randomUUID().toString()
                    if (call.method == "prepareTransfer") transfer = ticket to plan
                    plan.summary() + mapOf("ticket" to ticket)
                }
                "signTransfer" -> {
                    val prepared = transfer
                    transfer = null
                    if (prepared == null || prepared.first != call.argument<String>("ticket")) {
                        finishError("invalid", "转账预览已失效，请重新填写")
                    } else authenticate {
                        vault.withSecret(prepared.second.keyId) { secret, pk ->
                            val raw = secret.copyOfRange(0,1281)
                            try { Transfer.sign(prepared.second, raw, pk) } finally { raw.fill(0) }
                        }
                    }
                }
                "generate" -> authenticate { vault.generate() }
                "generateMnemonic" -> authenticate { vault.generateMnemonic() }
                "import" -> {
                    val text = call.argument<String>("wif") ?: ""
                    if (text.length > 2000) finishError("invalid", "私钥长度无效")
                    else authenticate { vault.importWif(text) }
                }
                "importMnemonic" -> {
                    val text = call.argument<String>("mnemonic") ?: ""
                    if (text.length > 512) finishError("invalid", "助记词过长")
                    else authenticate { vault.importMnemonic(text) }
                }
                "viewWif", "viewMnemonic" -> {
                    val id = call.argument<String>("id") ?: ""
                    val mnemonic = call.method == "viewMnemonic"
                    authenticate {
                        val bytes = if (mnemonic) vault.exportMnemonic(id) else vault.exportWif(id)
                        try { bytes.toString(Charsets.UTF_8).trim() } finally { bytes.fill(0) }
                    }
                }
                "copySecret" -> {
                    try {
                        val text = call.argument<String>("text") ?: ""
                        require(text.isNotEmpty() && text.length <= 2000)
                        val clip = android.content.ClipData.newPlainText("Dragon Wallet", text)
                        clip.description.extras = android.os.PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        (getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(clip)
                        pending = null; result.success(null)
                    } catch (_: Exception) { finishError("clipboard", "复制失败，请重试") }
                }
                "delete" -> {
                    val id = call.argument<String>("id") ?: ""
                    authenticate { vault.delete(id); null }
                }
                else -> { pending = null; result.notImplemented() }
            }
        }
    }
    private fun authenticate(action: () -> Any?) {
        val manager = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        if (!manager.isDeviceSecure) {
            finishError("lock_required", "请先在 Android 系统设置中启用锁屏 PIN 或密码，再管理私钥")
            return
        }
        operation = action
        val intent = manager.createConfirmDeviceCredentialIntent("Dragon Wallet", if (english) "Verify device lock to access local keys" else "验证设备锁屏以访问本地密钥")
        if (intent == null) { finishError("auth", "无法验证设备锁屏"); return }
        try { startActivityForResult(intent, 701) }
        catch (_: Exception) { finishError("auth", "无法验证设备锁屏") }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 701 || pending == null) return
        if (resultCode != RESULT_OK) { finishError("cancelled", "操作已取消"); return }
        val action = operation
        operation = null
        if (action != null) execute(action) else finishError("auth", "验证已过期，请重试")
    }
    private fun execute(action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                runOnUiThread { pending?.success(value); pending = null }
            } catch (error: IllegalArgumentException) {
                runOnUiThread { finishError("invalid", error.message ?: "密钥数据无效") }
            } catch (_: Exception) {
                runOnUiThread { finishError("vault", "密钥操作失败，请重新验证锁屏后重试；设备锁屏变更后可能需要从备份恢复") }
            }
        }
    }
    private fun finishError(code: String, message: String) {
        pending?.error(code, message, null)
        pending = null; operation = null
    }
    override fun onDestroy() {
        operation = null; pending = null
        worker.shutdown()
        super.onDestroy()
    }
}
