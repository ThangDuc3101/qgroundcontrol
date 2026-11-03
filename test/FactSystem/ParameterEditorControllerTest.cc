#include "ParameterEditorControllerTest.h"

#include <QtCore/QString>
#include <QtCore/QRegularExpression>
#include <QtTest/QTest>
#include <QtTest/QSignalSpy>

#include "ParameterEditorController.h"
#include "QmlObjectListModel.h"
#include "Fixtures/RAIIFixtures.h"
#include "UnitTest.h"

UT_REGISTER_TEST(ParameterEditorControllerTest, TestLabel::Integration, TestLabel::Vehicle)

// QGC tab-delimited file with SYS_AUTOSTART changed from 4001 → 4002
static const char* kQGCParamsWithDiff =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\tSYS_AUTOSTART\t4002\t6\n";

// QGC tab-delimited file with SYS_AUTOSTART matching vehicle default (4001)
static const char* kQGCParamsNoDiff =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\tSYS_AUTOSTART\t4001\t6\n";

// Mission Planner 2-column file with same diff
static const char* kMPParamsWithDiff =
    "# Mission Planner parameter file\n"
    "SYS_AUTOSTART,4002\n";

// Mission Planner 2-column file matching vehicle default
static const char* kMPParamsNoDiff =
    "# Mission Planner parameter file\n"
    "SYS_AUTOSTART,4001\n";

// Mission Planner 2-column file with a parameter not on the vehicle
static const char* kMPParamsMissingParam =
    "# Mission Planner parameter file\n"
    "NONEXISTENT_PARAM_XYZ,1\n";

// Garbage — no parseable lines
static const char* kBadFormatParams =
    "This is not a parameter file\n"
    "random text here\n";

// QGC file with a parameter that does not exist on the (PX4 mock) vehicle
static const char* kQGCParamsUnknownParam =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\tNONEXISTENT_PARAM_XYZ\t1\t6\n";

static const char* kQGCParamsHashCheck =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\t_HASH_CHECK\t-1530949660\t6\n"
    "1\t1\tNONEXISTENT_PARAM_XYZ\t1\t6\n";

// Sensor calibration values that differ from the PX4 mock vehicle, plus two ordinary differences
static const char* kQGCParamsWithCalibration =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\tCAL_ACC0_XOFF\t0.5\t9\n"
    "1\t1\tCAL_GYRO0_ID\t999\t6\n"
    "1\t1\tSENS_BOARD_X_OFF\t1.5\t9\n"
    "1\t1\tSENS_DPRES_OFF\t2.0\t9\n"
    "1\t1\tASPD_SCALE_1\t1.3\t9\n"
    "1\t1\tTC_A0_ID\t5\t6\n"
    "1\t1\tSENS_BOARD_ROT\t2\t6\n"
    "1\t1\tSYS_AUTOSTART\t4002\t6\n";

// Flight counters and learned declination that differ from the PX4 mock vehicle, the declination mode (configuration)
// and an ordinary difference
static const char* kQGCParamsWithRuntimeValues =
    "# Onboard parameters for Vehicle 1\n"
    "#\n"
    "# Vehicle-Id Component-Id Name Value Type\n"
    "1\t1\tCOM_FLIGHT_UUID\t865\t6\n"
    "1\t1\tLND_FLIGHT_T_HI\t1\t6\n"
    "1\t1\tLND_FLIGHT_T_LO\t5\t6\n"
    "1\t1\tEKF2_MAG_DECL\t-1.73\t9\n"
    "1\t1\tEKF2_DECL_TYPE\t0\t6\n"
    "1\t1\tSYS_AUTOSTART\t4002\t6\n";

void ParameterEditorControllerTest::_buildDiffQGCFormat()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsWithDiff)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    QCOMPARE(controller.diffList()->count(), 1);
    const auto* diff = controller.diffList()->value<ParameterEditorDiff*>(0);
    QVERIFY(diff);
    QCOMPARE(diff->name, QStringLiteral("SYS_AUTOSTART"));
}

void ParameterEditorControllerTest::_buildDiffMPFormat()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.param"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kMPParamsWithDiff)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    QCOMPARE(controller.diffList()->count(), 1);
    const auto* diff = controller.diffList()->value<ParameterEditorDiff*>(0);
    QVERIFY(diff);
    QCOMPARE(diff->name, QStringLiteral("SYS_AUTOSTART"));
}

void ParameterEditorControllerTest::_buildDiffNoDifferencesQGC()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsNoDiff)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    QCOMPARE(controller.diffList()->count(), 0);
}

void ParameterEditorControllerTest::_buildDiffNoDifferencesMP()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.param"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kMPParamsNoDiff)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    QCOMPARE(controller.diffList()->count(), 0);
}

void ParameterEditorControllerTest::_buildDiffBadFormat()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.txt"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kBadFormatParams)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    expectAppMessage(QRegularExpression("No valid parameters found"));
    const bool result = controller.buildDiffFromFile(tempFile.path());
    verifyExpectedLogMessage();

    QVERIFY(!result);
    QCOMPARE(controller.diffList()->count(), 0);
}

void ParameterEditorControllerTest::_buildDiffMissingOnVehicle()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsUnknownParam)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    QCOMPARE(controller.diffList()->count(), 1);
    const auto* diff = controller.diffList()->value<ParameterEditorDiff*>(0);
    QVERIFY(diff);
    QVERIFY(diff->noVehicleValue);
    QCOMPARE(diff->name, QStringLiteral("NONEXISTENT_PARAM_XYZ"));
}

void ParameterEditorControllerTest::_buildDiffMPMissingParam()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.param"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kMPParamsMissingParam)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    QSignalSpy missingSpy(&controller, &ParameterEditorController::missingParamsFromFile);
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    // Unknown MP param is skipped — diff list stays empty
    QCOMPARE(controller.diffList()->count(), 0);
    // Signal emitted once with the missing param name
    QCOMPARE(missingSpy.count(), 1);
    const QStringList missingParams = missingSpy.at(0).at(0).toStringList();
    QCOMPARE(missingParams.count(), 1);
    QCOMPARE(missingParams.at(0), QStringLiteral("NONEXISTENT_PARAM_XYZ"));
}

void ParameterEditorControllerTest::_buildDiffSkipsHashCheck()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsHashCheck)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    const bool result = controller.buildDiffFromFile(tempFile.path());

    QVERIFY(result);
    // PX4's virtual _HASH_CHECK line is ignored; only the genuinely unknown param is reported
    QCOMPARE(controller.diffList()->count(), 1);
    const auto* diff = controller.diffList()->value<ParameterEditorDiff*>(0);
    QVERIFY(diff);
    QCOMPARE(diff->name, QStringLiteral("NONEXISTENT_PARAM_XYZ"));
}

void ParameterEditorControllerTest::_buildDiffSkipsSensorCalibration()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsWithCalibration)));
    QVERIFY(tempFile.file()->flush());

    ParameterEditorController controller;
    controller.setProperty("diffSkipSensorCalibration", true);
    QVERIFY(controller.buildDiffFromFile(tempFile.path()));

    // Only the ordinary differences are compared; board rotation is mounting config, not calibration
    QStringList diffNames;
    for (int i = 0; i < controller.diffList()->count(); i++) {
        diffNames.append(controller.diffList()->value<ParameterEditorDiff*>(i)->name);
    }
    diffNames.sort();
    QCOMPARE(diffNames, QStringList({QStringLiteral("SENS_BOARD_ROT"), QStringLiteral("SYS_AUTOSTART")}));

    QStringList skipped = controller.diffSkippedParams();
    skipped.sort();
    QCOMPARE(skipped, QStringList({QStringLiteral("ASPD_SCALE_1"), QStringLiteral("CAL_ACC0_XOFF"), QStringLiteral("CAL_GYRO0_ID"),
                                   QStringLiteral("SENS_BOARD_X_OFF"), QStringLiteral("SENS_DPRES_OFF"), QStringLiteral("TC_A0_ID")}));

    controller.clearDiff();
    QVERIFY(controller.diffSkippedParams().isEmpty());
}

void ParameterEditorControllerTest::_buildDiffComparesCalibrationByDefault()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsWithCalibration)));
    QVERIFY(tempFile.file()->flush());

    // The Parameters page "Load from file" (restoring a backup) keeps comparing everything
    ParameterEditorController controller;
    QVERIFY(controller.buildDiffFromFile(tempFile.path()));
    QCOMPARE(controller.diffList()->count(), 8);
    QVERIFY(controller.diffSkippedParams().isEmpty());
}

void ParameterEditorControllerTest::_isSensorCalibrationParam()
{
    for (const char* name : {"CAL_ACC0_XOFF", "CAL_MAG1_ID", "CAL_MAG_SIDES", "CAL_BARO0_PRIO", "TC_G0_X0_0", "TC_A_ENABLE",
                             "SENS_BOARD_X_OFF", "SENS_BOARD_Z_OFF", "SENS_DPRES_OFF", "ASPD_SCALE_2"}) {
        QVERIFY2(ParameterEditorController::isSensorCalibrationParam(QString::fromLatin1(name)), name);
    }
    for (const char* name : {"SENS_BOARD_ROT", "SENS_BOARD_X_OFFSET", "MPC_XY_VEL_MAX", "CALX_TEST", "MY_CAL_X", "RC1_TRIM",
                             "ASPD_PRIMARY", "ASPD_SCALE_APPLY", "ASPD_SCALE_NSD", "SYS_AUTOSTART"}) {
        QVERIFY2(!ParameterEditorController::isSensorCalibrationParam(QString::fromLatin1(name)), name);
    }
}

void ParameterEditorControllerTest::_buildDiffSkipsVehicleRuntimeValues()
{
    TestFixtures::TempFileFixture tempFile(QStringLiteral("test_XXXXXX.params"));
    QVERIFY(tempFile.isValid());
    QVERIFY(tempFile.write(QByteArray(kQGCParamsWithRuntimeValues)));
    QVERIFY(tempFile.file()->flush());

    auto diffNames = [](ParameterEditorController& controller) {
        QStringList names;
        for (int i = 0; i < controller.diffList()->count(); i++) {
            names.append(controller.diffList()->value<ParameterEditorDiff*>(i)->name);
        }
        names.sort();
        return names;
    };

    // Runtime values are left out; the declination mode is configuration and still compared
    ParameterEditorController controller;
    controller.setProperty("diffSkipVehicleRuntime", true);
    QVERIFY(controller.buildDiffFromFile(tempFile.path()));
    QCOMPARE(diffNames(controller), QStringList({QStringLiteral("EKF2_DECL_TYPE"), QStringLiteral("SYS_AUTOSTART")}));
    QStringList skipped = controller.diffSkippedRuntimeParams();
    skipped.sort();
    QCOMPARE(skipped, QStringList({QStringLiteral("COM_FLIGHT_UUID"), QStringLiteral("EKF2_MAG_DECL"),
                                   QStringLiteral("LND_FLIGHT_T_HI"), QStringLiteral("LND_FLIGHT_T_LO")}));
    QVERIFY(controller.diffSkippedParams().isEmpty());

    // The two skips are independent: calibration-only skipping keeps comparing runtime values
    ParameterEditorController calibrationOnly;
    calibrationOnly.setProperty("diffSkipSensorCalibration", true);
    QVERIFY(calibrationOnly.buildDiffFromFile(tempFile.path()));
    QCOMPARE(calibrationOnly.diffList()->count(), 6);
    QVERIFY(calibrationOnly.diffSkippedRuntimeParams().isEmpty());

    controller.clearDiff();
    QVERIFY(controller.diffSkippedRuntimeParams().isEmpty());
}

void ParameterEditorControllerTest::_isVehicleRuntimeParam()
{
    for (const char* name : {"COM_FLIGHT_UUID", "LND_FLIGHT_T_HI", "LND_FLIGHT_T_LO", "EKF2_MAG_DECL"}) {
        QVERIFY2(ParameterEditorController::isVehicleRuntimeParam(QString::fromLatin1(name)), name);
    }
    for (const char* name : {"EKF2_DECL_TYPE", "COM_FLIGHT_UUIDX", "LND_FLIGHT_T", "MAV_SYS_ID", "CAL_ACC0_XOFF"}) {
        QVERIFY2(!ParameterEditorController::isVehicleRuntimeParam(QString::fromLatin1(name)), name);
    }
}
