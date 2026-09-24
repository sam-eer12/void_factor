package com.voidfactor.app

import android.app.Application
import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat

/**
 * Exists for one line: [SplitCompat.install].
 *
 * The on-demand `gemma_engine` module is sometimes installed *emulated* — by
 * Play while the app was already running, and always by bundletool's local
 * testing — and an emulated split's libraries are on the class loader only
 * once SplitCompat has run in this process. Doing it here covers every later
 * launch; [GemmaEngineDelivery] repeats it right after an install.
 */
class VoidFactorApplication : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        SplitCompat.install(this)
    }
}
