package org.levarac.beid.lab

import android.os.Bundle
import android.widget.TextView
import org.levarac.beid.MainActivity

/** Lab launcher; production MainActivity remains the coordinator owner. */
class LabMainActivity : MainActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val identity = runCatching {
            LabControlIdentity(
                runId = intent.getStringExtra("run_id").orEmpty(),
                role = intent.getStringExtra("role").orEmpty(),
                deviceId = intent.getStringExtra("device_id").orEmpty(),
                generation = intent.getIntExtra("generation", -1),
                token = intent.getStringExtra("token").orEmpty(),
                protocolVersion = intent.getIntExtra("protocol_version", -1),
            )
        }.getOrElse {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: ${it.message}" })
            return
        }
        val brokerUrl = intent.getStringExtra("broker_url").orEmpty()
        if (brokerUrl.isBlank()) {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: lab broker is not configured" })
            return
        }
        super.onCreate(savedInstanceState)
        val result = LabControlBootstrap(
            identity = identity,
            brokerUrl = brokerUrl,
            broker = OkHttpLabWebSocketClient(),
            productionState = ::labReadOnlyState,
        ).start()
        if (result.isFailure) {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: ${result.exceptionOrNull()?.message}" })
        }
    }
}
