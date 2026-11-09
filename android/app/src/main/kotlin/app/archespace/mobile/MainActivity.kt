package app.archespace.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so the
// biometric prompt can attach to a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var screenOff: BroadcastReceiver? = null

    // Tells Dart when the screen turns off, so the vault locks with the device.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "archespace/screen_lock")
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                channel.invokeMethod("locked", null)
            }
        }
        // A system broadcast, so no exported flag is needed.
        registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
        screenOff = receiver
    }

    override fun onDestroy() {
        screenOff?.let { unregisterReceiver(it) }
        screenOff = null
        super.onDestroy()
    }
}
