package app.archespace.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so the
// biometric prompt can attach to a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var screenOff: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Tells Dart when the screen turns off, so the vault locks with the device.
        val channel = MethodChannel(messenger, "archespace/screen_lock")
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                channel.invokeMethod("locked", null)
            }
        }
        // A system broadcast, so no exported flag is needed.
        registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
        screenOff = receiver

        // In-app updates (app_updater.dart): which APK fits this phone, the
        // "install unknown apps" permission, and handing the APK to the installer.
        MethodChannel(messenger, "archespace/updates").setMethodCallHandler { call, result ->
            when (call.method) {
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        packageManager.canRequestPackageInstalls()
                )
                "openInstallSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                    )
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "No APK path", null)
                    } else {
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        )
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        screenOff?.let { unregisterReceiver(it) }
        screenOff = null
        super.onDestroy()
    }
}
