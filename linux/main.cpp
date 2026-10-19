#include <QApplication>
#include <QLabel>
#include <QMainWindow>
#include <QVBoxLayout>
#include <QWidget>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    QMainWindow window;
    auto *central = new QWidget(&window);
    auto *layout = new QVBoxLayout(central);
    auto *title = new QLabel("ZenStream Studio");
    title->setStyleSheet("font-size: 24px; font-weight: 600;");
    auto *status = new QLabel(
        "Native Linux starter\n\n"
        "Next: add camera/microphone capture, scene layouts, recording, and streaming output.");
    status->setWordWrap(true);
    layout->addWidget(title);
    layout->addWidget(status);
    window.setCentralWidget(central);
    window.resize(760, 480);
    window.setWindowTitle("ZenStream");
    window.show();
    return app.exec();
}
