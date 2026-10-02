package com.robertyi.ledger

// FlutterFragmentActivity (a ComponentActivity), not FlutterActivity:
// the health plugin registers Health Connect's permission-request
// ActivityResultContract, which needs a ComponentActivity host.
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
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
import java.io.File
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
                                setSource(r, path)
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
                                setSource(r, path)
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.robertyi.fitness/video_pick",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> startVideoPick(result)
                "copy" -> {
                    val uri = call.argument<String>("uri")
                    val dest = call.argument<String>("dest")
                    if (uri == null || dest == null) {
                        result.error("args", "copy needs uri + dest", null)
                    } else {
                        runOffMain(result) {
                            val out = File(dest)
                            out.parentFile?.mkdirs()
                            val tmp = File("$dest.part")
                            contentResolver.openInputStream(Uri.parse(uri)).use { input ->
                                requireNotNull(input) { "cannot open $uri" }
                                tmp.outputStream().use { input.copyTo(it) }
                            }
                            if (!tmp.renameTo(out)) error("rename failed: $dest")
                            null
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // --- Local video attach (strength form `widget: video`) ---
    //
    // The Android SYSTEM photo picker (ACTION_PICK_IMAGES, video only — no
    // runtime permission; on-device Google Photos clips show up there),
    // falling back to the document picker below API 33. The chosen URI's
    // read grant is PERSISTED so the row can keep referencing the local
    // clip across restarts; when Android refuses to persist it, Dart
    // copies the clip into app storage via "copy" while the one-shot
    // grant is still live. Replaces the Google Photos Picker API flow
    // whose ~60-min download URL kept expiring. Dart: video_attach.dart.
    private var pendingPick: MethodChannel.Result? = null

    private fun startVideoPick(result: MethodChannel.Result) {
        pendingPick?.error("superseded", "another pick started", null)
        pendingPick = result
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).setType("video/*")
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("video/*")
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                )
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_VIDEO)
        } catch (e: Exception) {
            pendingPick = null
            result.error("video_pick", e.message ?: "$e", null)
        }
    }

    @Deprecated("Activity-result API; the plugin-forwarding super still runs")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_PICK_VIDEO) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null) // cancelled
            return
        }
        val persisted = try {
            contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            true
        } catch (e: Exception) {
            false
        }
        var name: String? = null
        var size: Long? = null
        try {
            contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (e: Exception) { /* metadata is best-effort */ }
        result.success(
            mapOf(
                "uri" to uri.toString(),
                "persisted" to persisted,
                "mimeType" to contentResolver.getType(uri),
                "name" to name,
                "size" to size,
            ),
        )
    }

    // MediaMetadataRetriever reads a file path OR a content:// URI (local
    // video refs from the system picker) — no download either way.
    private fun setSource(r: MediaMetadataRetriever, path: String) {
        if (path.startsWith("content://")) {
            r.setDataSource(this, Uri.parse(path))
        } else if (path.startsWith("file://")) {
            r.setDataSource(Uri.parse(path).path)
        } else {
            r.setDataSource(path)
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

    companion object {
        private const val REQ_PICK_VIDEO = 0x7E0
    }
}
