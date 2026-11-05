#include "UavControlModeTest.h"

#include <utility>

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
    bool       holdSetModeReplies = false;
    QList<QByteArray> setModeBodies;

    void releaseHeldReplies()
    {
        holdSetModeReplies = false;
        for (QTcpSocket* socket : std::exchange(_heldSockets, {})) {
            _reply(socket, setModeStatus, R"({"status":"x"})");
        }
    }

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
            if (holdSetModeReplies) {
                _buffers.remove(socket);
                _heldSockets.append(socket);
                return;
            }
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
    QList<QTcpSocket*> _heldSockets;
};

constexpr int kPollHz = 20;
constexpr int kPollsToSettle = 2;  // the first may have been answered before the change under test
constexpr auto kAutoAi08 = R"({"board_status":false,"message":"","control_mode":"auto","control_ai":0.8})";
constexpr auto kManualAi08 = R"({"board_status":false,"message":"","control_mode":"manual","control_ai":0.8})";

QJsonObject sentBody(const UavServerStub& server, qsizetype index)
{
    return QJsonDocument::fromJson(server.setModeBodies.at(index)).object();
}

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
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual"})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual"), TestTimeout::mediumMs());
    QCOMPARE(changed.count(), 1);
}

void UavControlModeTest::_unknownWhenServerStopsReporting()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual"})";
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual"), TestTimeout::mediumMs());

    // A server without the field, as before this feature
    server.uavInfoBody = R"({"board_status":false,"message":""})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QString(), TestTimeout::mediumMs());

    // A value that is not a known mode
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"xyz"})";
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
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(finished.at(0).at(0).toBool(), true);

    QCOMPARE(server.setModeBodies.count(), 1);
    const QJsonObject first = QJsonDocument::fromJson(server.setModeBodies.at(0)).object();
    QCOMPARE(first.value("mode").toString(), QStringLiteral("manual"));
    QCOMPARE(first.value("seq").toInt(), 1);
    QVERIFY(first.value("timestamp_utc").toString().endsWith(QLatin1Char('Z')));

    // A sent change does not show as the current mode until the server reports it
    QSignalSpy polls(vehicle(), &Vehicle::uavInfoReceived);
    QTRY_VERIFY_WITH_TIMEOUT(polls.count() >= kPollsToSettle, TestTimeout::mediumMs());
    QCOMPARE(vehicle()->uavControlMode(), QStringLiteral("auto"));

    vehicle()->sendUavControlMode(QStringLiteral("auto"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, TestTimeout::mediumMs());
    QCOMPARE(QJsonDocument::fromJson(server.setModeBodies.at(1)).object().value("seq").toInt(), 2);
}

void UavControlModeTest::_reportsFailedModeChange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.setModeStatus = 500;
    vehicle()->GetUAVInfo(server.url(), kPollHz);

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
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
    vehicle()->sendUavControlMode(QStringLiteral("xyz"));
    verifyExpectedLogMessage();
    QSignalSpy polls(vehicle(), &Vehicle::uavInfoReceived);
    QTRY_VERIFY_WITH_TIMEOUT(polls.count() >= kPollsToSettle, TestTimeout::mediumMs());
    QCOMPARE(finished.count(), 0);
    QVERIFY(server.setModeBodies.isEmpty());
}

void UavControlModeTest::_followsReportedAi()
{
    UavServerStub server;
    QVERIFY(server.listen());
    QVERIFY(vehicle()->uavControlAi() < 0);

    server.uavInfoBody = kAutoAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.8, TestTimeout::mediumMs());

    // Out of range is not a value to show
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto","control_ai":1.5})";
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->uavControlAi() < 0, TestTimeout::mediumMs());

    server.uavInfoBody = kAutoAi08;
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.8, TestTimeout::mediumMs());

    // A server without the field, as before this feature
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto"})";
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->uavControlAi() < 0, TestTimeout::mediumMs());

    server.uavInfoBody = kAutoAi08;
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.8, TestTimeout::mediumMs());
    server.close();
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->uavControlAi() < 0, TestTimeout::mediumMs());
}

void UavControlModeTest::_modeChangeCarriesAi()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = kAutoAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.8, TestTimeout::mediumMs());

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(sentBody(server, 0).value("mode").toString(), QStringLiteral("manual"));
    QCOMPARE(sentBody(server, 0).value("ai").toDouble(), 0.8);

    // Unknown value: the mode must still go out, without a made-up value
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"manual"})";
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->uavControlAi() < 0, TestTimeout::mediumMs());
    vehicle()->sendUavControlMode(QStringLiteral("auto"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, TestTimeout::mediumMs());
    QVERIFY(!sentBody(server, 1).contains("ai"));
}

void UavControlModeTest::_postsAiChange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = kAutoAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.8, TestTimeout::mediumMs());

    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlAi(0.5);
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(finished.at(0).at(0).toBool(), true);

    const QJsonObject body = sentBody(server, 0);
    QCOMPARE(body.value("mode").toString(), QStringLiteral("auto"));
    QCOMPARE(body.value("ai").toDouble(), 0.5);
    QCOMPARE(body.value("seq").toInt(), 1);

    // A sent value does not show as the current one until the server reports it
    QCOMPARE(vehicle()->uavControlAi(), 0.8);
    server.uavInfoBody = R"({"board_status":false,"message":"","control_mode":"auto","control_ai":0.5})";
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlAi(), 0.5, TestTimeout::mediumMs());
}

void UavControlModeTest::_refusesAiOutsideAutoOrRange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = kManualAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual"), TestTimeout::mediumMs());

    expectLogMessage("Vehicle.Vehicle", QtWarningMsg, QRegularExpression("not settled in auto mode"));
    vehicle()->sendUavControlAi(0.5);
    verifyExpectedLogMessage();

    server.uavInfoBody = kAutoAi08;
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());
    for (const double ai : {-0.1, 1.1, qQNaN()}) {
        expectLogMessage("Vehicle.Vehicle", QtWarningMsg, QRegularExpression("Invalid UAV control AI value"));
        vehicle()->sendUavControlAi(ai);
        verifyExpectedLogMessage();
    }

    // Only this one reaches the server
    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlAi(0.5);
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(server.setModeBodies.count(), 1);
    QCOMPARE(sentBody(server, 0).value("ai").toDouble(), 0.5);
}

void UavControlModeTest::_aiCannotUndoUnconfirmedModeChange()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = kAutoAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());

    // Accepted by the server, but the last report still says auto
    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, TestTimeout::mediumMs());
    QCOMPARE(vehicle()->uavControlMode(), QStringLiteral("auto"));

    expectLogMessage("Vehicle.Vehicle", QtWarningMsg, QRegularExpression("not settled in auto mode"));
    vehicle()->sendUavControlAi(0.5);
    verifyExpectedLogMessage();
    QCOMPARE(server.setModeBodies.count(), 1);

    // Allowed again once the server has settled back in auto
    server.uavInfoBody = kManualAi08;
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("manual"), TestTimeout::mediumMs());
    vehicle()->sendUavControlMode(QStringLiteral("auto"));
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, TestTimeout::mediumMs());
    server.uavInfoBody = kAutoAi08;
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());
    vehicle()->sendUavControlAi(0.5);
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 3, TestTimeout::mediumMs());
    QCOMPARE(sentBody(server, 2).value("ai").toDouble(), 0.5);
}

void UavControlModeTest::_keepsRequestsInOrder()
{
    UavServerStub server;
    QVERIFY(server.listen());
    server.uavInfoBody = kAutoAi08;
    vehicle()->GetUAVInfo(server.url(), kPollHz);
    QTRY_COMPARE_WITH_TIMEOUT(vehicle()->uavControlMode(), QStringLiteral("auto"), TestTimeout::mediumMs());

    server.holdSetModeReplies = true;
    vehicle()->sendUavControlAi(0.5);
    QTRY_COMPARE_WITH_TIMEOUT(server.setModeBodies.count(), 1, TestTimeout::mediumMs());

    // Both wait for the first; only the newest goes out, and it is the one that says manual
    QSignalSpy finished(vehicle(), &Vehicle::uavControlModeSendFinished);
    vehicle()->sendUavControlAi(0.6);
    vehicle()->sendUavControlMode(QStringLiteral("manual"));
    QCOMPARE(server.setModeBodies.count(), 1);

    server.releaseHeldReplies();
    QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, TestTimeout::mediumMs());
    QCOMPARE(server.setModeBodies.count(), 2);
    QCOMPARE(sentBody(server, 1).value("mode").toString(), QStringLiteral("manual"));
}

#include "UnitTest.h"

UT_REGISTER_TEST(UavControlModeTest, TestLabel::Integration, TestLabel::Vehicle)
