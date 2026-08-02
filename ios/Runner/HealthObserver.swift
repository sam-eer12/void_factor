import Foundation
import HealthKit
import Flutter

/// Registers HKObserverQuery + background delivery for steps, water, and
/// workouts, and emits a (payload-free) "changed" event to Dart whenever
/// HealthKit reports new data. The Dart side responds by re-reading totals.
///
/// Wired to two channels in `AppDelegate`:
///   - method  `app/health_observer`         → startObservers / stopObservers
///   - event   `app/health_observer/events`  → data-changed pings
class HealthObserver: NSObject, FlutterStreamHandler {
  private let store = HKHealthStore()
  private var eventSink: FlutterEventSink?
  private var queries: [HKObserverQuery] = []

  private var sampleTypes: [HKSampleType] {
    var types: [HKSampleType] = []
    if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
      types.append(steps)
    }
    if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) {
      types.append(water)
    }
    types.append(HKObjectType.workoutType())
    return types
  }

  func start() {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    stop()
    for type in sampleTypes {
      let query = HKObserverQuery(sampleType: type, predicate: nil) {
        [weak self] _, completionHandler, _ in
        DispatchQueue.main.async { self?.eventSink?(nil) }
        // Signal HealthKit that the background delivery was handled.
        completionHandler()
      }
      store.execute(query)
      queries.append(query)
      store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }
  }

  func stop() {
    for q in queries { store.stop(q) }
    queries.removeAll()
    for type in sampleTypes {
      store.disableBackgroundDelivery(for: type) { _, _ in }
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
