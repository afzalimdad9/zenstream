package com.zenstream.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max

/**
 * Binds CameraX Preview to a PreviewView and runs a lightweight
 * AudioRecord loop that publishes a normalized mic level (0.0–1.0).
 *
 * This is the capture foundation only — no encoding, no recording, no streaming.
 */
class CameraCaptureService(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val scope: CoroutineScope,
) {
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var audioJob: Job? = null
    private var audioRecord: AudioRecord? = null

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel

    fun start(previewView: PreviewView) {
        startCamera(previewView)
        startMicMeter()
    }

    fun stop() {
        audioJob?.cancel()
        audioJob = null
        audioRecord?.runCatching {
            stop()
            release()
        }
        audioRecord = null
        ProcessCameraProvider.getInstance(context).get().unbindAll()
    }

    // ---- Camera ---------------------------------------------------------

    private fun startCamera(previewView: PreviewView) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_FRONT_CAMERA, // swap to DEFAULT_BACK_CAMERA if preferred
                preview,
            )
        }, ContextCompat.getMainExecutor(context))
    }

    // ---- Mic level ------------------------------------------------------

    private fun startMicMeter() {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) return

        val sampleRate = 44_100
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) return

        audioJob = scope.launch(Dispatchers.Default) {
            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuf, 2048),
            )
            audioRecord = record
            if (record.state != AudioRecord.STATE_INITIALIZED) return@launch

            record.startRecording()
            val buffer = ShortArray(1024)

            while (isActive) {
                val read = record.read(buffer, 0, buffer.size)
                if (read > 0) {
                    var sum = 0.0
                    for (i in 0 until read) {
                        val v = buffer[i].toDouble()
                        sum += v * v
                    }
                    val rms = kotlin.math.sqrt(sum / read)
                    // Map RMS to a 0..1 perceptual level.
                    val db = 20.0 * log10(max(rms, 1.0) / Short.MAX_VALUE.toDouble())
                    val normalized = ((db + 60.0) / 60.0).coerceIn(0.0, 1.0).toFloat()
                    _micLevel.value = normalized
                }
            }
            record.stop()
            record.release()
        }
    }
}