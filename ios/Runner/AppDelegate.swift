import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var screenLockChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Tells Dart when the device locks, so the vault locks with it. iOS only
    // sends this with a passcode set; without one the idle timer still applies.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenLock") else { return }
    screenLockChannel = FlutterMethodChannel(
      name: "archespace/screen_lock", binaryMessenger: registrar.messenger())
    NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.screenLockChannel?.invokeMethod("locked", arguments: nil)
    }
  }
}
