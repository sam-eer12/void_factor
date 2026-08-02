import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let healthObserver = HealthObserver()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Obtain a binary messenger via a plugin registrar (no dependency on the
    // root view controller under the implicit-engine lifecycle).
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HealthObserver")
    guard let messenger = registrar?.messenger() else { return }

    let eventChannel = FlutterEventChannel(
      name: "app/health_observer/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(healthObserver)

    let methodChannel = FlutterMethodChannel(
      name: "app/health_observer", binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startObservers":
        self?.healthObserver.start()
        result(nil)
      case "stopObservers":
        self?.healthObserver.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
