#include <QApplication>
#include <QLabel>
#include <QtPositioning/QGeoCoordinate>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QGeoCoordinate point(37.7749, -122.4194);
    QLabel label(QString("Qt %1 on FoxynBSD\nQtPositioning: %2, %3")
        .arg(QT_VERSION_STR).arg(point.latitude()).arg(point.longitude()));
    label.setWindowTitle("Qt 6 smoke test");
    label.resize(440, 120);
    label.show();
    return app.exec();
}
