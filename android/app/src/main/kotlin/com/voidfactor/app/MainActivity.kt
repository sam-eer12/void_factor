package com.voidfactor.app

import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var gemmaEngine: GemmaEngineDelivery? = null

    // Registered as a property so it exists before the activity is started,
    // which is the only time a launcher may be registered.
    private val engineConfirmation =
        registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
            gemmaEngine?.onConfirmationResult(it.resultCode)
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        gemmaEngine = GemmaEngineDelivery(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            engineConfirmation,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        gemmaEngine?.dispose()
        gemmaEngine = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
