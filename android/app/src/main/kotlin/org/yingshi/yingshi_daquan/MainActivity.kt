package org.yingshi.yingshi_daquan

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 电视端白屏防护 + U 盘配置扫描（原生读文件，避免 Dart 侧权限/挂载点漏扫）
 */
class MainActivity : FlutterActivity() {
    @Volatile
    private var flutterUiDisplayed = false

    private var permissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setBackgroundDrawableResource(R.color.launch_background)
        super.onCreate(savedInstanceState)
        Handler(Looper.getMainLooper()).postDelayed({
            flutterUiDisplayed = true
        }, 8000)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listStorageRoots" -> result.success(listStorageRoots())
                "requestReadPermission" -> requestReadPermission(result)
                "scanConfigJson" -> result.success(scanConfigJson())
                else -> result.notImplemented()
            }
        }
    }

    /** 在各存储卷根目录找配置 JSON，直接返回文本 */
    private fun scanConfigJson(): Map<String, Any?> {
        val roots = listStorageRoots()
        val preferredNames = listOf(
            "veliora-sources.json",
            "veliora-sources.txt",
            "veliora-config.json",
            "veliora-settings.json",
            "sources.json",
            "yingshi-sources.json",
            "影视大全-sources.json",
        )
        val tried = mutableListOf<String>()
        for (root in roots) {
            tried.add(root)
            val dir = File(root)
            // 1) 精确文件名
            for (name in preferredNames) {
                val hit = readIfConfig(File(dir, name))
                if (hit != null) {
                    return mapOf(
                        "ok" to true,
                        "text" to hit.first,
                        "message" to "已读取：${hit.second}",
                        "roots" to roots,
                    )
                }
            }
            // 2) 根目录任意 .json / .txt（文件名含 sources/settings/config/veliora/yingshi）
            try {
                dir.listFiles()?.forEach { f ->
                    if (!f.isFile) return@forEach
                    val n = f.name.lowercase()
                    if (!(n.endsWith(".json") || n.endsWith(".txt"))) return@forEach
                    val nameHit = n.contains("source") ||
                        n.contains("setting") ||
                        n.contains("config") ||
                        n.contains("veliora") ||
                        n.contains("yingshi") ||
                        n.contains("libretv") ||
                        n == "sources.json"
                    if (!nameHit && !n.endsWith(".json")) return@forEach
                    // 根目录的任意 json 也试读（用户常直接丢一个 json）
                    if (n.endsWith(".json") || nameHit) {
                        val hit = readIfConfig(f)
                        if (hit != null) {
                            return mapOf(
                                "ok" to true,
                                "text" to hit.first,
                                "message" to "已读取：${hit.second}",
                                "roots" to roots,
                            )
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        return mapOf(
            "ok" to false,
            "text" to null,
            "message" to "已扫 ${roots.size} 个目录仍未找到。请确认电视已识别 U 盘，并把 veliora-sources.json 放在 U 盘根目录。扫描路径：${roots.joinToString(" | ")}",
            "roots" to roots,
        )
    }

    private fun readIfConfig(file: File): Pair<String, String>? {
        return try {
            if (!file.exists() || !file.isFile) return null
            val text = file.readText(Charsets.UTF_8)
            if (text.length > 10 * 1024 * 1024) return null
            if (!looksLikeConfig(text)) return null
            Pair(text, file.absolutePath)
        } catch (_: Exception) {
            null
        }
    }

    private fun looksLikeConfig(text: String): Boolean {
        val t = text.trim()
        if (!t.startsWith("{")) return false
        return t.contains("Veliora-Settings") ||
            t.contains("LibreTV-Settings") ||
            t.contains("\"sources\"") ||
            t.contains("customAPIs") ||
            t.contains("Veliora-Sources")
    }

    private fun listStorageRoots(): List<String> {
        val paths = linkedSetOf<String>()

        // StorageVolume（含可移动卷）
        try {
            val sm = getSystemService(STORAGE_SERVICE) as StorageManager
            for (vol in sm.storageVolumes) {
                val dir = volumeDirectory(vol) ?: continue
                val path = dir.absolutePath
                // 主存储也加：部分盒子把 U 盘映射得很怪
                paths.add(path)
                // 可移动卷优先标记，稍后排序
            }
        } catch (_: Exception) {
        }

        // 常见挂载点（不管 canRead，存在就进列表，读文件时再试）
        val probes = listOf(
            "/storage",
            "/mnt/media_rw",
            "/mnt/usb",
            "/mnt/udisk",
            "/mnt/usb_storage",
            "/mnt/usbhost",
            "/mnt/usbotg",
            "/mnt/USB",
            "/mnt/external_sd",
            "/mnt/sdcard",
            "/mnt/sda1",
            "/mnt/sdb1",
            "/storage/usb",
            "/storage/usbotg",
            "/storage/udisk",
        )
        for (p in probes) {
            try {
                val f = File(p)
                if (!f.exists()) continue
                if (p == "/storage" || p == "/mnt/media_rw") {
                    f.listFiles()?.forEach { child ->
                        if (child.isDirectory) {
                            val name = child.name.lowercase()
                            if (name == "self") return@forEach
                            paths.add(child.absolutePath)
                        }
                    }
                } else {
                    paths.add(f.absolutePath)
                    f.listFiles()?.forEach { child ->
                        if (child.isDirectory) paths.add(child.absolutePath)
                    }
                }
            } catch (_: Exception) {
            }
        }

        try {
            @Suppress("DEPRECATION")
            val ext = Environment.getExternalStorageDirectory()
            if (ext != null) paths.add(ext.absolutePath)
        } catch (_: Exception) {
        }

        // 可移动 / 非 emulated 排前面
        return paths.sortedWith(
            compareBy<String> {
                val n = it.lowercase()
                when {
                    n.contains("emulated") -> 2
                    n.contains("usb") || n.contains("udisk") || n.contains("media_rw") -> 0
                    Regex("/storage/[0-9a-f]{4}-[0-9a-f]{4}", RegexOption.IGNORE_CASE).containsMatchIn(n) -> 0
                    else -> 1
                }
            },
        )
    }

    private fun volumeDirectory(vol: android.os.storage.StorageVolume): File? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                vol.directory
            } else {
                @Suppress("DEPRECATION")
                val path = vol.javaClass.getMethod("getPath").invoke(vol) as? String
                if (path.isNullOrBlank()) null else File(path)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun requestReadPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val need = Manifest.permission.READ_EXTERNAL_STORAGE
        if (ContextCompat.checkSelfPermission(this, need) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        permissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(need), REQ_READ)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_READ) return
        val ok = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(ok)
        permissionResult = null
    }

    override fun onFlutterUiDisplayed() {
        flutterUiDisplayed = true
        super.onFlutterUiDisplayed()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (!flutterUiDisplayed) {
            finish()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    companion object {
        private const val CHANNEL = "yingshi_daquan/storage"
        private const val REQ_READ = 9911
    }
}
