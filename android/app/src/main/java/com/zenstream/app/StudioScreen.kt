package com.zenstream.app

import android.view.ViewGroup
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.flow.StateFlow

@Composable
fun StudioScreen(
    captureService: CameraCaptureService,
    micLevel: StateFlow<Float>,
) {
    val level by micLevel.collectAsState()

    DisposableEffect(captureService) {
        onDispose { captureService.stop() }
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("ZenStream Studio", fontSize = 26.sp, style = MaterialTheme.typography.headlineMedium)

        AndroidView(
            factory = { ctx ->
                PreviewView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    captureService.start(this)
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        )

        Text("Mic level", fontSize = 14.sp)
        LinearProgressIndicator(
            progress = { level },
            modifier = Modifier.fillMaxWidth().height(12.dp),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { }, enabled = false) { Text("Record (next milestone)") }
            OutlinedButton(onClick = { }, enabled = false) { Text("Stream (later)") }
        }
    }
}