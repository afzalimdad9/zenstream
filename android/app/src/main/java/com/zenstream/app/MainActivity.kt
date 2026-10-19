package com.zenstream.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    PermissionGate {
                        StudioHost()
                    }
                }
            }
        }
    }
}

@Composable
private fun StudioHost() {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    // Single service instance, scoped to the composition.
    val service = remember(lifecycleOwner) {
        CameraCaptureService(context, lifecycleOwner, scope)
    }

    StudioScreen(
        captureService = service,
        micLevel = service.micLevel,
    )
}