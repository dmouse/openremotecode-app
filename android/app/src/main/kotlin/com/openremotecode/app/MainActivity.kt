package com.openremotecode.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.crypto.hpke.HPKE
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val cryptoWorker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openremotecode/hpke").setMethodCallHandler { call, result ->
            if (call.method != "seal" && call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val args = call.arguments as Map<*, *>
                fun bytes(name: String, max: Int): ByteArray {
                    val value = args[name] as ByteArray
                    require(value.isNotEmpty() && value.size <= max)
                    return value.copyOf()
                }
                val secret = bytes("privateKey", 32)
                val public = bytes("publicKey", 65)
                val peer = bytes("peerKey", 65)
                val aad = bytes("aad", 2048)
                val content = bytes("content", 1500000)
                val enc = if (call.method == "open") bytes("enc", 65) else null
                try {
                    cryptoWorker.execute {
                        try {
                            val hpke = HPKE(HPKE.mode_auth, HPKE.kem_P256_SHA256, HPKE.kdf_HKDF_SHA256, HPKE.aead_AES_GCM256)
                            val own = hpke.deserializePrivateKey(secret, public)
                            val other = hpke.deserializePublicKey(peer)
                            val info = "opencode-remote/relay/v1".toByteArray(Charsets.UTF_8)
                            val output: Any = if (enc == null) {
                                val context = hpke.setupAuthS(other, info, own)
                                mapOf("enc" to context.encapsulation, "ciphertext" to context.seal(aad, content))
                            } else {
                                hpke.setupAuthR(enc, own, info, other).open(aad, content)
                            }
                            runOnUiThread { result.success(output) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("crypto_failed", "Encrypted message could not be processed", null) }
                        } finally {
                            secret.fill(0)
                            content.fill(0)
                        }
                    }
                } catch (_: Exception) {
                    secret.fill(0)
                    content.fill(0)
                    result.error("crypto_busy", "Encryption is busy", null)
                }
            } catch (_: Exception) {
                result.error("crypto_failed", "Invalid encrypted message", null)
            }
        }
    }
    override fun onDestroy() {
        cryptoWorker.shutdown()
        super.onDestroy()
    }
}
