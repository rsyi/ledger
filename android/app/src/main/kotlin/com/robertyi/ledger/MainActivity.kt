package com.robertyi.ledger

// FlutterFragmentActivity (a ComponentActivity), not FlutterActivity:
// the health plugin registers Health Connect's permission-request
// ActivityResultContract, which needs a ComponentActivity host.
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

// Video frame sampling for the strength form's AI RPE estimate.
//
// A small MediaMetadataRetriever channel instead of the video_thumbnail
// plugin: the plugin wraps the exact same Android API but only exposes
// one-frame-per-call, and this repo has been burned by plugin version
// pins (health 13.3.1, google_sign_in 7.2.0) — a dependency-free
// channel keeps frame count/size/quality fully under our control.
// Dart side: services/video_frames.dart.
class MainActivity : FlutterFragmentActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // --- Stale keyboard-inset resync (the "screen cut off on return" bug) ---
    //
    // Flutter's TextInputPlugin installs ImeSyncDeferringInsetsCallback on
    // the FlutterView (API 30+). It sets `animating = true` in an IME
    // animation's onPrepare and clears it ONLY in onEnd; while set, its
    // OnApplyWindowInsetsListener returns CONSUMED for every insets
    // dispatch. When the activity is backgrounded mid IME animation
    // (switching apps with a keyboard up, or leaving right after popping
    // the log form with the keyboard open) onEnd can be skipped, the flag
    // sticks, and Flutter keeps the last keyboard height as
    // MediaQuery.viewInsets.bottom — every resizeToAvoidBottomInset
    // Scaffold stays shrunk ("cut off") until some later IME animation
    // happens to complete ("sometimes it fixes itself").
    //
    // Fix: when the window regains focus, push the window's CURRENT insets
    // straight into FlutterView.onApplyWindowInsets — the same bypass the
    // callback itself uses in onProgress/onEnd — so a stuck listener can't
    // swallow them. Idempotent: with nothing stuck it re-sends the same
    // metrics. Re-run once shortly after, for an IME hide that settles late.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val decor = window?.decorView ?: return
        decor.post { resyncInsets(decor) }
        decor.postDelayed({ resyncInsets(decor) }, 350L)
    }

    private fun resyncInsets(decor: View) {
        val fv = findFlutterView(decor) ?: return
        val insets = fv.rootWindowInsets ?: return
        fv.onApplyWindowInsets(insets)
    }

    private fun findFlutterView(v: View): FlutterView? {
        if (v is FlutterView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                findFlutterView(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.robertyi.fitness/video_frames",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("args", "probe needs a path", null)
                    } else {
                        runOffMain(result) {
                            val r = MediaMetadataRetriever()
                            try {
                                r.setDataSource(path)
                                val ms = r.extractMetadata(
                                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                                )?.toLongOrNull() ?: 0L
                                mapOf("durationMs" to ms)
                            } finally {
                                r.release()
                            }
                        }
                    }
                }
                "frames" -> {
                    val path = call.argument<String>("path")
                    val timestamps = call.argument<List<Number>>("timestampsMs")
                    val maxWidth = call.argument<Int>("maxWidth") ?: 512
                    val quality = call.argument<Int>("quality") ?: 70
                    if (path == null || timestamps == null) {
                        result.error("args", "frames needs path + timestampsMs", null)
                    } else {
                        runOffMain(result) {
                            val r = MediaMetadataRetriever()
                            try {
                                r.setDataSource(path)
                                val out = ArrayList<ByteArray>()
                                for (ts in timestamps) {
                                    // OPTION_CLOSEST = exact frame (not just the
                                    // nearest sync frame) — bar-position spacing
                                    // at equal time steps is the velocity signal.
                                    val bmp = r.getFrameAtTime(
                                        ts.toLong() * 1000L,
                                        MediaMetadataRetriever.OPTION_CLOSEST,
                                    ) ?: continue
                                    val scaled = if (bmp.width > maxWidth) {
                                        val h = bmp.height * maxWidth / bmp.width
                                        Bitmap.createScaledBitmap(bmp, maxWidth, h, true)
                                    } else {
                                        bmp
                                    }
                                    val baos = ByteArrayOutputStream()
                                    scaled.compress(
                                        Bitmap.CompressFormat.JPEG, quality, baos,
                                    )
                                    out.add(baos.toByteArray())
                                }
                                out
                            } finally {
                                r.release()
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Frame extraction takes seconds on a long clip — never block the
    // platform thread; MethodChannel results must be posted back to it.
    private fun runOffMain(result: MethodChannel.Result, body: () -> Any?) {
        executor.execute {
            try {
                val value = body()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("video_frames", e.message ?: "$e", null)
                }
            }
        }
    }
}
