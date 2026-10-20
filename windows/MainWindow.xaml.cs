using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Render;
using Windows.Storage;

namespace ZenStream;

public sealed partial class MainWindow : Window
{
    private MediaCapture? _mediaCapture;
    private MediaSource? _cameraSource;
    private AudioGraph? _audioGraph;
    private AudioDeviceInputNode? _microphoneInput;
    private AudioFrameOutputNode? _audioFrameOutput;
    private bool _isRecording;
    private bool _isStartingRecording;
    private bool _audioGraphPausedForRecording;
    private bool _isPortrait;
    private bool _isStreaming;
    private bool _isStartingStream;
    private string? _recordingFilePath;

    public MainWindow()
    {
        InitializeComponent();
        SetCanvasOrientation(portrait: false);
    }

    private void HorizontalButton_Click(object sender, RoutedEventArgs e)
    {
        SetCanvasOrientation(portrait: false);
    }

    private void VerticalButton_Click(object sender, RoutedEventArgs e)
    {
        SetCanvasOrientation(portrait: true);
    }

    private void SetCanvasOrientation(bool portrait)
    {
        _isPortrait = portrait;
        CameraPreviewCanvas.Width = portrait ? 900 : 1600;
        CameraPreviewCanvas.Height = portrait ? 1600 : 900;
        CompositionLabel.Text = portrait
            ? "ZenStream Studio - Vertical 9:16"
            : "ZenStream Studio - Horizontal 16:9";
        HorizontalButton.IsEnabled = !_isRecording && !_isStartingRecording && portrait;
        VerticalButton.IsEnabled = !_isRecording && !_isStartingRecording && !portrait;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await StartCameraPreviewAsync();
        }
        catch (Exception exception)
        {
            AddStatus($"Camera unavailable: {exception.Message}");
        }

        try
        {
            await StartMicrophoneMeterAsync();
        }
        catch (Exception exception)
        {
            AddStatus($"Microphone unavailable: {exception.Message}");
        }
    }

    private async Task StartCameraPreviewAsync()
    {
        var sourceGroups = await MediaFrameSourceGroup.FindAllAsync();
        var sourceGroup = sourceGroups.FirstOrDefault(group =>
            group.SourceInfos.Any(sourceInfo => sourceInfo.SourceKind == MediaFrameSourceKind.Color));
        if (sourceGroup is null)
        {
            AddStatus("No camera device was found.");
            return;
        }

        var camera = new MediaCapture();
        try
        {
            await camera.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = sourceGroup,
                StreamingCaptureMode = StreamingCaptureMode.AudioAndVideo,
                SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            });
        }
        catch
        {
            camera.Dispose();
            throw;
        }

        var sourceInfo = sourceGroup.SourceInfos.First(sourceInfo =>
            sourceInfo.SourceKind == MediaFrameSourceKind.Color);
        _mediaCapture = camera;
        _cameraSource = MediaSource.CreateFromMediaFrameSource(camera.FrameSources[sourceInfo.Id]);
        CameraPreview.Source = _cameraSource;
        RecordButton.IsEnabled = true;
    }

    private async Task StartMicrophoneMeterAsync()
    {
        var graphResult = await AudioGraph.CreateAsync(
            new AudioGraphSettings(AudioRenderCategory.Media));
        if (graphResult.Status != AudioGraphCreationStatus.Success)
        {
            throw new InvalidOperationException($"Audio graph initialization failed: {graphResult.Status}.");
        }

        _audioGraph = graphResult.Graph;
        var inputResult = await _audioGraph.CreateDeviceInputNodeAsync(MediaCategory.Other);
        if (inputResult.Status != AudioDeviceNodeCreationStatus.Success)
        {
            throw new InvalidOperationException($"Microphone initialization failed: {inputResult.Status}.");
        }

        _microphoneInput = inputResult.DeviceInputNode;
        _audioFrameOutput = _audioGraph.CreateFrameOutputNode();
        _microphoneInput.AddOutgoingConnection(_audioFrameOutput);
        _audioGraph.QuantumStarted += AudioGraph_QuantumStarted;
        _audioGraph.Start();
    }

    private unsafe void AudioGraph_QuantumStarted(AudioGraph sender, object args)
    {
        using var frame = _audioFrameOutput!.GetFrame();
        using var buffer = frame.LockBuffer(AudioBufferAccessMode.Read);
        using var reference = buffer.CreateReference();

        ((IMemoryBufferByteAccess)reference).GetBuffer(out byte* bytes, out uint capacity);
        var sampleCount = capacity / sizeof(float);
        if (bytes == null || sampleCount == 0)
        {
            return;
        }

        var samples = (float*)bytes;
        double sumOfSquares = 0;
        for (uint index = 0; index < sampleCount; index++)
        {
            sumOfSquares += samples[index] * samples[index];
        }

        var level = Math.Clamp(Math.Sqrt(sumOfSquares / sampleCount), 0, 1);
        DispatcherQueue.TryEnqueue(() => MicrophoneLevel.Value = level);
    }

    private void AddStatus(string message)
    {
        StatusText.Text = string.IsNullOrEmpty(StatusText.Text)
            ? message
            : $"{StatusText.Text}{Environment.NewLine}{message}";
    }

    private void GoLiveButton_Click(object sender, RoutedEventArgs e)
    {
        var endpoint = StreamUrlTextBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            AddStatus("Enter an RTMP destination before going live.");
            return;
        }

        if (_isStreaming || _isStartingStream || _isRecording)
        {
            return;
        }

        _isStartingStream = true;
        GoLiveButton.IsEnabled = false;
        StopStreamButton.IsEnabled = false;
        AddStatus($"RTMP destination configured: {endpoint}. Managed RTMP library restore was not available in this pass, so the stream entry is staged for the follow-up integration.");
        _isStreaming = true;
        _isStartingStream = false;
        StopStreamButton.IsEnabled = true;
        AddStatus("Stream ready to connect once the RTMP client restore is available.");
    }

    private void StopStreamButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isStreaming) return;
        _isStreaming = false;
        _isStartingStream = false;
        GoLiveButton.IsEnabled = true;
        StopStreamButton.IsEnabled = false;
        AddStatus("RTMP stream stopped. Destination remains configured for the next client restore.");
    }

    private async void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        var mediaCapture = _mediaCapture;
        if (mediaCapture is null)
        {
            AddStatus("Camera capture is not available.");
            return;
        }

        RecordButton.IsEnabled = false;
        _isStartingRecording = true;
        SetCanvasOrientation(_isPortrait);
        try
        {
            // TODO: record the Win2D-composed canvas instead of the raw camera stream.
            AddStatus("Recording the raw camera feed; composed recording is pending.");
            var recordingsPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ZenStream",
                "Recordings");
            Directory.CreateDirectory(recordingsPath);
            var folder = await StorageFolder.GetFolderFromPathAsync(recordingsPath);
            var file = await folder.CreateFileAsync(
                $"ZenStream-{DateTime.UtcNow:yyyyMMdd-HHmmss}.mp4",
                CreationCollisionOption.GenerateUniqueName);

            if (_audioGraph is not null)
            {
                _audioGraph.Stop();
                _audioGraphPausedForRecording = true;
            }

            await mediaCapture.StartRecordToStorageFileAsync(
                MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Auto),
                file);
            _recordingFilePath = file.Path;
            _isRecording = true;
            _isStartingRecording = false;
            StopButton.IsEnabled = true;
            SetCanvasOrientation(_isPortrait);
            AddStatus($"Recording to {_recordingFilePath}");
        }
        catch (Exception exception)
        {
            _isRecording = false;
            _isStartingRecording = false;
            StopButton.IsEnabled = false;
            RecordButton.IsEnabled = true;
            SetCanvasOrientation(_isPortrait);
            ResumeMicrophoneMeter();
            AddStatus($"Recording could not start: {exception.Message}");
        }
    }

    private async void StopButton_Click(object sender, RoutedEventArgs e)
    {
        await StopRecordingAsync();
    }

    private async Task StopRecordingAsync()
    {
        if (!_isRecording || _mediaCapture is null) return;

        try
        {
            await _mediaCapture.StopRecordAsync();
            _isRecording = false;
            StopButton.IsEnabled = false;
            RecordButton.IsEnabled = true;
            SetCanvasOrientation(_isPortrait);
            ResumeMicrophoneMeter();
            AddStatus($"Recording saved to {_recordingFilePath}");
        }
        catch (Exception exception)
        {
            AddStatus($"Recording could not stop cleanly: {exception.Message}");
        }
    }

    private void ResumeMicrophoneMeter()
    {
        if (!_audioGraphPausedForRecording || _audioGraph is null) return;

        try
        {
            _audioGraph.Start();
            _audioGraphPausedForRecording = false;
        }
        catch (Exception exception)
        {
            AddStatus($"Microphone meter could not resume: {exception.Message}");
        }
    }

    private async void Window_Closed(object sender, WindowEventArgs args)
    {
        await StopRecordingAsync();
        CameraPreview.Source = null;
        _cameraSource?.Dispose();
        _mediaCapture?.Dispose();

        if (_audioGraph is not null)
        {
            _audioGraph.QuantumStarted -= AudioGraph_QuantumStarted;
            _audioGraph.Stop();
            _audioGraph.Dispose();
        }
    }

    [ComImport]
    [Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private unsafe interface IMemoryBufferByteAccess
    {
        void GetBuffer(out byte* buffer, out uint capacity);
    }
}
