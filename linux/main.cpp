#include <QApplication>
#include <QAudioBuffer>
#include <QAudioDevice>
#include <QAudioFormat>
#include <QAudioSource>
#include <QDateTime>
#include <QDir>
#include <QHBoxLayout>
#include <QIODevice>
#include <QLabel>
#include <QMainWindow>
#include <QMediaDevices>
#include <QProgressBar>
#include <QPushButton>
#include <QResizeEvent>
#include <QSizePolicy>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtMath>

#include <gst/gst.h>
#include <gst/video/videooverlay.h>

#include <cmath>

namespace {
qreal calculateRms(const QAudioBuffer &buffer)
{
    if (!buffer.isValid() || buffer.sampleCount() == 0) {
        return 0;
    }

    const int sampleCount = buffer.sampleCount();
    double sumOfSquares = 0;

    switch (buffer.format().sampleFormat()) {
    case QAudioFormat::UInt8: {
        const auto *samples = buffer.constData<quint8>();
        for (int i = 0; i < sampleCount; ++i) {
            const double sample = (static_cast<int>(samples[i]) - 128) / 128.0;
            sumOfSquares += sample * sample;
        }
        break;
    }
    case QAudioFormat::Int16: {
        const auto *samples = buffer.constData<qint16>();
        for (int i = 0; i < sampleCount; ++i) {
            const double sample = samples[i] / 32768.0;
            sumOfSquares += sample * sample;
        }
        break;
    }
    case QAudioFormat::Int32: {
        const auto *samples = buffer.constData<qint32>();
        for (int i = 0; i < sampleCount; ++i) {
            const double sample = samples[i] / 2147483648.0;
            sumOfSquares += sample * sample;
        }
        break;
    }
    case QAudioFormat::Float: {
        const auto *samples = buffer.constData<float>();
        for (int i = 0; i < sampleCount; ++i) {
            sumOfSquares += samples[i] * samples[i];
        }
        break;
    }
    case QAudioFormat::Unknown:
        return 0;
    }

    return qBound<qreal>(0, std::sqrt(sumOfSquares / sampleCount), 1);
}

class AspectRatioPreview final : public QWidget
{
public:
    explicit AspectRatioPreview(QWidget *parent = nullptr)
        : QWidget(parent),
          m_videoSurface(new QWidget(this))
    {
        setMinimumSize(320, 180);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        m_videoSurface->setAttribute(Qt::WA_NativeWindow);
        m_videoSurface->setAttribute(Qt::WA_OpaquePaintEvent);
        m_videoSurface->setStyleSheet("background-color: black;");
    }

    QWidget *videoSurface() const
    {
        return m_videoSurface;
    }

    void setPortrait(bool portrait)
    {
        m_portrait = portrait;
        updateSurfaceGeometry();
    }

protected:
    void resizeEvent(QResizeEvent *event) override
    {
        QWidget::resizeEvent(event);
        updateSurfaceGeometry();
    }

private:
    void updateSurfaceGeometry()
    {
        const QSize available = size();
        if (available.width() <= 0 || available.height() <= 0) {
            return;
        }

        const qreal aspectRatio = m_portrait ? 9.0 / 16.0 : 16.0 / 9.0;
        int width = available.width();
        int height = qRound(width / aspectRatio);
        if (height > available.height()) {
            height = available.height();
            width = qRound(height * aspectRatio);
        }

        m_videoSurface->setGeometry(
            (available.width() - width) / 2,
            (available.height() - height) / 2,
            width,
            height);
    }

    QWidget *m_videoSurface;
    bool m_portrait = false;
};

void setVideoWindowHandle(GstElement *element, gpointer userData)
{
    auto *surface = static_cast<QWidget *>(userData);
    if (GST_IS_VIDEO_OVERLAY(element)) {
        gst_video_overlay_set_window_handle(
            GST_VIDEO_OVERLAY(element),
            static_cast<guintptr>(surface->winId()));
    }
}

void onDeepElementAdded(
    GstBin *,
    GstBin *,
    GstElement *element,
    gpointer userData)
{
    if (GST_IS_VIDEO_OVERLAY(element)) {
        g_signal_connect(
            element,
            "prepare-window-handle",
            G_CALLBACK(setVideoWindowHandle),
            userData);
    }
}

QString videoCompositionDescription(bool portrait)
{
    const int width = portrait ? 720 : 1280;
    const int height = portrait ? 1280 : 720;
    const QString label = portrait
        ? "ZenStream Studio - Vertical 9:16"
        : "ZenStream Studio - Horizontal 16:9";
    return QString(
        "compositor name=scene background=black ! "
        "video/x-raw,width=%1,height=%2,framerate=30/1 ! videoconvert ! "
        "textoverlay text=\"%3\" valignment=top halignment=left "
        "font-desc=\"Sans Bold 24\" shaded-background=true ! tee name=video "
        "v4l2src device=/dev/video0 ! decodebin ! videoconvert ! "
        "videoscale add-borders=true ! videorate ! "
        "video/x-raw,width=%1,height=%2,framerate=30/1 ! queue ! scene.")
        .arg(width)
        .arg(height)
        .arg(label);
}

QString recordingPipelineDescription(bool portrait, const QString &filePath)
{
    const QByteArray pathBytes = filePath.toUtf8();
    gchar *escapedPath = g_strescape(pathBytes.constData(), nullptr);
    QString description = QString(
        " video. ! queue ! autovideosink "
        "video. ! queue ! videoconvert ! "
        "x264enc tune=zerolatency speed-preset=ultrafast bitrate=4000 key-int-max=30 ! "
        "h264parse ! queue ! mux. "
        "pulsesrc do-timestamp=true ! queue ! audioconvert ! audioresample ! "
        "audio/x-raw,rate=48000,channels=2 ! avenc_aac bitrate=128000 ! "
        "aacparse ! queue ! mux. "
        "mp4mux name=mux faststart=true ! filesink location=\"__OUTPUT_FILE__\"");
    description.prepend(videoCompositionDescription(portrait));
    description.replace("__OUTPUT_FILE__", QString::fromUtf8(escapedPath));
    g_free(escapedPath);
    return description;
}
}

int main(int argc, char *argv[])
{
    gst_init(&argc, &argv);
    QApplication app(argc, argv);
    QMainWindow window;
    auto *central = new QWidget(&window);
    auto *layout = new QVBoxLayout(central);

    auto *title = new QLabel("ZenStream Studio");
    title->setStyleSheet("font-size: 24px; font-weight: 600;");
    layout->addWidget(title);

    auto *preview = new AspectRatioPreview(central);
    layout->addWidget(preview, 1);

    auto *orientationControls = new QWidget(central);
    auto *orientationLayout = new QHBoxLayout(orientationControls);
    orientationLayout->setContentsMargins(0, 0, 0, 0);
    auto *horizontalButton = new QPushButton("Horizontal 16:9", orientationControls);
    auto *verticalButton = new QPushButton("Vertical 9:16", orientationControls);
    orientationLayout->addWidget(horizontalButton);
    orientationLayout->addWidget(verticalButton);
    layout->addWidget(orientationControls);

    auto *microphoneLabel = new QLabel("Microphone level");
    auto *microphoneLevel = new QProgressBar(central);
    microphoneLevel->setRange(0, 100);
    microphoneLevel->setValue(0);
    layout->addWidget(microphoneLabel);
    layout->addWidget(microphoneLevel);

    auto *status = new QLabel(central);
    status->setWordWrap(true);
    layout->addWidget(status);

    auto *recordButton = new QPushButton("Record", central);
    auto *stopButton = new QPushButton("Stop", central);
    recordButton->setEnabled(false);
    stopButton->setEnabled(false);
    auto *recordingControls = new QWidget(central);
    auto *recordingLayout = new QHBoxLayout(recordingControls);
    recordingLayout->setContentsMargins(0, 0, 0, 0);
    recordingLayout->addWidget(recordButton);
    recordingLayout->addWidget(stopButton);
    layout->addWidget(recordingControls);

    const QAudioDevice inputDevice = QMediaDevices::defaultAudioInput();
    const QAudioFormat format = inputDevice.preferredFormat();
    auto *audioSource = new QAudioSource(inputDevice, format, &window);
    bool microphoneMeterRunning = false;
    auto startMicrophoneMeter = [&]() {
        if (microphoneMeterRunning || inputDevice.isNull() || !format.isValid()) {
            return;
        }

        QIODevice *audioStream = audioSource->start();
        if (audioStream == nullptr) {
            status->setText("Microphone capture could not be started.");
            return;
        }

        microphoneMeterRunning = true;
        QObject::connect(audioStream, &QIODevice::readyRead, audioStream,
            [audioStream, format, microphoneLevel]() {
                const QAudioBuffer buffer(audioStream->readAll(), format);
                microphoneLevel->setValue(qRound(calculateRms(buffer) * 100));
            });
    };
    auto stopMicrophoneMeter = [&]() {
        if (!microphoneMeterRunning) {
            return;
        }
        audioSource->stop();
        microphoneMeterRunning = false;
    };

    if (inputDevice.isNull() || !format.isValid()) {
        status->setText("No microphone device was found.");
    } else {
        startMicrophoneMeter();
    }

    GstElement *pipeline = nullptr;
    GstBus *bus = nullptr;
    bool portrait = false;
    bool cameraReady = false;
    bool recordingActive = false;
    bool recordingFinalizing = false;
    QString recordingPath;

    auto stopPipeline = [&]() {
        if (pipeline != nullptr) {
            gst_element_set_state(pipeline, GST_STATE_NULL);
            gst_object_unref(pipeline);
            pipeline = nullptr;
        }
        if (bus != nullptr) {
            gst_object_unref(bus);
            bus = nullptr;
        }
    };

    auto startPipeline = [&](const QString &description, QString *errorMessage) {
        stopPipeline();
        GError *error = nullptr;
        GstElement *newPipeline = gst_parse_launch(
            description.toUtf8().constData(),
            &error);
        if (newPipeline == nullptr || error != nullptr) {
            *errorMessage = error != nullptr
                ? QString::fromUtf8(error->message)
                : "Could not create the GStreamer pipeline.";
            if (error != nullptr) {
                g_error_free(error);
            }
            if (newPipeline != nullptr) {
                gst_object_unref(newPipeline);
            }
            return false;
        }

        g_signal_connect(
            newPipeline,
            "deep-element-added",
            G_CALLBACK(onDeepElementAdded),
            preview->videoSurface());
        bus = gst_element_get_bus(newPipeline);
        const GstStateChangeReturn stateResult =
            gst_element_set_state(newPipeline, GST_STATE_PLAYING);
        if (stateResult == GST_STATE_CHANGE_FAILURE) {
            gst_object_unref(bus);
            bus = nullptr;
            gst_element_set_state(newPipeline, GST_STATE_NULL);
            gst_object_unref(newPipeline);
            *errorMessage = "GStreamer could not start the pipeline.";
            return false;
        }

        pipeline = newPipeline;
        return true;
    };

    auto startPreviewPipeline = [&](QString *errorMessage) {
        const QString description =
            videoCompositionDescription(portrait) + " video. ! autovideosink";
        if (!startPipeline(description, errorMessage)) {
            cameraReady = false;
            recordButton->setEnabled(false);
            return false;
        }
        cameraReady = true;
        recordButton->setEnabled(true);
        stopButton->setEnabled(false);
        return true;
    };

    auto setOrientation = [&](bool usePortrait) {
        if (recordingActive || recordingFinalizing || portrait == usePortrait) {
            return;
        }
        portrait = usePortrait;
        preview->setPortrait(portrait);
        QString errorMessage;
        if (!startPreviewPipeline(&errorMessage)) {
            status->setText(QString("Camera unavailable: %1").arg(errorMessage));
        } else {
            status->setText(portrait
                ? "Live preview active - vertical 9:16."
                : "Live preview active - horizontal 16:9.");
        }
    };

    QObject::connect(horizontalButton, &QPushButton::clicked, &window,
        [&]() { setOrientation(false); });
    QObject::connect(verticalButton, &QPushButton::clicked, &window,
        [&]() { setOrientation(true); });

    QObject::connect(recordButton, &QPushButton::clicked, &window, [&]() {
        if (!cameraReady || recordingActive || recordingFinalizing) {
            status->setText("Camera is not ready to record.");
            return;
        }

        const QString recordingDirectory = QDir::home().filePath("Videos/ZenStream");
        if (!QDir().mkpath(recordingDirectory)) {
            status->setText("Could not create ~/Videos/ZenStream.");
            return;
        }

        const QString fileName = QString("ZenStream-%1.mp4")
            .arg(QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss-zzz"));
        recordingPath = QDir(recordingDirectory).filePath(fileName);
        stopMicrophoneMeter();

        QString errorMessage;
        const QString description = recordingPipelineDescription(portrait, recordingPath);
        if (!startPipeline(description, &errorMessage)) {
            startMicrophoneMeter();
            QString previewError;
            if (!startPreviewPipeline(&previewError)) {
                errorMessage += QString("; preview restart failed: %1").arg(previewError);
            }
            status->setText(QString("Recording could not start: %1").arg(errorMessage));
            return;
        }

        recordingActive = true;
        recordButton->setEnabled(false);
        stopButton->setEnabled(true);
        horizontalButton->setEnabled(false);
        verticalButton->setEnabled(false);
        status->setText(QString("Recording composed output to %1").arg(recordingPath));
    });

    QObject::connect(stopButton, &QPushButton::clicked, &window, [&]() {
        if (!recordingActive || pipeline == nullptr) {
            return;
        }

        recordingFinalizing = true;
        stopButton->setEnabled(false);
        status->setText("Finalizing MP4 recording...");
        if (!gst_element_send_event(pipeline, gst_event_new_eos())) {
            recordingActive = false;
            recordingFinalizing = false;
            stopPipeline();
            startMicrophoneMeter();
            QString errorMessage;
            if (startPreviewPipeline(&errorMessage)) {
                status->setText("Could not finalize the MP4 recording.");
            } else {
                status->setText(QString("Could not finalize recording or restart preview: %1")
                    .arg(errorMessage));
            }
            horizontalButton->setEnabled(true);
            verticalButton->setEnabled(true);
        }
    });

    QTimer busTimer;
    QObject::connect(&busTimer, &QTimer::timeout, &window, [&]() {
        if (bus == nullptr) {
            return;
        }

        while (GstMessage *message = gst_bus_pop_filtered(
                   bus,
                   static_cast<GstMessageType>(GST_MESSAGE_ERROR | GST_MESSAGE_EOS))) {
            const GstMessageType messageType = GST_MESSAGE_TYPE(message);
            if (messageType == GST_MESSAGE_ERROR) {
                GError *error = nullptr;
                gchar *debugInformation = nullptr;
                gst_message_parse_error(message, &error, &debugInformation);
                const QString errorText = error != nullptr
                    ? QString::fromUtf8(error->message)
                    : "Unknown GStreamer error.";
                if (error != nullptr) {
                    g_error_free(error);
                }
                g_free(debugInformation);
                gst_message_unref(message);

                const bool failedRecording = recordingActive || recordingFinalizing;
                recordingActive = false;
                recordingFinalizing = false;
                stopPipeline();
                if (failedRecording) {
                    startMicrophoneMeter();
                    QString previewError;
                    if (!startPreviewPipeline(&previewError)) {
                        status->setText(QString("GStreamer failed: %1; preview failed: %2")
                            .arg(errorText, previewError));
                    } else {
                        status->setText(QString("GStreamer failed: %1").arg(errorText));
                    }
                    horizontalButton->setEnabled(true);
                    verticalButton->setEnabled(true);
                } else {
                    cameraReady = false;
                    recordButton->setEnabled(false);
                    status->setText(QString("Camera pipeline failed: %1").arg(errorText));
                }
                break;
            }

            gst_message_unref(message);
            if (recordingActive || recordingFinalizing) {
                recordingActive = false;
                recordingFinalizing = false;
                stopPipeline();
                startMicrophoneMeter();
                QString previewError;
                if (startPreviewPipeline(&previewError)) {
                    status->setText(QString("Recording saved to %1").arg(recordingPath));
                } else {
                    status->setText(QString("Recording saved to %1; preview restart failed: %2")
                        .arg(recordingPath, previewError));
                }
                horizontalButton->setEnabled(true);
                verticalButton->setEnabled(true);
                break;
            }

            stopPipeline();
            cameraReady = false;
            recordButton->setEnabled(false);
            status->setText("Camera stream ended.");
            break;
        }
    });
    busTimer.start(100);

    window.setCentralWidget(central);
    window.resize(760, 700);
    window.setWindowTitle("ZenStream");
    window.show();
    preview->videoSurface()->winId();
    QTimer::singleShot(0, &window, [&]() {
        QString errorMessage;
        if (startPreviewPipeline(&errorMessage)) {
            status->setText("Live preview active - horizontal 16:9.");
        } else {
            status->setText(QString("Camera unavailable: %1").arg(errorMessage));
        }
    });
    const int exitCode = app.exec();
    busTimer.stop();
    stopPipeline();
    stopMicrophoneMeter();
    return exitCode;
}
