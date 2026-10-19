#include <QApplication>
#include <QAudioBuffer>
#include <QAudioDevice>
#include <QAudioFormat>
#include <QAudioInput>
#include <QAudioSource>
#include <QCamera>
#include <QDateTime>
#include <QDir>
#include <QHBoxLayout>
#include <QIODevice>
#include <QLabel>
#include <QMainWindow>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QMediaRecorder>
#include <QProgressBar>
#include <QPushButton>
#include <QUrl>
#include <QVideoWidget>
#include <QVBoxLayout>
#include <QWidget>
#include <QtMath>

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
}

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QMainWindow window;
    auto *central = new QWidget(&window);
    auto *layout = new QVBoxLayout(central);

    auto *title = new QLabel("ZenStream Studio");
    title->setStyleSheet("font-size: 24px; font-weight: 600;");
    layout->addWidget(title);

    auto *preview = new QVideoWidget(central);
    preview->setMinimumSize(480, 270);
    layout->addWidget(preview, 1);

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
    stopButton->setEnabled(false);
    auto *recordingControls = new QWidget(central);
    auto *recordingLayout = new QHBoxLayout(recordingControls);
    recordingLayout->setContentsMargins(0, 0, 0, 0);
    recordingLayout->addWidget(recordButton);
    recordingLayout->addWidget(stopButton);
    layout->addWidget(recordingControls);

    auto *captureSession = new QMediaCaptureSession(&window);
    auto *recorder = new QMediaRecorder(&window);
    captureSession->setRecorder(recorder);
    captureSession->setVideoOutput(preview);

    if (QMediaDevices::videoInputs().isEmpty()) {
        status->setText("No camera device was found.");
    } else {
        auto *camera = new QCamera(QMediaDevices::defaultVideoInput(), &window);
        captureSession->setCamera(camera);
        QObject::connect(camera, &QCamera::errorOccurred, &window,
            [status](QCamera::Error, const QString &errorString) {
                status->setText(QString("Camera unavailable: %1").arg(errorString));
            });
        camera->start();
    }

    const QAudioDevice inputDevice = QMediaDevices::defaultAudioInput();
    const QAudioFormat format = inputDevice.preferredFormat();
    auto *audioInput = new QAudioInput(inputDevice, &window);
    captureSession->setAudioInput(audioInput);

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
        status->setText(status->text().isEmpty()
            ? "No microphone device was found."
            : status->text() + "\nNo microphone device was found.");
    } else {
        startMicrophoneMeter();
    }

    bool recordingActive = false;
    QObject::connect(recorder, &QMediaRecorder::recorderStateChanged, &window,
        [&, status, recordButton, stopButton](QMediaRecorder::RecorderState state) {
            if (state == QMediaRecorder::RecordingState) {
                recordingActive = true;
                recordButton->setEnabled(false);
                stopButton->setEnabled(true);
            } else if (state == QMediaRecorder::StoppedState) {
                const bool wasRecording = recordingActive;
                recordingActive = false;
                recordButton->setEnabled(true);
                stopButton->setEnabled(false);
                if (wasRecording) {
                    status->setText("Recording saved to " + recorder->outputLocation().toLocalFile());
                }
                startMicrophoneMeter();
            }
        });
    QObject::connect(recorder, &QMediaRecorder::errorOccurred, &window,
        [&, status, recordButton, stopButton](QMediaRecorder::Error, const QString &errorString) {
            status->setText(QString("Recording failed: %1").arg(errorString));
            recordingActive = false;
            recordButton->setEnabled(true);
            stopButton->setEnabled(false);
            startMicrophoneMeter();
        });

    QObject::connect(recordButton, &QPushButton::clicked, &window, [&]() {
        const QString recordingDirectory = QDir::home().filePath("Videos/ZenStream");
        if (!QDir().mkpath(recordingDirectory)) {
            status->setText("Could not create ~/Videos/ZenStream.");
            return;
        }

        const QString fileName = QString("ZenStream-%1.mp4")
            .arg(QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss-zzz"));
        const QString outputPath = QDir(recordingDirectory).filePath(fileName);
        recorder->setOutputLocation(QUrl::fromLocalFile(outputPath));
        stopMicrophoneMeter();
        recordButton->setEnabled(false);
        status->setText(QString("Starting recording to %1").arg(outputPath));
        recorder->record();
    });
    QObject::connect(stopButton, &QPushButton::clicked, &window, [recorder]() {
        recorder->stop();
    });

    window.setCentralWidget(central);
    window.resize(760, 600);
    window.setWindowTitle("ZenStream");
    window.show();
    return app.exec();
}
