#include <QApplication>
#include <QMouseEvent>
#include <QPainter>
#include <QWidget>
#include <fstream>
class Counter : public QWidget {
  std::string path;
  int presses = 0, releases = 0;
  void record(const char *kind, QMouseEvent *e) {
    std::ofstream(path, std::ios::app)
        << kind << " " << int(e->button()) << std::endl;
    update();
  }
  void mousePressEvent(QMouseEvent *e) override {
    ++presses;
    record("press", e);
  }
  void mouseReleaseEvent(QMouseEvent *e) override {
    ++releases;
    record("release", e);
  }
  void paintEvent(QPaintEvent *) override {
    QPainter p(this);
    p.fillRect(rect(), QColor("#24364b"));
    p.setPen(Qt::white);
    p.drawText(rect(), Qt::AlignCenter,
               QString("Presses: %1  Releases: %2").arg(presses).arg(releases));
  }

public:
  Counter(const char *p) : path(p) { resize(1000, 700); }
};
int main(int argc, char **argv) {
  QApplication app(argc, argv);
  app.setDesktopFileName("stage-click-counter");
  Counter w(argv[1]);
  w.setWindowTitle(argv[2]);
  w.show();
  return app.exec();
}
