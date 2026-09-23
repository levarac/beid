package org.levarac.beid.venue

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import org.levarac.beid.registry.RegistryDependencies
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.parallax.registry.RegistryClient

/** Dedicated, explicit-only venue host. Construction/import never starts the radio. */
internal class VenueActivity : ComponentActivity() {
    private lateinit var radio: VenueRadio
    private lateinit var controller: VenueController
    private var registryClient: RegistryClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        radio = BarnardVenueRadio(this)
        registryClient = RegistryDependencies.createClient()
        controller = VenueController(
            SharedVenuePackImporter(registryClient),
            radio,
            lifecycleScope,
        )
        setContent { BeidAppTheme { VenueScreen(controller) } }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        radio.forwardPermissionResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        controller.dispose()
        registryClient?.close()
        super.onDestroy()
    }

    companion object {
        /** Tested launcher contract; navigation integration intentionally remains a later PR. */
        fun createIntent(context: Context): Intent = Intent(context, VenueActivity::class.java)
    }
}
