package com.zenstream.app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Environment
import android.provider.MediaStore
import android.util.Rational
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraEffect
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.effects.OverlayEffect
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
import com.pedro.common.ConnectChecker
import com.pedro.library.rtmp.RtmpCamera2
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
import kotlin.math.min

data class RecordingStatus(
    val isStarting: Boolean = false,
    val isRecording: Boolean = false,
    val savedUri: Uri? = null,
    val errorMessage: String? = null,
)

data class StreamStatus(
    val isStarting: Boolean = false,
    val isStreaming: Boolean = false,
    val endpoint: String = "",
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
    private var previewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var overlayEffect: OverlayEffect? = null
    private var overlayHandlerThread: HandlerThread? = null
    private var rtmpStream: RtmpCamera2? = null
    @Volatile private var isPortrait = false
    private var isStopped = false

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel

    private val _cameraReady = MutableStateFlow(false)
    val cameraReady: StateFlow<Boolean> = _cameraReady

    private val _cameraError = MutableStateFlow<String?>(null)
    val cameraError: StateFlow<String?> = _cameraError

    private val _recordingStatus = MutableStateFlow(RecordingStatus())
    val recordingStatus: StateFlow<RecordingStatus> = _recordingStatus

    private val _streamStatus = MutableStateFlow(StreamStatus())
    val streamStatus: StateFlow<StreamStatus> = _streamStatus

    fun start(previewView: PreviewView) {
        isStopped = false
        this.previewView = previewView
        startCamera(previewView)
        startMicMeter()
    }

    fun setPortrait(portrait: Boolean) {
        if (isPortrait == portrait ||
            _recordingStatus.value.isStarting ||
            _recordingStatus.value.isRecording
        ) {
            return
        }
        isPortrait = portrait
        _cameraReady.value = false
        videoCapture = null
        val provider = cameraProvider ?: return
        val currentPreview = previewView ?: return
        bindCamera(provider, currentPreview)
    }

    fun stop() {
        isStopped = true
        stopStreaming()
        activeRecording?.stop()
        activeRecording = null
        stopMicMeter()
        _cameraReady.value = false
        ProcessCameraProvider.getInstance(context).get().unbindAll()
        overlayEffect?.close()
        overlayEffect = null
        overlayHandlerThread?.quitSafely()
        overlayHandlerThread = null
        cameraProvider = null
        previewView = null
    }

    fun startStreaming(endpoint: String) {
        val normalized = endpoint.trim()
        if (normalized.isEmpty()) {
            _streamStatus.value = StreamStatus(errorMessage = "Enter an RTMP endpoint before going live.")
            return
        }
        if (_streamStatus.value.isStarting || _streamStatus.value.isStreaming) return

        _streamStatus.value = StreamStatus(isStarting = true, endpoint = normalized)
        rtmpStream = RtmpCamera2(context.applicationContext, object : ConnectChecker {
            override fun onConnectionStarted(url: String) = Unit
            override fun onConnectionSuccess() {
                _streamStatus.value = StreamStatus(isStreaming = true, endpoint = normalized)
            }
            override fun onConnectionFailed(reason: String) {
                _streamStatus.value = StreamStatus(
                    endpoint = normalized,
                    errorMessage = "Stream failed: $reason",
                )
                rtmpStream = null
            }
            override fun onDisconnect() {
                _streamStatus.value = StreamStatus(endpoint = normalized)
                rtmpStream = null
            }
            override fun onAuthError() {
                _streamStatus.value = StreamStatus(
                    endpoint = normalized,
                    errorMessage = "Stream authentication failed.",
                )
                rtmpStream = null
            }
            override fun onAuthSuccess() = Unit
        })

        scope.launch {
            try {
                val videoPrepared = rtmpStream?.prepareVideo(
                    1280,
                    720,
                    30,
                    1200 * 1024,
                    if (isPortrait) 90 else 0,
                ) ?: false
                val audioPrepared = rtmpStream?.prepareAudio(
                    64 * 1024,
                    32_000,
                    true,
                    true,
                    true,
                ) ?: false
                if (!videoPrepared || !audioPrepared) {
                    _streamStatus.value = StreamStatus(
                        endpoint = normalized,
                        errorMessage = "RTMP encoder preparation failed.",
                    )
                    stopStreaming()
                    return@launch
                }
                rtmpStream?.startStream(normalized)
                _streamStatus.value = StreamStatus(isStreaming = true, endpoint = normalized)
            } catch (exception: Exception) {
                _streamStatus.value = StreamStatus(
                    endpoint = normalized,
                    errorMessage = "Could not start stream: ${exception.localizedMessage}",
                )
                stopStreaming()
            }
        }
    }

    fun stopStreaming() {
        val currentUrl = _streamStatus.value.endpoint
        rtmpStream?.stopStream()
        rtmpStream?.release()
        rtmpStream = null
        _streamStatus.value = StreamStatus(endpoint = currentUrl)
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
                cameraProvider = provider
                bindCamera(provider, previewView)
            } catch (exception: Exception) {
                videoCapture = null
                _cameraReady.value = false
                _cameraError.value = "Camera unavailable: ${exception.localizedMessage}"
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bindCamera(provider: ProcessCameraProvider, previewView: PreviewView) {
        try {
            val rotation = previewView.display?.rotation ?: android.view.Surface.ROTATION_0
            val preview = Preview.Builder()
                .setTargetRotation(rotation)
                .build()
                .also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
            val recorder = Recorder.Builder()
                .setQualitySelector(QualitySelector.from(Quality.HD))
                .build()
            val capture = VideoCapture.withOutput(recorder)
                .also { it.targetRotation = rotation }
            val aspectRatio = if (isPortrait) Rational(9, 16) else Rational(16, 9)
            val viewPort = ViewPort.Builder(aspectRatio, rotation)
                .setScaleType(ViewPort.FILL_CENTER)
                .build()
            val useCaseGroup = UseCaseGroup.Builder()
                .setViewPort(viewPort)
                .addUseCase(preview)
                .addUseCase(capture)
                .addEffect(getOverlayEffect())
                .build()

            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_FRONT_CAMERA,
                useCaseGroup,
            )
            videoCapture = capture
            _cameraReady.value = true
            _cameraError.value = null
        } catch (exception: Exception) {
            videoCapture = null
            _cameraReady.value = false
            _cameraError.value = "Camera unavailable: ${exception.localizedMessage}"
        }
    }

    private fun getOverlayEffect(): OverlayEffect {
        overlayEffect?.let { return it }
        val handlerThread = HandlerThread("ZenStreamOverlay").apply { start() }
        return try {
            OverlayEffect(
                CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE,
                0,
                Handler(handlerThread.looper),
            ) { throwable ->
                _cameraReady.value = false
                videoCapture = null
                _cameraError.value = "Composition unavailable: ${throwable.localizedMessage}"
            }.also { effect ->
                val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.argb(205, 15, 23, 42)
                }
                val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.WHITE
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                }
                effect.setOnDrawListener { frame ->
                    val canvas: Canvas = frame.overlayCanvas
                    val crop = frame.cropRect
                    val padding = min(crop.width(), crop.height()) * 0.035f
                    textPaint.textSize = min(crop.width(), crop.height()) * 0.055f
                    val label = if (isPortrait) {
                        "ZenStream Studio - VERTICAL"
                    } else {
                        "ZenStream Studio - HORIZONTAL"
                    }
                    val textWidth = textPaint.measureText(label)
                    val textHeight = textPaint.textSize
                    val left = crop.left + padding
                    val top = crop.top + padding
                    val badge = RectF(
                        left,
                        top,
                        left + textWidth + padding * 2,
                        top + textHeight + padding * 2,
                    )
                    canvas.drawRoundRect(badge, padding, padding, backgroundPaint)
                    canvas.drawText(label, left + padding, top + padding + textHeight, textPaint)
                    true
                }
                overlayEffect = effect
                overlayHandlerThread = handlerThread
            }
        } catch (exception: Exception) {
            handlerThread.quitSafely()
            throw exception
        }
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
