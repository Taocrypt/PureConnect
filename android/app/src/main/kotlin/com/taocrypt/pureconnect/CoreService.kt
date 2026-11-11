package com.taocrypt.pureconnect

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LocalServerSocket
import android.net.NetworkCapabilities
import android.net.LocalSocket
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * Foreground service that owns the zjuconnect-core process.
 *
 * The core binary ships as `jniLibs/<abi>/libzjuconnect_core.so` and is
 * exec()'d from nativeLibraryDir. Its stdout (JSON lines) is forwarded to the
 * UI through [CoreBus]; in VPN mode the service answers the core's
 * `tun_request` by building the TUN interface and passing its fd over an
 * abstract unix socket (SCM_RIGHTS).
 */
class CoreService : VpnService() {

    companion object {
        const val ACTION_START = "com.taocrypt.pureconnect.START"
        const val ACTION_STOP = "com.taocrypt.pureconnect.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_VPN = "vpn"
        const val EXTRA_WORK_DIR = "workDir"
        private const val CHANNEL = "core"
        private const val NOTIFY_ID = 1

        @Volatile
        var instance: CoreService? = null
            private set

        fun start(ctx: Context, config: String, vpn: Boolean, workDir: String) {
            val i = Intent(ctx, CoreService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, config)
                .putExtra(EXTRA_VPN, vpn)
                .putExtra(EXTRA_WORK_DIR, workDir)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            instance?.stopCore() ?: CoreBus.emit("""{"type":"state","state":"stopped"}""")
        }

        const val ACTION_PROBE = "com.taocrypt.pureconnect.PROBE"
        private val probes = java.util.concurrent.ConcurrentHashMap<Long, (Map<String, Any?>) -> Unit>()
        private val probeIds = java.util.concurrent.atomic.AtomicLong()

        /** See [probeOwner]; [cb] runs on a background thread. */
        fun probeProxyOwner(ctx: Context, port: Int, cb: (Map<String, Any?>) -> Unit) {
            val id = probeIds.incrementAndGet()
            probes[id] = cb
            ctx.startService(Intent(ctx, CoreService::class.java)
                .setAction(ACTION_PROBE).putExtra("port", port).putExtra("id", id))
        }

        fun coreBinary(ctx: Context) = File(ctx.applicationInfo.nativeLibraryDir, "libzjuconnect_core.so")
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var process: Process? = null
    private var writer: BufferedWriter? = null
    private var tun: ParcelFileDescriptor? = null
    private var fdServer: LocalServerSocket? = null
    private var job: Job? = null
    /** A start requested while the previous session was still shutting down. */
    private var pendingStart: Triple<String, Boolean, String>? = null
    private var bypassApps: List<String> = emptyList()
    // Notification contents while connected.
    private var profileLabel = ""
    private var serverLabel = ""
    private var virtualIp = ""
    @Volatile private var connected = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForegroundCompat(getString(R.string.notify_connecting))
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: "{}"
                val vpn = intent.getBooleanExtra(EXTRA_VPN, false)
                val workDir = intent.getStringExtra(EXTRA_WORK_DIR) ?: filesDir.absolutePath
                if (job?.isActive == true) {
                    pendingStart = Triple(config, vpn, workDir)
                    if (process != null) stopCore()
                } else {
                    job = scope.launch { runCore(config, vpn, workDir) }
                }
            }
            ACTION_STOP -> { pendingStart = null; stopCore() }
            ACTION_PROBE -> {
                val port = intent.getIntExtra("port", 0)
                val id = intent.getLongExtra("id", 0)
                scope.launch {
                    val r = probeOwner(port)
                    probes.remove(id)?.invoke(r)
                    // Started only for the probe: go away again.
                    if (process == null && job?.isActive != true) stopSelf()
                }
            }
            else -> stopSelf() // restarted by the system without a request
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        // Another VPN took over or the user revoked the permission.
        stopCore()
    }

    override fun onDestroy() {
        stopCore()
        scope.cancel()
        instance = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------------

    /** DNS of the underlying (non-VPN) network: another VPN's DNS dies once we take over. */
    private fun systemDns(): String? {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        val nets = listOfNotNull(cm.activeNetwork) + cm.allNetworks.toList()
        val net = nets.firstOrNull { n ->
            val c = cm.getNetworkCapabilities(n)
            c != null && !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } ?: cm.activeNetwork ?: return null
        val lp = cm.getLinkProperties(net) ?: return null
        return lp.dnsServers.firstOrNull { it is Inet4Address }?.hostAddress
            ?: lp.dnsServers.firstOrNull()?.hostAddress
    }

    private fun otherVpnActive(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return false
        @Suppress("DEPRECATION")
        return cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
    }

    /**
     * Android allows one VPN at a time. If another VPN is up, the core would
     * log in through it and then lose those sockets the moment our TUN
     * replaces it, so the first connect fails. Take over first with a
     * throw-away interface (this revokes the other VPN), close it, and wait
     * until traffic flows over the physical network again.
     */
    private fun takeOverOtherVpn() {
        if (!otherVpnActive()) return
        CoreBus.raw("Another VPN is active; taking over before login", "warn")
        try {
            Builder().setSession("PureConnect (takeover)")
                .addAddress("10.255.255.254", 32)
                .setBlocking(false)
                .establish()?.close()
        } catch (e: Exception) {
            CoreBus.raw("VPN takeover failed: $e", "warn")
            return
        }
        val deadline = System.currentTimeMillis() + 4000
        while (otherVpnActive() && System.currentTimeMillis() < deadline) Thread.sleep(100)
        Thread.sleep(300) // let the default network and DNS settle
    }

    /**
     * Which app listens on 127.0.0.1:[port] (the external proxy)? Its own
     * outbound traffic must stay outside our VPN, or every connection loops
     * proxy -> VPN -> proxy. Android only tells the active VPN owner who owns
     * a socket (getConnectionOwnerUid, API 29+), so when our tunnel is not up
     * bring up a throw-away interface, connect, and look up the accepting side.
     * Result: status = found | not_found | other_vpn | no_permission |
     * unsupported | unreachable | error, plus package/label/message.
     */
    private fun probeOwner(port: Int): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return mapOf("status" to "unsupported")
        val cm = getSystemService(ConnectivityManager::class.java) ?: return mapOf("status" to "error", "message" to "no ConnectivityManager")
        // Our real tunnel excludes this app, and Android answers only callers
        // the VPN applies to, so the lookup needs the throw-away interface.
        if (tun != null) return mapOf("status" to "vpn_running")
        // Bringing up any VPN would stop another app's VPN (and a Clash in
        // VPN mode with it), so refuse instead of breaking it.
        if (otherVpnActive()) return mapOf("status" to "other_vpn")
        if (prepare(this) != null) return mapOf("status" to "no_permission")
        var probe: ParcelFileDescriptor? = null
        val diag = StringBuilder()
        return try {
            probe = Builder().setSession("PureConnect (probe)")
                .addAddress("10.255.255.253", 32)
                .addRoute("10.255.255.254", 32)
                .setBlocking(false)
                .establish() ?: return mapOf("status" to "no_permission")
            // establish() returns before ConnectivityService registers the
            // network; until then the owner lookup always says INVALID_UID.
            val registered = waitForOwnVpn(cm, 3000)
            diag.append("vpn=").append(if (registered) "up" else "timeout")
            Socket().use { sock ->
                try {
                    sock.connect(InetSocketAddress("127.0.0.1", port), 1500)
                } catch (e: Exception) {
                    return mapOf("status" to "unreachable", "message" to e.message)
                }
                val ours = sock.localSocketAddress as InetSocketAddress
                val theirs = InetSocketAddress(InetAddress.getByName("127.0.0.1"), port)
                val mapped = InetAddress.getByAddress(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, -1, 127, 0, 0, 1))
                val ours6 = InetSocketAddress(mapped, ours.port)
                val theirs6 = InetSocketAddress(mapped, port)
                val tuples = listOf(theirs to ours, ours to theirs, theirs6 to ours6, ours6 to theirs6)
                val ipproto = android.system.OsConstants.IPPROTO_TCP
                var uid = android.os.Process.INVALID_UID
                attempts@ for (attempt in 0 until 6) {
                    for ((l, r) in tuples) {
                        val u = try {
                            cm.getConnectionOwnerUid(ipproto, l, r)
                        } catch (e: Exception) {
                            if (attempt == 0) diag.append(" ex=").append(e.javaClass.simpleName).append(':').append(e.message)
                            android.os.Process.INVALID_UID
                        }
                        if (u != android.os.Process.INVALID_UID && u != android.os.Process.myUid()) { uid = u; break@attempts }
                        if (u == android.os.Process.myUid() && attempt == 0) diag.append(" self")
                    }
                    Thread.sleep(250)
                }
                diag.append(" sdk=").append(Build.VERSION.SDK_INT)
                if (uid == android.os.Process.INVALID_UID) return mapOf("status" to "not_found", "message" to diag.toString())
                val pkg = packageManager.getPackagesForUid(uid)?.firstOrNull()
                    ?: return mapOf("status" to "not_found", "message" to "uid $uid (no package visible) $diag")
                val label = runCatching {
                    packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
                }.getOrDefault(pkg)
                mapOf("status" to "found", "package" to pkg, "label" to label)
            }
        } catch (e: Exception) {
            mapOf("status" to "error", "message" to e.toString())
        } finally {
            runCatching { probe?.close() }
        }
    }

    /** Waits until our own VPN network is registered with ConnectivityService. */
    private fun waitForOwnVpn(cm: ConnectivityManager, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            @Suppress("DEPRECATION")
            val up = cm.allNetworks.any { n ->
                val c = cm.getNetworkCapabilities(n) ?: return@any false
                c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || c.ownerUid == android.os.Process.myUid())
            }
            if (up) return true
            Thread.sleep(100)
        }
        return false
    }

    private fun runCore(configJson: String, vpn: Boolean, workDir: String) {
        val bin = coreBinary(this)
        if (!bin.exists()) {
            CoreBus.emit(JSONObject().put("type", "state").put("state", "error")
                .put("error", "core binary missing: ${bin.absolutePath} (ABI not bundled?)").toString())
            CoreBus.emit("""{"type":"exit","code":127}""")
            finish()
            return
        }
        if (vpn) takeOverOtherVpn()
        val config = JSONObject(configJson)
        // App-only key: packages kept out of the VPN (the front proxy app, so
        // its own outbound traffic does not loop back into our tunnel).
        bypassApps = config.optJSONArray("android_bypass_apps")?.let { a ->
            (0 until a.length()).map { a.getString(it) }.filter { it.isNotBlank() }
        } ?: emptyList()
        config.remove("android_bypass_apps")
        profileLabel = config.optString("android_profile_label")
        config.remove("android_profile_label")
        serverLabel = config.optString("server_address").let { h ->
            val port = config.optInt("server_port", 0)
            if (h.isNotEmpty() && port > 0 && port != 443) "$h:$port" else h
        }
        virtualIp = ""
        connected = false
        // The core is a static Go binary without Android's resolver; give its
        // underlay dialer the current network's DNS server explicitly.
        if (config.optString("local_dns_server").isEmpty()) {
            systemDns()?.let { config.put("local_dns_server", it) }
        }

        val socketName = "zjuconnect-tun-${android.os.Process.myPid()}-${System.nanoTime()}"
        if (vpn) fdServer = LocalServerSocket(socketName)

        val proc = try {
            ProcessBuilder(bin.absolutePath).directory(File(workDir)).start()
        } catch (e: Exception) {
            CoreBus.emit(JSONObject().put("type", "state").put("state", "error").put("error", e.toString()).toString())
            CoreBus.emit("""{"type":"exit","code":126}""")
            finish()
            return
        }
        process = proc
        writer = proc.outputStream.bufferedWriter()

        scope.launch {
            proc.errorStream.bufferedReader().forEachLine { if (it.isNotBlank()) CoreBus.raw(it, if ("panic" in it) "error" else "info") }
        }

        send(JSONObject()
            .put("cmd", "start")
            .put("config", config)
            .put("tun", if (vpn) "android_fd" else "none")
            .put("tun_fd_socket", socketName)
            .put("work_dir", workDir)
            .toString())

        proc.inputStream.bufferedReader().forEachLine { line ->
            CoreBus.emit(line)
            val ev = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
            when (ev.optString("type")) {
                "tun_request" -> scope.launch { establishTun(ev.optJSONObject("session")) }
                "state" -> when (ev.optString("state")) {
                    "connected" -> { connected = true; showConnected(0, 0, 0, 0) }
                    "error" -> {
                        connected = false
                        // Kicked by a sign-in on another device: say so even
                        // when no UI is around (the core then stops itself).
                        if (ev.optString("error").contains("kicked offline")) showKicked()
                    }
                    "stopping", "stopped" -> connected = false
                }
                "session" -> ev.optJSONObject("session")?.optString("ip")?.let {
                    if (it.isNotEmpty()) {
                        virtualIp = it
                        if (connected) showConnected(0, 0, 0, 0)
                    }
                }
                "traffic" -> if (connected) ev.optJSONObject("traffic")?.let { t ->
                    showConnected(t.optLong("tx"), t.optLong("rx"), t.optLong("tx_rate"), t.optLong("rx_rate"))
                }
            }
        }
        val code = runCatching { proc.waitFor() }.getOrDefault(-1)
        CoreBus.emit("""{"type":"exit","code":$code}""")
        finish()
    }

    /**
     * Keeps the phone's own LAN (e.g. a campus Wi-Fi on 10.x) out of the
     * tunnel even when a route such as 10.0.0.0/8 covers it: sending gateway
     * or LAN DNS traffic to the VPN server gets the session SHUTDOWN.
     * excludeRoute needs Android 13+; older versions keep the routes as is.
     */
    private fun excludeLocalNetworks(b: Builder) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        @Suppress("DEPRECATION")
        val networks = cm.allNetworks
        for (n in networks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            for (la in lp.linkAddresses) {
                val addr = la.address
                if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                runCatching { b.excludeRoute(android.net.IpPrefix(addr, la.prefixLength)) }
                    .onSuccess { CoreBus.raw("keep local network ${addr.hostAddress}/${la.prefixLength} outside VPN", "info") }
            }
        }
    }

    private fun establishTun(session: JSONObject?) {
        if (session == null) return
        try {
            val b = Builder()
                .setSession("PureConnect")
                .setMtu(session.optInt("mtu", 1400).takeIf { it > 0 } ?: 1400)
                .addAddress(session.getString("ip"), 32)
            val routes = session.optJSONArray("routes")
            if (routes != null) for (i in 0 until routes.length()) {
                val (addr, prefix) = routes.getString(i).split("/").let { it[0] to (it.getOrNull(1)?.toInt() ?: 32) }
                runCatching { b.addRoute(addr, prefix) }
                    .onFailure { CoreBus.raw("skip route ${routes.getString(i)}: ${it.message}", "warning") }
            }
            excludeLocalNetworks(b)
            for (key in listOf("dns_server", "secondary_dns")) {
                val dns = session.optString(key)
                if (dns.isNotEmpty() && isIpLiteral(dns)) runCatching { b.addDnsServer(dns) }
            }
            // The core's own sockets (to the VPN server) must not loop back
            // into the tunnel: exclude this app's UID from the VPN.
            b.addDisallowedApplication(packageName)
            for (pkg in bypassApps) {
                runCatching { b.addDisallowedApplication(pkg) }
                    .onSuccess { CoreBus.raw("bypass VPN: $pkg", "info") }
            }
            if (session.optBoolean("full_takeover")) {
                // Let the system know traffic still flows through the VPN.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
            }
            val pfd = b.establish() ?: error("VpnService.establish() returned null (permission revoked?)")
            tun = pfd

            val server = fdServer ?: error("fd socket not ready")
            // accept() is blocking and not cancellable: close the server socket
            // if the core never shows up.
            val watchdog = scope.launch {
                delay(30_000)
                runCatching { server.close() }
            }
            val client: LocalSocket = try {
                server.accept()
            } catch (e: Exception) {
                error("core did not connect to the fd socket")
            } finally {
                watchdog.cancel()
            }
            client.use {
                it.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
                it.outputStream.write(1)
                it.outputStream.flush()
            }
            CoreBus.raw("TUN established (${session.optString("ip")}, ${routes?.length() ?: 0} routes)")
        } catch (e: Exception) {
            CoreBus.emit(JSONObject().put("type", "state").put("state", "error").put("error", "TUN: ${e.message}").toString())
            stopCore()
        }
    }

    private fun isIpLiteral(s: String) =
        s.matches(Regex("""^\d{1,3}(\.\d{1,3}){3}$""")) || (s.contains(':') && runCatching { InetAddress.getByName(s) }.isSuccess)

    fun send(line: String) {
        val w = writer ?: return
        try {
            synchronized(w) {
                w.write(line)
                w.newLine()
                w.flush()
            }
        } catch (_: Exception) {
        }
    }

    fun stopCore() {
        val proc = process
        if (proc == null) {
            finish()
            return
        }
        scope.launch {
            send("""{"cmd":"stop"}""")
            if (!proc.waitFor(6, TimeUnit.SECONDS)) proc.destroyForcibly()
        }
    }

    private fun finish() {
        runCatching { tun?.close() }
        tun = null
        runCatching { fdServer?.close() }
        fdServer = null
        process = null
        writer = null
        val next = pendingStart
        if (next != null) {
            pendingStart = null
            val prev = job
            job = scope.launch {
                prev?.join()
                runCore(next.first, next.second, next.third)
            }
            return
        }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ---------------------------------------------------------------------

    private fun notification(text: String, title: String = "PureConnect", sub: String? = null): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "PureConnect", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, CoreService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setSubText(sub)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.notify_stop), stop)
            .build()
    }

    private fun showKicked() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(MainActivity.ALERT_CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(
                MainActivity.ALERT_CHANNEL, getString(R.string.notify_alerts), NotificationManager.IMPORTANCE_DEFAULT))
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val open = PendingIntent.getActivity(this, 3, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val text = getString(R.string.notify_kicked)
        nm.notify(MainActivity.ALERT_ID, NotificationCompat.Builder(this, MainActivity.ALERT_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("PureConnect")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(open)
            .build())
    }

    private fun startForegroundCompat(text: String) {
        ServiceCompat.startForeground(this, NOTIFY_ID, notification(text),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
    }

    private fun updateNotification(text: String, title: String = "PureConnect", sub: String? = null) {
        getSystemService(NotificationManager::class.java).notify(NOTIFY_ID, notification(text, title, sub))
    }

    /** Connected: profile + server as the title, live rates and totals below. */
    private fun showConnected(tx: Long, rx: Long, txRate: Long, rxRate: Long) {
        val name = profileLabel.ifEmpty { serverLabel }
        val title = getString(R.string.notify_connected, name)
        val text = "↑ ${fmtBytes(txRate)}/s  ↓ ${fmtBytes(rxRate)}/s · " +
            getString(R.string.notify_total, fmtBytes(tx), fmtBytes(rx))
        val sub = listOf(serverLabel.takeIf { it != name }, virtualIp)
            .filter { !it.isNullOrEmpty() }.joinToString(" · ").ifEmpty { null }
        updateNotification(text, title, sub)
    }

    private fun fmtBytes(b: Long): String {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var v = b.toDouble()
        var i = 0
        while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
        return if (i == 0) "${v.toLong()} B" else String.format(java.util.Locale.US, if (v >= 100) "%.0f %s" else "%.1f %s", v, units[i])
    }
}
