package com.openremotecode.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.crypto.hpke.HPKE
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import android.media.AudioTrack
import android.media.AudioFormat
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.content.Context
import android.os.Build

class MainActivity : FlutterActivity() {
    private var audio: AudioTrack? = null
    private var audioFrames = 0
    private var playbackForeground = false
    private val audioManager by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private val playbackAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change != AudioManager.AUDIOFOCUS_GAIN) stopAudio()
    }
    private val focus by lazy { if (Build.VERSION.SDK_INT >= 26)
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(playbackAttributes).setOnAudioFocusChangeListener(focusListener).build()
        else null }
    private fun stopAudio() {
        audio?.release()
        audio = null
        audioFrames = 0
        if (Build.VERSION.SDK_INT >= 26) focus?.let { audioManager.abandonAudioFocusRequest(it) }
        else { @Suppress("DEPRECATION") audioManager.abandonAudioFocus(focusListener) }
    }
    private val cryptoWorker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openremotecode/voice-playback").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "play" -> {
                        stopAudio()
                        require(playbackForeground && !isFinishing)
                        val pcm = call.arguments as ByteArray
                        require(pcm.isNotEmpty() && pcm.size <= 1920000 && pcm.size % 2 == 0)
                        val granted = if (Build.VERSION.SDK_INT >= 26) audioManager.requestAudioFocus(focus!!)
                            else { @Suppress("DEPRECATION") audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT) }
                        require(granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                        val track = AudioTrack.Builder().setAudioAttributes(playbackAttributes)
                            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                            .setBufferSizeInBytes(pcm.size).setTransferMode(AudioTrack.MODE_STATIC).build()
                        audio = track
                        audioFrames = pcm.size / 2
                        require(track.write(pcm, 0, pcm.size) == pcm.size)
                        pcm.fill(0)
                        track.play()
                        result.success(null)
                    }
                    "pause" -> { audio?.pause(); result.success(null) }
                    "resume" -> { require(playbackForeground && !isFinishing); audio?.play(); result.success(null) }
                    "stop" -> { stopAudio(); result.success(null) }
                    "state" -> {
                        val track = audio
                        val frames = track?.playbackHeadPosition ?: 0
                        val playing = track?.playState == AudioTrack.PLAYSTATE_PLAYING && frames < audioFrames
                        if (track != null && frames >= audioFrames) stopAudio()
                        result.success(mapOf("milliseconds" to frames / 16, "playing" to playing))
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                stopAudio()
                result.error("playback_failed", "Audio playback is unavailable", null)
            }
        }
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
        stopAudio()
        cryptoWorker.shutdown()
        super.onDestroy()
    }
    override fun onPause() {
        playbackForeground = false
        stopAudio()
        super.onPause()
    }
    override fun onResume() {
        super.onResume()
        playbackForeground = true
    }
}
