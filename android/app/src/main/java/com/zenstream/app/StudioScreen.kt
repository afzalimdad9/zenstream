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
    val cameraReady by captureService.cameraReady.collectAsState()
    val cameraError by captureService.cameraError.collectAsState()
    val recording by captureService.recordingStatus.collectAsState()
    var portrait by remember { mutableStateOf(false) }
    val isRecording = recording.isStarting || recording.isRecording

    DisposableEffect(captureService) {
        onDispose { captureService.stop() }
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("ZenStream Studio", fontSize = 26.sp, style = MaterialTheme.typography.headlineMedium)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = !portrait,
                onClick = {
                    portrait = false
                    captureService.setPortrait(false)
                },
                enabled = !isRecording,
                label = { Text("Horizontal 16:9") },
            )
            FilterChip(
                selected = portrait,
                onClick = {
                    portrait = true
                    captureService.setPortrait(true)
                },
                enabled = !isRecording,
                label = { Text("Vertical 9:16") },
            )
        }

        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            val aspectRatio = if (portrait) 9f / 16f else 16f / 9f
            val previewModifier = if (maxWidth / maxHeight >= aspectRatio) {
                Modifier.height(maxHeight).aspectRatio(aspectRatio)
            } else {
                Modifier.width(maxWidth).aspectRatio(aspectRatio)
            }
            AndroidView(
                factory = { ctx ->
                    PreviewView(ctx).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        scaleType = PreviewView.ScaleType.FILL_CENTER
                        captureService.start(this)
                    }
                },
                modifier = previewModifier,
            )
        }

        Text("Mic level", fontSize = 14.sp)
        LinearProgressIndicator(
            progress = { level },
            modifier = Modifier.fillMaxWidth().height(12.dp),
        )

        cameraError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        recording.errorMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
        }
        if (recording.savedUri != null) {
            Text("Saved recording to Movies/ZenStream")
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = captureService::startRecording,
                enabled = cameraReady && !recording.isStarting && !recording.isRecording,
            ) {
                Text(if (recording.isStarting) "Preparing..." else "Record")
            }
            OutlinedButton(
                onClick = captureService::stopRecording,
                enabled = recording.isRecording,
            ) {
                Text("Stop")
            }
            OutlinedButton(onClick = { }, enabled = false) { Text("Stream (later)") }
        }
    }
}