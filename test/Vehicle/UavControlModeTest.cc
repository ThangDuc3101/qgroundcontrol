#include "UavControlModeTest.h"

#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtNetwork/QHostAddress>
#include <QtNetwork/QTcpServer>
#include <QtNetwork/QTcpSocket>
#include <QtTest/QSignalSpy>

#include "Vehicle.h"

namespace {

// The companion computer's HTTP server: GET /uav_info and POST /set_mode
class UavServerStub : public QObject
{
public:
    UavServerStub()
    {
        connect(&_server, &QTcpServer::newConnection, this, [this]() {
            while (QTcpSocket* socket = _server.nextPendingConnection()) {
                connect(socket, &QTcpSocket::readyRead, this, [this, socket]() { _onReadyRead(socket); });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
    }

    bool listen() { return _server.listen(QHostAddress::LocalHost); }
    void close() { _server.close(); }
    QString url() const { return QStringLiteral("http://127.0.0.1:%1/uav_info").arg(_server.serverPort()); }

    QByteArray uavInfoBody = R"({"board_status":false,"message":""})";
    int        setModeStatus = 200;
    QList<QByteArray> setModeBodies;

private:
    void _onReadyRead(QTcpSocket* socket)
    {
        QByteArray& request = _buffers[socket];
        request += socket->readAll();

        const qsizetype headerEnd = request.indexOf("\r\n\r\n");
        if (headerEnd < 0) {
            return;
        }
        const QByteArray lowerHeaders = request.left(headerEnd).toLower();
        const qsizetype lengthPos = lowerHeaders.indexOf("content-length:");
        qsizetype bodyLength = 0;
        if (lengthPos >= 0) {
            const qsizetype lineEnd = lowerHeaders.indexOf("\r\n", lengthPos);
            bodyLength = lowerHeaders.mid(lengthPos + 15, lineEnd < 0 ? -1 : lineEnd - lengthPos - 15).trimmed().toLongLong();
        }
        const QByteArray body = request.mid(headerEnd + 4);
        if (body.size() < bodyLength) {
            return;
        }

        int status = 404;
        QByteArray responseBody;
        if (request.startsWith("GET /uav_info")) {
            status = 200;
            responseBody = uavInfoBody;
        } else if (request.startsWith("POST /set_mode")) {
            setModeBodies.append(body);
            status = setModeStatus;
            responseBody = R"({"status":"x"})";
        }
        _buffers.remove(socket);
        _reply(socket, status, responseBody);
    }

    void _reply(QTcpSocket* socket, int status, const QByteArray& responseBody)
    {
        socket->write(QByteArray("HTTP/1.1 ") + QByteArray::number(status) + " X\r\nContent-Type: application/json\r\nContent-Length: "
                      + QByteArray::number(responseBody.size()) + "\r\nConnection: close\r\n\r\n" + responseBody);
        socket->disconnectFromHost();
    }

    QTcpServer _server;
    QHash<QTcpSocket*, QByteArray> _buffers;
};

constexpr int kPollHz = 20;
constexpr int kPollsToSettle = 2;  // the first may have been answered before the change under test

}  // namespace

void UavControlModeTest::_followsReportedMode()
{
    UavServerStub server;
    QVERIFY(server.listen());
    QCOMPARE(vehicle()->uavControlMode(), QString());

    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto"})";
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());

    QSignalSpy changed(vehicle(), &Vehicle::uavControlModeChanged);
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual_gps"})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual_gps"), TestTimeout::mediumMs());
    QCOMPARE(changed.count(), 1);

    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual_image"})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual_image"), TestTimeout::mediumMs());
    QCOMPARE(changed.count(), 2);
}

void UavControlModeTest::_unknownWhenServerStopsReporting()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual_gps"})";
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual_gps"), TestTimeout::mediumMs());

    // A server without the field, as before this feature
    server.uavInfoBody = R"({"board_status":false,"message":""})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QString(), TestTimeout::mediumMs());

    // A value that is not a known mode, such as the single manual mode of an older server
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual"})";
    QSignalSpy polls(vehicle(), &Vehicle::uavInfoReceived);
    QTRY_VERIFY_WITH_TIMEOUT(polls.count() >= kPollsToSettle, TestTimeout::mediumMs());
    QCOMPARE(vehicle()->uavControlMode(), QString());

    // Server gone
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto"})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());
    server.close();
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QString(), TestTimeout::mediumMs());
}

void UavControlModeTest::_postsModeChange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto"})";
    vehicle()->GetUAVInfo(server.url(), kPollHz);

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlMode(QStringLiteral("manual_gps"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(finished.at(0).at(0).toBool(), true);

    QCOMPARE(server.setModeBodies.count(), 1);
    const QJsonObject first = QJsonDocument::fromJson(server.setModeBodies.at(0)).object();
    QCOMPARE(first.value("mode").toString(), QStringLiteral("manual_gps"));
    QCOMPARE(first.value("seq").toInt(), 1);
    QVERIFY(first.value("timestamp_utc").toString().endsWith(QLatin1Char('Z')));
    QCOMPARE(first.size(), 3);

    // A sent change does not show as the current mode until the server reports it
    QSignalSpy polls(vehicle(), &Vehicle::uavInfoReceived);
    QTRY_VERIFY_WITH_TIMEOUT(polls.count() >= kPollsToSettle, TestTimeout::mediumMs());
    QCOMPARE(vehicle()->uavControlMode(), QStringLiteral("auto"));

    vehicle()->sendUavControlMode(QStringLiteral("manual_image"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, TestTimeout::mediumMs());
    const QJsonObject second = QJsonDocument::fromJson(server.setModeBodies.at(1)).object();
    QCOMPARE(second.value("mode").toString(), QStringLiteral("manual_image"));
    QCOMPARE(second.value("seq").toInt(), 2);
}

void UavControlModeTest::_reportsFailedModeChange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.setModeStatus = 500;
    vehicle()->GetUAVInfo(server.url(), kPollHz);

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlMode(QStringLiteral("manual_gps"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(finished.at(0).at(0).toBool(), false);
    QVERIFY(!finished.at(0).at(1).toString().isEmpty());
}

void UavControlModeTest::_refusesUnknownMode()
{
    UavServerStub server;
    QVERIFY(server.listen());
    vehicle()->GetUAVInfo(server.url(), kPollHz);

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    expectLogMessage("Vehicle.Vehicle", QtWarningMsg, QRegularExpression("Invalid UAV control mode"));
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
    verifyExpectedLogMessage();
    QSignalSpy polls(vehicle(), &Vehicle::uavInfoReceived);
    QTRY_VERIFY_WITH_TIMEOUT(polls.count() >= kPollsToSettle, TestTimeout::mediumMs());
    QCOMPARE(finished.count(), 0);
    QVERIFY(server.setModeBodies.isEmpty());
}

#include "UnitTest.h"

UT_REGISTER_TEST(UavControlModeTest, TestLabel::Integration, TestLabel::Vehicle)
