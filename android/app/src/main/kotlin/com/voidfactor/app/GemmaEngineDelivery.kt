package com.voidfactor.app

import android.app.Activity
import android.content.Context
import android.os.StatFs
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallException
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallErrorCode
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import dalvik.system.BaseDexClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Installs the on-demand `gemma_engine` module and tells Dart where its
 * libraries are.
 *
 * Dart owns *when* (the user downloading the model); this owns *how*. The
 * channel is `void_factor/gemma_engine`:
 *
 * - `libraryPaths` — `null` when the engine is not installed; an empty list
 *   when it is in the base APK, where flutter_gemma finds it by name on its
 *   own; otherwise every library's path, in load order, for Dart to preload.
 * - `install` — completes when the module is installed, reporting
 *   `progress` back as `[bytesDownloaded, totalBytes]` along the way.
 * - `installing` — whether Play is still installing it, which after a restart
 *   means a download that outlived the process that asked for it.
 * - `deferredUninstall` — lets Play reclaim the module once the model is gone.
 * - `freeBytes` — space left where the model would be written.
 *
 * Why preloading is needed at all: flutter_gemma opens `libLiteRtLm.so` by
 * name, which only finds a library on the process's search path or one
 * already loaded. A split installed while the app runs is on neither, so Dart
 * loads each file by path first, in dependency order, and the plugin's later
 * by-name open finds them loaded.
 */
class GemmaEngineDelivery(
    activity: Activity,
    messenger: BinaryMessenger,
    private val confirmationLauncher: ActivityResultLauncher<IntentSenderRequest>,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "GemmaEngineDelivery"
        const val CHANNEL = "void_factor/gemma_engine"
        const val MODULE = "gemma_engine"

        /** In load order. Declared once, in android/app/build.gradle.kts. */
        private val LIBRARIES = BuildConfig.GEMMA_ENGINE_LIBS.split(",")
    }

    private val context: Context = activity.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val manager: SplitInstallManager = SplitInstallManagerFactory.create(context)

    /** The Dart call waiting on an install, answered exactly once by [finish]. */
    private var pending: MethodChannel.Result? = null
    private var sessionId: Int? = null
    private val listener = SplitInstallStateUpdatedListener(::onState)

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        manager.unregisterListener(listener)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "libraryPaths" -> result.success(libraryPaths())
            "install" -> install(result)
            "installing" -> manager.sessionStates
                .addOnSuccessListener { states ->
                    result.success(states.any { MODULE in it.moduleNames() && !it.isTerminal() })
                }
                .addOnFailureListener { result.success(false) }
            "deferredUninstall" -> {
                manager.deferredUninstall(listOf(MODULE))
                    .addOnCompleteListener { result.success(null) }
            }
            "freeBytes" -> result.success(StatFs(context.filesDir.path).availableBytes)
            else -> result.notImplemented()
        }
    }

    // ── Where the libraries are ────────────────────────────────────────────

    private fun libraryPaths(): List<String>? {
        var paths = resolve()
        if (paths.any { it == null } && MODULE in manager.installedModules) {
            // Installed, but not yet visible to this process's class loader.
            SplitCompat.install(context)
            paths = resolve()
        }
        if (paths.any { it == null }) return null

        val resolved = paths.filterNotNull()
        val info = context.applicationInfo
        val inBase = resolved.all {
            it.startsWith(info.sourceDir) || it.startsWith(info.nativeLibraryDir)
        }
        return if (inBase) emptyList() else resolved
    }

    private fun resolve(): List<String?> {
        val loader = context.classLoader as? BaseDexClassLoader
        return LIBRARIES.map { file ->
            val name = file.removePrefix("lib").removeSuffix(".so")
            loader?.findLibrary(name) ?: extractedCopy(file)
        }
    }

    /**
     * An emulated split's library as SplitCompat extracted it, for the case
     * where the class loader was not updated to point at it.
     */
    private fun extractedCopy(file: String): String? =
        File(context.filesDir, "splitcompat")
            .takeIf { it.isDirectory }
            ?.walkTopDown()
            ?.firstOrNull { it.isFile && it.name == file }
            ?.path

    // ── Installing ─────────────────────────────────────────────────────────

    private fun install(result: MethodChannel.Result) {
        if (libraryPaths() != null) {
            result.success(null)
            return
        }
        // One install at a time. A second caller takes over the wait rather
        // than starting a second session Play would refuse anyway.
        pending?.error("SUPERSEDED", "A newer install request took over", null)
        pending = result
        sessionId = null
        manager.registerListener(listener)

        val request = SplitInstallRequest.newBuilder().addModule(MODULE).build()
        manager.startInstall(request)
            .addOnSuccessListener { id ->
                // Zero means there was nothing to install.
                if (id == 0) finish(null) else sessionId = id
            }
            .addOnFailureListener { error ->
                val code = (error as? SplitInstallException)?.errorCode
                if (code == SplitInstallErrorCode.ACTIVE_SESSIONS_LIMIT_EXCEEDED) {
                    // Already installing — most likely a download that outlived
                    // the process that asked for it. Wait on that one.
                    attachToActiveSession()
                } else {
                    Log.w(TAG, "startInstall failed", error)
                    finish(code ?: SplitInstallErrorCode.INTERNAL_ERROR)
                }
            }
    }

    private fun attachToActiveSession() {
        manager.sessionStates
            .addOnSuccessListener { states ->
                val active = states.firstOrNull {
                    MODULE in it.moduleNames() && !it.isTerminal()
                }
                if (active == null) {
                    finish(SplitInstallErrorCode.ACTIVE_SESSIONS_LIMIT_EXCEEDED)
                } else {
                    sessionId = active.sessionId()
                    onState(active)
                }
            }
            .addOnFailureListener { finish(SplitInstallErrorCode.INTERNAL_ERROR) }
    }

    private fun onState(state: SplitInstallSessionState) {
        if (pending == null || MODULE !in state.moduleNames()) return
        val expected = sessionId
        if (expected != null && state.sessionId() != expected) return

        when (state.status()) {
            SplitInstallSessionStatus.DOWNLOADING ->
                channel.invokeMethod(
                    "progress",
                    listOf(state.bytesDownloaded(), state.totalBytesToDownload()),
                )
            SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION ->
                // Play asks before a large download on a metered network, or for
                // an app it did not install. Its answer comes back as a state.
                manager.startConfirmationDialogForResult(state, confirmationLauncher)
            SplitInstallSessionStatus.INSTALLED -> {
                SplitCompat.install(context)
                finish(null)
            }
            SplitInstallSessionStatus.FAILED -> finish(state.errorCode())
            SplitInstallSessionStatus.CANCELED -> finish(SplitInstallErrorCode.INTERNAL_ERROR, "CANCELED")
            else -> Unit
        }
    }

    /** The user dismissed Play's confirmation dialog. */
    fun onConfirmationResult(resultCode: Int) {
        if (resultCode != Activity.RESULT_OK) {
            finish(SplitInstallErrorCode.INTERNAL_ERROR, "CANCELED")
        }
    }

    private fun finish(errorCode: Int?, name: String? = null) {
        val result = pending ?: return
        pending = null
        sessionId = null
        manager.unregisterListener(listener)
        if (errorCode == null) {
            result.success(null)
        } else {
            result.error(name ?: errorName(errorCode), "Engine install failed ($errorCode)", errorCode)
        }
    }

    private fun SplitInstallSessionState.isTerminal() = when (status()) {
        SplitInstallSessionStatus.INSTALLED,
        SplitInstallSessionStatus.FAILED,
        SplitInstallSessionStatus.CANCELED -> true
        else -> false
    }

    /** Stable names for the codes Dart turns into copy. */
    private fun errorName(code: Int): String = when (code) {
        SplitInstallErrorCode.NETWORK_ERROR -> "NETWORK_ERROR"
        SplitInstallErrorCode.INSUFFICIENT_STORAGE -> "INSUFFICIENT_STORAGE"
        SplitInstallErrorCode.PLAY_STORE_NOT_FOUND -> "PLAY_STORE_NOT_FOUND"
        SplitInstallErrorCode.APP_NOT_OWNED -> "APP_NOT_OWNED"
        SplitInstallErrorCode.API_NOT_AVAILABLE -> "API_NOT_AVAILABLE"
        else -> "INSTALL_FAILED"
    }
}
