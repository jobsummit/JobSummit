package com.examtracker.exam_tracker

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.PersistableBundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sounds: SoundPool? = null
    private val soundIds = mutableMapOf<String, Int>()
    private var shareChannel: MethodChannel? = null
    private var pendingShare: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // A job shared to the app: Dart takes the one that opened it, and hears of later ones.
        pendingShare = sharedText(intent)
        shareChannel = MethodChannel(messenger, "jobsummit/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "take") return@setMethodCallHandler result.notImplemented()
                result.success(pendingShare)
                pendingShare = null
            }
        }

        // Copies a password marked "sensitive": Android 13+ shows no preview of it, and
        // keyboards (Gboard and others) keep it out of their clipboard history.
        MethodChannel(messenger, "jobsummit/clipboard").setMethodCallHandler { call, result ->
            if (call.method != "copySensitive") return@setMethodCallHandler result.notImplemented()
            val text = call.argument<String>("text") ?: return@setMethodCallHandler result.error("no_text", null, null)
            val clip = ClipData.newPlainText("JobSummit", text)
            clip.description.extras = PersistableBundle().apply {
                // ClipDescription.EXTRA_IS_SENSITIVE (Android 13); keyboards read the same key earlier too.
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
            getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
            result.success(null)
        }

        // Short sound effects (res/raw/fx_*.wav, made by tool/make_sounds.py). Played as
        // UI sounds: they never take audio focus, so music keeps playing, and only when
        // the phone is on ring (silent and vibrate mean silent).
        val pool = SoundPool.Builder()
            .setMaxStreams(3)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .build()
        sounds = pool
        for ((name, res) in listOf(
            "fx_pop" to R.raw.fx_pop,
            "fx_success" to R.raw.fx_success,
            "fx_levelup" to R.raw.fx_levelup,
            "fx_tap" to R.raw.fx_tap,
            "fx_swoosh" to R.raw.fx_swoosh,
            "fx_soft_error" to R.raw.fx_soft_error,
        )) {
            soundIds[name] = pool.load(this, res, 1)
        }
        MethodChannel(messenger, "jobsummit/fx").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val id = soundIds[call.argument<String>("name")]
                    val ring = getSystemService(AudioManager::class.java)?.ringerMode == AudioManager.RINGER_MODE_NORMAL
                    if (id != null && ring) pool.play(id, 1f, 1f, 1, 0, 1f)
                    result.success(id != null && ring)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedText(intent) ?: return
        val channel = shareChannel
        if (channel == null) pendingShare = text else channel.invokeMethod("shared", text)
    }

    private fun sharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return null
        val parts = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getStringExtra(Intent.EXTRA_TEXT))
        return parts.joinToString("\n").takeIf { it.isNotBlank() }?.take(4000)
    }

    override fun onDestroy() {
        sounds?.release()
        sounds = null
        super.onDestroy()
    }
}
