package com.taocrypt.pureconnect

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind transparent system bars (no grey scrim), Flutter pads with SafeArea.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        @Suppress("DEPRECATION")
        window.statusBarColor = Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        super.onCreate(savedInstanceState)
    }


    private var pendingStart: (() -> Unit)? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingProbe: ((Boolean) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "zju_connect/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                CoreBus.attach(events)
            }

            override fun onCancel(arguments: Any?) {
                CoreBus.attach(null)
            }
        })

        MethodChannel(messenger, "zju_connect/core").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("config") ?: "{}"
                    val vpn = call.argument<Boolean>("vpn") ?: false
                    val workDir = call.argument<String>("workDir") ?: filesDir.absolutePath
                    requestNotificationPermission()
                    val go = { CoreService.start(this, config, vpn, workDir) }
                    val prepare = if (vpn) VpnService.prepare(this) else null
                    if (prepare == null) {
                        go()
                        result.success(true)
                    } else {
                        pendingStart = go
                        pendingResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(prepare, REQ_VPN)
                    }
                }
                "stop" -> {
                    CoreService.stop(this)
                    result.success(null)
                }
                "send" -> {
                    CoreService.instance?.send(call.arguments as String)
                    result.success(null)
                }
                "replay" -> {
                    CoreBus.replay()
                    result.success(null)
                }
                "probeProxyOwner" -> {
                    val port = call.argument<Int>("port") ?: 0
                    val run = {
                        CoreService.probeProxyOwner(this, port) { r -> runOnUiThread { result.success(r) } }
                    }
                    val prepare = VpnService.prepare(this)
                    if (prepare == null || call.argument<Boolean>("askPermission") != true) {
                        run()
                    } else {
                        pendingProbe = { ok -> if (ok) run() else result.success(mapOf("status" to "no_permission")) }
                        @Suppress("DEPRECATION")
                        startActivityForResult(prepare, REQ_VPN_PROBE)
                    }
                }
                "oneShot" -> oneShot(call.arguments as String, result)
                "listApps" -> {
                    val browsers = call.argument<Boolean>("browsers") ?: false
                    ensureAppListPermission()
                    Thread {
                        val list = runCatching { listApps(browsers) }.getOrDefault(emptyList())
                        runOnUiThread { result.success(list) }
                    }.start()
                }
                "appIcon" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    Thread {
                        val png = runCatching { iconPng(pkg) }.getOrNull()
                        runOnUiThread { result.success(png) }
                    }.start()
                }
                "appLabel" -> result.success(runCatching {
                    val pkg = call.argument<String>("package") ?: ""
                    packageManager.getApplicationInfo(pkg, 0).loadLabel(packageManager).toString()
                }.getOrNull())
                "openUrl" -> {
                    val pkg = call.argument<String>("package")
                    val view = android.content.Intent(android.content.Intent.ACTION_VIEW,
                        android.net.Uri.parse(call.argument<String>("url") ?: ""))
                        .addCategory(android.content.Intent.CATEGORY_BROWSABLE)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (!pkg.isNullOrEmpty()) view.setPackage(pkg)
                    try {
                        startActivity(view)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "installApk" -> result.success(installApk(call.argument<String>("path") ?: ""))
                "launcherIcon" -> result.success(currentLauncherIcon())
                "setLauncherIcon" -> result.success(runCatching {
                    setLauncherIcon(call.arguments as String)
                }.isSuccess)
                "systemAccent" -> result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                        ContextCompat.getColor(this, android.R.color.system_accent1_500)
                    else null
                )
                else -> result.notImplemented()
            }
        }
    }

    /** Opens the system installer for a downloaded update. Returns "ok", or
     *  "need_permission" after sending the user to allow installs from this app. */
    private fun installApk(path: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                android.net.Uri.parse("package:$packageName"))
            runCatching { startActivity(settings) }
            return "need_permission"
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", java.io.File(path))
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return "ok"
    }

    /** Runs a short-lived core for `auth_info` / `trust_device`. */
    private fun oneShot(command: String, result: MethodChannel.Result) {
        thread {
            var answer: String? = null
            try {
                val proc = ProcessBuilder(CoreService.coreBinary(this).absolutePath).start()
                proc.outputStream.bufferedWriter().apply { write(command); newLine(); flush() }
                proc.inputStream.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        val t = runCatching { JSONObject(line).optString("type") }.getOrDefault("")
                        if (t == "result" || t == "auth_info") {
                            answer = line
                            break
                        }
                    }
                }
                proc.outputStream.close()
                if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroyForcibly()
            } catch (e: Exception) {
                answer = JSONObject().put("type", "result").put("error", e.toString()).toString()
            }
            runOnUiThread { result.success(answer) }
        }
    }

    /** Installed apps; [browsers] = only apps that open http(s) links. */
    private fun listApps(browsers: Boolean): List<Map<String, Any>> {
        val pm = packageManager
        if (browsers) {
            val probe = android.content.Intent(android.content.Intent.ACTION_VIEW,
                android.net.Uri.parse("https://example.com"))
                .addCategory(android.content.Intent.CATEGORY_BROWSABLE)
            @Suppress("DEPRECATION")
            val infos = pm.queryIntentActivities(probe, android.content.pm.PackageManager.MATCH_ALL)
            val seen = LinkedHashMap<String, String>()
            for (ri in infos) {
                val pkg = ri.activityInfo?.packageName ?: continue
                if (pkg == packageName || pkg in seen) continue
                seen[pkg] = ri.loadLabel(pm).toString()
            }
            return seen.map { (p, l) -> mapOf("package" to p, "label" to l, "system" to false) }
        }
        @Suppress("DEPRECATION")
        val apps = pm.getInstalledApplications(0)
        return apps.filter { it.packageName != packageName }.map { ai ->
            val system = (ai.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0 &&
                (ai.flags and android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
            mapOf("package" to ai.packageName, "label" to ai.loadLabel(pm).toString(), "system" to system)
        }
    }

    private fun iconPng(pkg: String): ByteArray {
        val d = packageManager.getApplicationIcon(pkg)
        val size = 96
        val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(c)
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    /** Some ROMs (MIUI/HyperOS, ColorOS…) gate the app list behind a runtime permission. */
    private fun ensureAppListPermission() {
        val perm = "com.android.permission.GET_INSTALLED_APPS"
        val supported = runCatching { packageManager.getPermissionInfo(perm, 0) }.isSuccess
        if (supported && checkSelfPermission(perm) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(perm), 0x5652)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN_PROBE) {
            pendingProbe?.invoke(resultCode == RESULT_OK)
            pendingProbe = null
        }
        if (requestCode == REQ_VPN) {
            val ok = resultCode == RESULT_OK
            if (ok) pendingStart?.invoke()
            pendingResult?.success(ok)
            pendingStart = null
            pendingResult = null
        }
    }

    private companion object {
        const val REQ_VPN = 0x5650
        const val REQ_VPN_PROBE = 0x5651
        const val REQ_NOTIFY = 0x4e54
    }

    private val launcherIcons = listOf("a1", "a2", "b1", "b2")

    private fun aliasFor(id: String) =
        android.content.ComponentName(this, "$packageName.Icon${id.uppercase()}")

    private fun currentLauncherIcon(): String = launcherIcons.firstOrNull {
        when (packageManager.getComponentEnabledSetting(aliasFor(it))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> it == "a1"
            else -> false
        }
    } ?: "a1"

    /** Enables the chosen launcher alias and disables the rest. The launcher
     *  may take a few seconds to refresh. */
    private fun setLauncherIcon(id: String) {
        require(id in launcherIcons) { "unknown icon $id" }
        if (currentLauncherIcon() == id) return
        // Enable the new one first so the app never has zero launcher entries.
        packageManager.setComponentEnabledSetting(
            aliasFor(id), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for (other in launcherIcons) if (other != id) {
            packageManager.setComponentEnabledSetting(
                aliasFor(other), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        }
    }
}
