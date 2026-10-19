using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.Core;
using Windows.Media.Render;

namespace ZenStream;

public sealed partial class MainWindow : Window
{
    private MediaCapture? _mediaCapture;
    private MediaSource? _cameraSource;
    private AudioGraph? _audioGraph;
    private AudioDeviceInputNode? _microphoneInput;
    private AudioFrameOutputNode? _audioFrameOutput;

    public MainWindow() => InitializeComponent();

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
            group.SourceInfos.Any(sourceInfo => sourceInfo.Kind == MediaFrameSourceKind.VideoPreview));
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
                StreamingCaptureMode = StreamingCaptureMode.Video,
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
            sourceInfo.Kind == MediaFrameSourceKind.VideoPreview);
        _mediaCapture = camera;
        _cameraSource = MediaSource.CreateFromMediaFrameSource(camera.FrameSources[sourceInfo.Id]);
        CameraPreview.Source = _cameraSource;
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

    private void Window_Closed(object sender, WindowEventArgs args)
    {
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
