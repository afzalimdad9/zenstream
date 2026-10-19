package com.zenstream.app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.log10
import kotlin.math.max

data class RecordingStatus(
    val isStarting: Boolean = false,
    val isRecording: Boolean = false,
    val savedUri: Uri? = null,
    val errorMessage: String? = null,
)

class CameraCaptureService(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val scope: CoroutineScope,
) {
    private val audioRecordLock = Any()
    private var audioJob: Job? = null
    private var audioRecord: AudioRecord? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var isStopped = false

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel

    private val _cameraReady = MutableStateFlow(false)
    val cameraReady: StateFlow<Boolean> = _cameraReady

    private val _cameraError = MutableStateFlow<String?>(null)
    val cameraError: StateFlow<String?> = _cameraError

    private val _recordingStatus = MutableStateFlow(RecordingStatus())
    val recordingStatus: StateFlow<RecordingStatus> = _recordingStatus

    fun start(previewView: PreviewView) {
        isStopped = false
        startCamera(previewView)
        startMicMeter()
    }

    fun stop() {
        isStopped = true
        activeRecording?.stop()
        activeRecording = null
        stopMicMeter()
        _cameraReady.value = false
        ProcessCameraProvider.getInstance(context).get().unbindAll()
    }

    fun startRecording() {
        if (_recordingStatus.value.isStarting || _recordingStatus.value.isRecording) return
        _recordingStatus.value = RecordingStatus(isStarting = true)

        scope.launch {
            pauseMicMeter()
            val capture = videoCapture
            if (capture == null || isStopped) {
                _recordingStatus.value = RecordingStatus(
                    errorMessage = "Camera is not ready to record.",
                )
                if (!isStopped) startMicMeter()
                return@launch
            }

            if (ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.RECORD_AUDIO,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                _recordingStatus.value = RecordingStatus(
                    errorMessage = "Microphone permission is required to record audio.",
                )
                startMicMeter()
                return@launch
            }

            try {
                val fileName = "ZenStream-${System.currentTimeMillis()}.mp4"
                val contentValues = ContentValues().apply {
                    put(
                        MediaStore.MediaColumns.DISPLAY_NAME,
                        fileName,
                    )
                    put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(
                            MediaStore.MediaColumns.RELATIVE_PATH,
                            "${Environment.DIRECTORY_MOVIES}/ZenStream",
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        val moviesDirectory = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_MOVIES,
                        )
                        val outputDirectory = File(moviesDirectory, "ZenStream")
                        if (!outputDirectory.exists() && !outputDirectory.mkdirs()) {
                            throw IllegalStateException("Could not create Movies/ZenStream.")
                        }
                        put(
                            MediaStore.MediaColumns.DATA,
                            File(outputDirectory, fileName).absolutePath,
                        )
                    }
                }
                val outputOptions = MediaStoreOutputOptions.Builder(
                    context.contentResolver,
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                )
                    .setContentValues(contentValues)
                    .build()

                val pendingRecording = capture.output
                    .prepareRecording(context, outputOptions)
                    .withAudioEnabled()
                activeRecording = pendingRecording.start(
                    ContextCompat.getMainExecutor(context),
                ) { event ->
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            _recordingStatus.value = RecordingStatus(isRecording = true)
                        }
                        is VideoRecordEvent.Finalize -> {
                            activeRecording = null
                            _recordingStatus.value = if (event.hasError()) {
                                RecordingStatus(
                                    errorMessage = event.cause?.message
                                        ?: "Recording failed (${event.error}).",
                                )
                            } else {
                                RecordingStatus(savedUri = event.outputResults.outputUri)
                            }
                            if (!isStopped) startMicMeter()
                        }
                    }
                }
            } catch (exception: Exception) {
                _recordingStatus.value = RecordingStatus(
                    errorMessage = "Could not start recording: ${exception.localizedMessage}",
                )
                if (!isStopped) startMicMeter()
            }
        }
    }

    fun stopRecording() {
        activeRecording?.stop()
    }

    private suspend fun pauseMicMeter() {
        val job = audioJob
        stopMicMeter()
        job?.cancelAndJoin()
    }

    private fun startCamera(previewView: PreviewView) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            if (isStopped) return@addListener
            try {
                val provider = providerFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val recorder = Recorder.Builder()
                    .setQualitySelector(QualitySelector.from(Quality.HD))
                    .build()
                val capture = VideoCapture.withOutput(recorder)

                provider.unbindAll()
                provider.bindToLifecycle(
                    lifecycleOwner,
                    CameraSelector.DEFAULT_FRONT_CAMERA,
                    preview,
                    capture,
                )
                videoCapture = capture
                _cameraReady.value = true
                _cameraError.value = null
            } catch (exception: Exception) {
                videoCapture = null
                _cameraReady.value = false
                _cameraError.value = "Camera unavailable: ${exception.localizedMessage}"
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun stopMicMeter() {
        val (job, record) = synchronized(audioRecordLock) {
            val currentJob = audioJob
            val currentRecord = audioRecord
            audioJob = null
            audioRecord = null
            currentJob to currentRecord
        }

        job?.cancel()
        record?.let {
            if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                runCatching { it.stop() }
            }
            runCatching { it.release() }
        }
    }

    private fun startMicMeter() {
        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) return

        val sampleRate = 44_100
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) return

        synchronized(audioRecordLock) {
            if (audioJob?.isActive == true) return
            audioJob = scope.launch(Dispatchers.Default) {
                val record = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    max(minBuf, 2048),
                )
                if (record.state != AudioRecord.STATE_INITIALIZED) {
                    record.release()
                    return@launch
                }

                synchronized(audioRecordLock) {
                    if (!isActive) {
                        record.release()
                        return@launch
                    }
                    audioRecord = record
                }

                try {
                    record.startRecording()
                    val buffer = ShortArray(1024)
                    while (isActive) {
                        val read = record.read(buffer, 0, buffer.size)
                        if (read <= 0) break

                        var sum = 0.0
                        for (i in 0 until read) {
                            val value = buffer[i].toDouble()
                            sum += value * value
                        }
                        val rms = kotlin.math.sqrt(sum / read)
                        val db = 20.0 * log10(max(rms, 1.0) / Short.MAX_VALUE.toDouble())
                        _micLevel.value = ((db + 60.0) / 60.0).coerceIn(0.0, 1.0).toFloat()
                    }
                } finally {
                    synchronized(audioRecordLock) {
                        if (audioRecord === record) {
                            audioRecord = null
                            audioJob = null
                            if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                                runCatching { record.stop() }
                            }
                            runCatching { record.release() }
                        }
                    }
                }
            }
        }
    }
}
