#include <QApplication>
#include <QAudioBuffer>
#include <QAudioDevice>
#include <QAudioFormat>
#include <QAudioSource>
#include <QCamera>
#include <QIODevice>
#include <QLabel>
#include <QMainWindow>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QProgressBar>
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

    if (QMediaDevices::videoInputs().isEmpty()) {
        status->setText("No camera device was found.");
    } else {
        auto *camera = new QCamera(QMediaDevices::defaultVideoInput(), &window);
        auto *captureSession = new QMediaCaptureSession(&window);
        captureSession->setCamera(camera);
        captureSession->setVideoOutput(preview);
        QObject::connect(camera, &QCamera::errorOccurred, &window,
            [status](QCamera::Error, const QString &errorString) {
                status->setText(QString("Camera unavailable: %1").arg(errorString));
            });
        camera->start();
    }

    const QAudioDevice inputDevice = QMediaDevices::defaultAudioInput();
    const QAudioFormat format = inputDevice.preferredFormat();
    if (inputDevice.isNull() || !format.isValid()) {
        status->setText(status->text().isEmpty()
            ? "No microphone device was found."
            : status->text() + "\nNo microphone device was found.");
    } else {
        auto *audioSource = new QAudioSource(inputDevice, format, &window);
        QIODevice *audioInput = audioSource->start();
        if (audioInput == nullptr) {
            status->setText(status->text().isEmpty()
                ? "Microphone capture could not be started."
                : status->text() + "\nMicrophone capture could not be started.");
        } else {
            QObject::connect(audioInput, &QIODevice::readyRead, &window,
                [audioInput, format, microphoneLevel]() {
                    const QAudioBuffer buffer(audioInput->readAll(), format);
                    microphoneLevel->setValue(qRound(calculateRms(buffer) * 100));
                });
        }
    }

    window.setCentralWidget(central);
    window.resize(760, 560);
    window.setWindowTitle("ZenStream");
    window.show();
    return app.exec();
}
