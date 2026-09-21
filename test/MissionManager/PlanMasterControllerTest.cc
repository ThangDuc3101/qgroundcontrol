#include "PlanMasterControllerTest.h"

#include "AppSettings.h"
#include "CoordFixtures.h"
#include "SurveyPlanCreator.h"
#include "MissionManager.h"
#include "MultiSignalSpy.h"
#include "MultiVehicleManager.h"
#include "PlanMasterController.h"
#include "QmlObjectListModel.h"
#include "SettingsManager.h"
#include "SimpleMissionItem.h"
#include "SpeedSection.h"
#include "TakeoffMissionItem.h"
#include "Vehicle.h"

#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QRegularExpression>
#include <QtCore/QTemporaryDir>
#include <QtTest/QSignalSpy>

using namespace TestFixtures;

namespace {
constexpr double kCoordToleranceMeters = 0.5;
constexpr double kValueTolerance = 0.001;
} // namespace

void PlanMasterControllerTest::init()
{
    UnitTest::init();
    MultiVehicleManager::instance()->init();
    _masterController = new PlanMasterController(this);
    _masterController->setFlyView(false);
    _masterController->start();
}

void PlanMasterControllerTest::cleanup()
{
    delete _masterController;
    _masterController = nullptr;
    _disconnectMockLink();
    UnitTest::cleanup();
}

void PlanMasterControllerTest::_testMissionPlannerFileLoad()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QCOMPARE(_masterController->missionController()->visualItems()->count(), 6);
}

void PlanMasterControllerTest::_testTakeoffTextFileLoad()
{
    // Plain-text mission file with home position, takeoff and one waypoint (#13167)
    static const char* kTakeoffMission =
        "QGC WPL 110\r\n"
        "0\t1\t0\t16\t0\t0\t0\t0\t34.577822\t-112.469101\t584.380005\t1\r\n"
        "1\t0\t3\t22\t20.000000\t0.000000\t0.000000\t0.000000\t0.000000\t0.000000\t30.000000\t1\r\n"
        "2\t0\t3\t16\t0.000000\t0.000000\t0.000000\t0.000000\t34.469587\t-112.534801\t90.000000\t1\r\n";

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("TakeoffMission.waypoints"));
    QFile file(filename);
    // No QIODevice::Text: write the CRLF line endings verbatim on all platforms to match
    // the original repro file from the issue.
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(kTakeoffMission) != -1);
    file.close();

    SettingsManager::instance()->appSettings()->offlineEditingFirmwareClass()->setRawValue(QGCMAVLink::FirmwareClassArduPilot);

    _masterController->loadFromFile(filename);

    QmlObjectListModel* visualItems = _masterController->missionController()->visualItems();
    QCOMPARE(visualItems->count(), 3); // Mission settings, takeoff, waypoint

    // The original bug caused the takeoff item to consume the following waypoint line,
    // resulting in a single takeoff item carrying the waypoint's values.
    TakeoffMissionItem* takeoffItem = visualItems->value<TakeoffMissionItem*>(1);
    QVERIFY(takeoffItem);
    QCOMPARE(static_cast<MAV_CMD>(takeoffItem->command()), MAV_CMD_NAV_TAKEOFF);
    QCOMPARE(takeoffItem->missionItem().param7(), 30.0);

    SimpleMissionItem* waypointItem = visualItems->value<SimpleMissionItem*>(2);
    QVERIFY(waypointItem);
    QVERIFY(!waypointItem->isTakeoffItem());
    QCOMPARE(static_cast<MAV_CMD>(waypointItem->command()), MAV_CMD_NAV_WAYPOINT);
    QCOMPARE(waypointItem->missionItem().param7(), 90.0);
}

void PlanMasterControllerTest::_testActiveVehicleChanged()
{
    // The test emits missionManager->error() twice to verify signal propagation.
    // Each emission triggers a showAppMessage debug log via PlanMasterController.
    ignoreLogMessage("API.QGCApplication.AppMessage", QtDebugMsg,
                     QRegularExpression("Mission transfer failed"));
    // There was a defect where the PlanMasterController would, upon a new active vehicle,
    // overzelously disconnect all subscribers interested in the outgoing active vechicle.
    Vehicle* outgoingManagerVehicle = _masterController->managerVehicle();
    // spyMissionManager emulates a subscriber that should not be disconnected when
    // the active vehicle changes
    MultiSignalSpy spyMissionManager;
    spyMissionManager.init(outgoingManagerVehicle->missionManager());
    MultiSignalSpy spyMasterController;
    spyMasterController.init(_masterController);
    // Since MissionManager works with actual vehicles (which we don't have in the test cycle)
    // we have to be a bit creative emulating a signal emitted by a MissionManager.
    emit outgoingManagerVehicle->missionManager()->error(0, "");
    QVERIFY(spyMissionManager.onlyEmittedOnce("error"));
    spyMissionManager.clearSignal("error");
    QVERIFY(spyMissionManager.noneEmitted());

    _connectMockLink(MAV_AUTOPILOT_PX4);
    QVERIFY(spyMasterController.emittedOnce("managerVehicleChanged"));

    emit outgoingManagerVehicle->missionManager()->error(0, "");
    // This signal was affected by the defect - it wouldn't reach the subscriber. Here
    // we make sure it does.
    QVERIFY(spyMissionManager.onlyEmittedOnce("error"));
}

void PlanMasterControllerTest::_testDirtyFlagsMatrix_data()
{
    // Dirty-state transition matrix ("unchanged" means preserve prior value):
    //
    // | State \ Action | Upload OK | Clear | SaveDirty=true | Load plan | Save file OK | Clear save-dirty | Download w/ items | Download empty |
    // |----------------|-----------|-------|----------------|-----------|--------------|------------------|-------------------|----------------|
    // | dirtyForSave   | unchanged | false | true           | false     | false        | false            | false             | false          |
    // | dirtyForUpload | false     | false | true           | true      | unchanged    | unchanged        | false             | false          |

    // Data columns:
    //  - scenario: DirtyScenario enum value selecting which action path to execute
    //  - initialDirtyForSave: initial dirtyForSave state before action (DirtyStateTrue/False)
    //  - initialDirtyForUpload: initial dirtyForUpload state before action (DirtyStateTrue/False)
    //  - expectedDirtyForSave: expected final dirtyForSave state (DirtyState)
    //  - expectedDirtyForUpload: expected final dirtyForUpload state (DirtyState)

    QTest::addColumn<int>("scenario");
    QTest::addColumn<int>("initialDirtyForSave");
    QTest::addColumn<int>("initialDirtyForUpload");
    QTest::addColumn<int>("expectedDirtyForSave");
    QTest::addColumn<int>("expectedDirtyForUpload");

    struct ScenarioExpectation {
        DirtyScenario scenario;
        const char* name;
        DirtyState expectedDirtyForSave;
        DirtyState expectedDirtyForUpload;
    };

    const QList<ScenarioExpectation> scenarioExpectations = {
        { UploadPreservesSaveDirtyFalse,      "upload completion keeps save false",  DirtyStateUnchanged, DirtyStateFalse },
        { UploadPreservesSaveDirtyTrue,       "upload completion keeps save true",   DirtyStateUnchanged, DirtyStateFalse },
        { UploadFalseOnPlanClear,             "upload false on clear",               DirtyStateFalse,     DirtyStateFalse },
        { UploadTrueWhenSaveTrue,             "upload true when save true",          DirtyStateTrue,      DirtyStateTrue },
        { UploadTrueOnNewPlanLoad,            "upload true on new plan load",        DirtyStateFalse,     DirtyStateTrue },
        { SaveToFilePreservesUploadDirtyTrue, "saveToFile keeps upload true",        DirtyStateFalse,     DirtyStateUnchanged },
        { SaveToFilePreservesUploadDirtyFalse,"saveToFile keeps upload false",       DirtyStateFalse,     DirtyStateUnchanged },
        { SaveFalseOnSuccessfulLoad,          "save false on successful load",       DirtyStateFalse,     DirtyStateTrue },
        { ClearSaveDirtyPreservesUploadTrue,  "clear save dirty keeps upload true",  DirtyStateFalse,     DirtyStateUnchanged },
        { ClearSaveDirtyPreservesUploadFalse, "clear save dirty keeps upload false", DirtyStateFalse,     DirtyStateUnchanged },
        { DownloadWithItemsNotDirtyForSave,   "download with items stays clean",     DirtyStateFalse,     DirtyStateFalse },
        { DownloadEmptyNotDirtyForSave,       "download empty keeps save clean",     DirtyStateFalse,     DirtyStateFalse },
    };

    const QList<DirtyState> initialStates = {
        DirtyStateFalse,
        DirtyStateTrue,
    };

    for (const ScenarioExpectation& expectation : scenarioExpectations) {
        for (const DirtyState initialDirtyForSave : initialStates) {
            for (const DirtyState initialDirtyForUpload : initialStates) {
                DirtyState expectedDirtyForSave = expectation.expectedDirtyForSave;
                DirtyState expectedDirtyForUpload = expectation.expectedDirtyForUpload;

                if ((expectation.scenario == UploadTrueWhenSaveTrue) && (initialDirtyForSave == DirtyStateTrue)) {
                    // _setDirtyForSave(true) only drives dirtyForUpload when dirtyForSave transitions false->true.
                    // If dirtyForSave already starts true, dirtyForUpload is preserved.
                    expectedDirtyForUpload = DirtyStateUnchanged;
                }

                const QString rowName = QStringLiteral("%1 [init save=%2 upload=%3]")
                                            .arg(expectation.name)
                                            .arg(initialDirtyForSave == DirtyStateTrue ? QStringLiteral("true") : QStringLiteral("false"))
                                            .arg(initialDirtyForUpload == DirtyStateTrue ? QStringLiteral("true") : QStringLiteral("false"));
                QTest::newRow(rowName.toLatin1().constData())
                    << +expectation.scenario
                    << +initialDirtyForSave
                    << +initialDirtyForUpload
                    << +expectedDirtyForSave
                    << +expectedDirtyForUpload;
            }
        }
    }
}

void PlanMasterControllerTest::_testDirtyFlagsMatrix()
{
    QFETCH(int, scenario);
    QFETCH(int, initialDirtyForSave);
    QFETCH(int, initialDirtyForUpload);
    QFETCH(int, expectedDirtyForSave);
    QFETCH(int, expectedDirtyForUpload);

    QVERIFY(initialDirtyForSave != DirtyStateUnchanged);
    QVERIFY(initialDirtyForUpload != DirtyStateUnchanged);

    // Pre-load items for scenarios that need containsItems() == true
    if (scenario == DownloadWithItemsNotDirtyForSave) {
        _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    }

    const auto dirtyStateToBool = [](int state) -> bool {
        switch (state) {
        case DirtyStateFalse:
            return false;
        case DirtyStateTrue:
            return true;
        default:
            Q_ASSERT(false); // Invalid test data
            return false;
        }
    };

    _masterController->_setDirtyForSaveUnitTest(dirtyStateToBool(initialDirtyForSave));
    _masterController->_setDirtyForUploadUnitTest(dirtyStateToBool(initialDirtyForUpload));

    const bool initialDirtyForSaveBool = _masterController->dirtyForSave();
    const bool initialDirtyForUploadBool = _masterController->dirtyForUpload();

    QSignalSpy dirtyForSaveChangedSpy(_masterController, &PlanMasterController::dirtyForSaveChanged);
    QSignalSpy dirtyForUploadChangedSpy(_masterController, &PlanMasterController::dirtyForUploadChanged);

    switch (scenario) {
    case UploadPreservesSaveDirtyFalse: {
        const bool invoked = QMetaObject::invokeMethod(_masterController, "_sendRallyPointsComplete", Qt::DirectConnection);
        QVERIFY(invoked);
        break;
    }
    case UploadPreservesSaveDirtyTrue: {
        const bool invoked = QMetaObject::invokeMethod(_masterController, "_sendRallyPointsComplete", Qt::DirectConnection);
        QVERIFY(invoked);
        break;
    }
    case UploadFalseOnPlanClear:
        _masterController->removeAll();
        break;
    case UploadTrueWhenSaveTrue:
        _masterController->_setDirtyForSave(true);
        break;
    case UploadTrueOnNewPlanLoad:
        _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
        break;
    case SaveToFilePreservesUploadDirtyTrue: {
        const QString saveFile = QDir::temp().filePath(QStringLiteral("qgc_planmaster_test_%1.plan").arg(QDateTime::currentMSecsSinceEpoch()));
        QVERIFY(_masterController->saveToFile(saveFile));
        QFile::remove(saveFile);
        break;
    }
    case SaveToFilePreservesUploadDirtyFalse: {
        const QString saveFile = QDir::temp().filePath(QStringLiteral("qgc_planmaster_test_%1.plan").arg(QDateTime::currentMSecsSinceEpoch()));
        QVERIFY(_masterController->saveToFile(saveFile));
        QFile::remove(saveFile);
        break;
    }
    case SaveFalseOnSuccessfulLoad:
        _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
        break;
    case ClearSaveDirtyPreservesUploadTrue:
        _masterController->_setDirtyForSave(false);
        break;
    case ClearSaveDirtyPreservesUploadFalse:
        _masterController->_setDirtyForSave(false);
        break;
    case DownloadWithItemsNotDirtyForSave: {
        QVERIFY(_masterController->containsItems());
        const bool invoked = QMetaObject::invokeMethod(_masterController, "_loadRallyPointsComplete", Qt::DirectConnection);
        QVERIFY(invoked);
        break;
    }
    case DownloadEmptyNotDirtyForSave: {
        QVERIFY(!_masterController->containsItems());
        const bool invoked = QMetaObject::invokeMethod(_masterController, "_loadRallyPointsComplete", Qt::DirectConnection);
        QVERIFY(invoked);
        break;
    }
    }

    const auto resolveExpected = [](int expectedState, bool unchangedValue) -> bool {
        switch (expectedState) {
        case DirtyStateFalse:
            return false;
        case DirtyStateTrue:
            return true;
        case DirtyStateUnchanged:
            return unchangedValue;
        }
        return unchangedValue;
    };

    const bool expectedDirtyForSaveBool = resolveExpected(expectedDirtyForSave, initialDirtyForSaveBool);
    const bool expectedDirtyForUploadBool = resolveExpected(expectedDirtyForUpload, initialDirtyForUploadBool);
    const int expectedDirtyForSaveSignalCount = (expectedDirtyForSaveBool != initialDirtyForSaveBool) ? 1 : 0;
    const int expectedDirtyForUploadSignalCount = (expectedDirtyForUploadBool != initialDirtyForUploadBool) ? 1 : 0;

    QCOMPARE(_masterController->dirtyForSave(), expectedDirtyForSaveBool);
    QCOMPARE(_masterController->dirtyForUpload(), expectedDirtyForUploadBool);

    QCOMPARE(dirtyForSaveChangedSpy.count(), expectedDirtyForSaveSignalCount);
    QCOMPARE(dirtyForUploadChangedSpy.count(), expectedDirtyForUploadSignalCount);

    if (dirtyForSaveChangedSpy.count() > 0) {
        const QList<QVariant>& args = dirtyForSaveChangedSpy.at(dirtyForSaveChangedSpy.count() - 1);
        QCOMPARE(args.count(), 1);
        QCOMPARE(args.first().toBool(), _masterController->dirtyForSave());
    }

    if (dirtyForUploadChangedSpy.count() > 0) {
        const QList<QVariant>& args = dirtyForUploadChangedSpy.at(dirtyForUploadChangedSpy.count() - 1);
        QCOMPARE(args.count(), 1);
        QCOMPARE(args.first().toBool(), _masterController->dirtyForUpload());
    }
}

void PlanMasterControllerTest::_testFileNamesSetOnLoad()
{
    QSignalSpy currentNameSpy(_masterController, &PlanMasterController::currentPlanFileNameChanged);
    QSignalSpy originalNameSpy(_masterController, &PlanMasterController::originalPlanFileNameChanged);

    // Before load, names should be empty
    QVERIFY(_masterController->currentPlanFileName().isEmpty());
    QVERIFY(_masterController->originalPlanFileName().isEmpty());

    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    // After successful load, both names should be set to the base name
    QCOMPARE(_masterController->currentPlanFileName(), QStringLiteral("MissionPlanner"));
    QCOMPARE(_masterController->originalPlanFileName(), QStringLiteral("MissionPlanner"));

    // Signals should have fired
    QVERIFY(currentNameSpy.count() >= 1);
    QVERIFY(originalNameSpy.count() >= 1);
}

void PlanMasterControllerTest::_testCurrentPlanFileNameWritable()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    QSignalSpy currentNameSpy(_masterController, &PlanMasterController::currentPlanFileNameChanged);
    QSignalSpy originalNameSpy(_masterController, &PlanMasterController::originalPlanFileNameChanged);

    // Rename via the writable property
    _masterController->setCurrentPlanFileName(QStringLiteral("RenamedPlan"));

    QCOMPARE(_masterController->currentPlanFileName(), QStringLiteral("RenamedPlan"));
    // Original should remain unchanged
    QCOMPARE(_masterController->originalPlanFileName(), QStringLiteral("MissionPlanner"));

    QCOMPARE(currentNameSpy.count(), 1);
    QCOMPARE(originalNameSpy.count(), 0);

    // Setting to the same value should not emit again
    _masterController->setCurrentPlanFileName(QStringLiteral("RenamedPlan"));
    QCOMPARE(currentNameSpy.count(), 1);
}

void PlanMasterControllerTest::_testPlanFileRenamed()
{
    // Before load, planFileRenamed should be false (both names empty)
    QVERIFY(!_masterController->planFileRenamed());

    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    // After load, current == original → not renamed
    QVERIFY(!_masterController->planFileRenamed());

    // Rename
    _masterController->setCurrentPlanFileName(QStringLiteral("NewName"));
    QVERIFY(_masterController->planFileRenamed());

    // Rename back to original
    _masterController->setCurrentPlanFileName(QStringLiteral("MissionPlanner"));
    QVERIFY(!_masterController->planFileRenamed());
}

void PlanMasterControllerTest::_testSaveWithCurrentName()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    // First save to a real (writable) directory so _currentPlanFile points somewhere valid
    QTemporaryDir tmpDir;
    QVERIFY(tmpDir.isValid());
    const QString initialPath = QStringLiteral("%1/MissionPlanner.%2").arg(tmpDir.path(), _masterController->fileExtension());
    QVERIFY(_masterController->saveToFile(initialPath));

    // Rename
    _masterController->setCurrentPlanFileName(QStringLiteral("TestSaveRenamed"));

    // Save with the renamed name
    QVERIFY(_masterController->saveWithCurrentName());

    // After save, original should now match the renamed name
    QCOMPARE(_masterController->originalPlanFileName(), QStringLiteral("TestSaveRenamed"));
    QCOMPARE(_masterController->currentPlanFileName(), QStringLiteral("TestSaveRenamed"));
    QVERIFY(!_masterController->planFileRenamed());
}

void PlanMasterControllerTest::_testSaveWithCurrentNameNoFile()
{
    // No file loaded — saveWithCurrentName with empty name should fail
    QVERIFY(!_masterController->saveWithCurrentName());

    // Set a name without loading a file first (simulates typing a name in the UI)
    _masterController->setCurrentPlanFileName(QStringLiteral("BrandNewPlan"));

    // Should save to the default mission save directory
    QVERIFY(_masterController->saveWithCurrentName());

    const QString expectedDir = SettingsManager::instance()->appSettings()->missionSavePath();
    const QString expectedPath = QStringLiteral("%1/BrandNewPlan.%2").arg(expectedDir, _masterController->fileExtension());
    QCOMPARE(_masterController->currentPlanFile(), expectedPath);
    QCOMPARE(_masterController->originalPlanFileName(), QStringLiteral("BrandNewPlan"));

    // Clean up
    QFile::remove(expectedPath);
}

void PlanMasterControllerTest::_testResolvedPlanFileExists()
{
    // Empty name → should return false
    QVERIFY(!_masterController->resolvedPlanFileExists());

    // Save a file so it exists on disk
    QTemporaryDir tmpDir;
    QVERIFY(tmpDir.isValid());
    const QString savePath = QStringLiteral("%1/ExistingPlan.%2").arg(tmpDir.path(), _masterController->fileExtension());
    QVERIFY(_masterController->saveToFile(savePath));

    // Now rename to the same base name — file exists at resolved path
    _masterController->setCurrentPlanFileName(QStringLiteral("ExistingPlan"));
    QVERIFY(_masterController->resolvedPlanFileExists());

    // Rename to something non-existent
    _masterController->setCurrentPlanFileName(QStringLiteral("DoesNotExist"));
    QVERIFY(!_masterController->resolvedPlanFileExists());
}

void PlanMasterControllerTest::_testFileNamesClearedOnRemoveAll()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    // Verify names are set
    QVERIFY(!_masterController->currentPlanFileName().isEmpty());
    QVERIFY(!_masterController->originalPlanFileName().isEmpty());

    QSignalSpy currentNameSpy(_masterController, &PlanMasterController::currentPlanFileNameChanged);
    QSignalSpy originalNameSpy(_masterController, &PlanMasterController::originalPlanFileNameChanged);

    _masterController->removeAll();

    // Names should be cleared
    QVERIFY(_masterController->currentPlanFileName().isEmpty());
    QVERIFY(_masterController->originalPlanFileName().isEmpty());
    QVERIFY(_masterController->currentPlanFile().isEmpty());

    QVERIFY(currentNameSpy.count() >= 1);
    QVERIFY(originalNameSpy.count() >= 1);
}

void PlanMasterControllerTest::_testFileNamesClearedOnRemoveAllFromVehicle()
{
    _connectMockLink(MAV_AUTOPILOT_PX4);

    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    // Verify names are set
    QVERIFY(!_masterController->currentPlanFileName().isEmpty());
    QVERIFY(!_masterController->originalPlanFileName().isEmpty());

    QSignalSpy currentNameSpy(_masterController, &PlanMasterController::currentPlanFileNameChanged);
    QSignalSpy originalNameSpy(_masterController, &PlanMasterController::originalPlanFileNameChanged);

    _masterController->removeAllFromVehicle();

    // Names should be cleared
    QVERIFY(_masterController->currentPlanFileName().isEmpty());
    QVERIFY(_masterController->originalPlanFileName().isEmpty());
    QVERIFY(_masterController->currentPlanFile().isEmpty());

    QVERIFY(currentNameSpy.count() >= 1);
    QVERIFY(originalNameSpy.count() >= 1);
}

void PlanMasterControllerTest::_testSaveUpdatesOriginalFileName()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QCOMPARE(_masterController->originalPlanFileName(), QStringLiteral("MissionPlanner"));

    // Save to a completely different path
    const QString saveFile = QDir::temp().filePath(
        QStringLiteral("qgc_planmaster_rename_%1.plan").arg(QDateTime::currentMSecsSinceEpoch()));
    QVERIFY(_masterController->saveToFile(saveFile));

    // Both names should now reflect the new file base name
    const QString expectedBase = QFileInfo(saveFile).completeBaseName();
    QCOMPARE(_masterController->currentPlanFileName(), expectedBase);
    QCOMPARE(_masterController->originalPlanFileName(), expectedBase);

    // Clean up
    QFile::remove(saveFile);
}

void PlanMasterControllerTest::_testTemplateModeHidesTemplatesOnPlanCreatorSelection()
{
    // Initial state: empty plan → templates shown
    QVERIFY(_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);

    // User selects a plan creator (e.g. Survey) — adds items to the plan
    SurveyPlanCreator creator(_masterController);
    creator.createPlan(QGeoCoordinate(47.0, -122.0));

    QVERIFY(_masterController->containsItems());
    QVERIFY(!_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
}

void PlanMasterControllerTest::_testTemplateModeHidesTemplatesOnFileLoad()
{
    // Initial state: empty plan, not manual creation → templates shown
    QVERIFY(_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);

    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");

    QVERIFY(_masterController->containsItems());
    QVERIFY(!_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
}

void PlanMasterControllerTest::_testTemplateModeRestoredOnRemoveAll()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QVERIFY(!_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);

    _masterController->removeAll();

    QVERIFY(!_masterController->containsItems());
    QVERIFY(_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
}

void PlanMasterControllerTest::_testTemplateModeRestoredOnIndividualItemRemoval()
{
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QVERIFY(!_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);

    _masterController->missionController()->removeAll();
    _masterController->geoFenceController()->removeAll();
    _masterController->rallyPointController()->removeAll();

    QVERIFY(!_masterController->containsItems());
    QVERIFY(_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
}

void PlanMasterControllerTest::_testManualCreationHidesTemplates()
{
    // Initial state: empty plan → templates shown
    QVERIFY(_masterController->showCreateFromTemplate());
    QVERIFY(!_masterController->userSelectedManualCreation());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);
    QSignalSpy spyManual(_masterController, &PlanMasterController::userSelectedManualCreationChanged);

    // User clicks "No Template" — hides templates even though plan is empty
    _masterController->setUserSelectedManualCreation(true);

    QVERIFY(_masterController->userSelectedManualCreation());
    QVERIFY(!_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
    QCOMPARE(spyManual.count(), 1);

    // Setting the same value again should not re-emit
    _masterController->setUserSelectedManualCreation(true);
    QCOMPARE(spyShow.count(), 1);
    QCOMPARE(spyManual.count(), 1);
}

void PlanMasterControllerTest::_testManualCreationRestoredOnRemoveAll()
{
    _masterController->setUserSelectedManualCreation(true);
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QVERIFY(!_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);
    QSignalSpy spyManual(_masterController, &PlanMasterController::userSelectedManualCreationChanged);

    _masterController->removeAll();

    QVERIFY(!_masterController->containsItems());
    QVERIFY(!_masterController->userSelectedManualCreation());
    QVERIFY(_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
    QCOMPARE(spyManual.count(), 1);
}

void PlanMasterControllerTest::_testManualCreationRestoredOnIndividualItemRemoval()
{
    _masterController->setUserSelectedManualCreation(true);
    _masterController->loadFromFile(":/unittest/MissionPlanner.waypoints");
    QVERIFY(!_masterController->showCreateFromTemplate());

    QSignalSpy spyShow(_masterController, &PlanMasterController::showCreateFromTemplateChanged);
    QSignalSpy spyManual(_masterController, &PlanMasterController::userSelectedManualCreationChanged);

    _masterController->missionController()->removeAll();
    _masterController->geoFenceController()->removeAll();
    _masterController->rallyPointController()->removeAll();

    QVERIFY(!_masterController->containsItems());
    QVERIFY(!_masterController->userSelectedManualCreation());
    QVERIFY(_masterController->showCreateFromTemplate());
    QCOMPARE(spyShow.count(), 1);
    QCOMPARE(spyManual.count(), 1);
}

void PlanMasterControllerTest::_testPlanCreatorsFiltered()
{
    // MultiRotor supports StructureScan — expect all 4 creators
    PlanMasterController multiRotorController(MAV_AUTOPILOT_PX4, MAV_TYPE_QUADROTOR);
    multiRotorController.setFlyView(false);
    multiRotorController.start();
    QVERIFY(multiRotorController.planCreators() != nullptr);
    const int multiRotorCount = multiRotorController.planCreators()->count();
    QVERIFY(multiRotorCount > 0);

    // FixedWing does not support StructureScan — expect one fewer creator
    PlanMasterController fixedWingController(MAV_AUTOPILOT_PX4, MAV_TYPE_FIXED_WING);
    fixedWingController.setFlyView(false);
    fixedWingController.start();
    QVERIFY(fixedWingController.planCreators() != nullptr);
    const int fixedWingCount = fixedWingController.planCreators()->count();
    QVERIFY(fixedWingCount > 0);

    QCOMPARE(fixedWingCount, multiRotorCount - 1);
}

void PlanMasterControllerTest::_testSaveMissionWaypointsAsJson()
{
    MissionController* missionController = _masterController->missionController();

    // insertTakeoffItem() ignores its coordinate argument and derives position from home instead
    // (see MissionController::insertTakeoffItem) - set it explicitly so the test is deterministic.
    TakeoffMissionItem* takeoffItem = qobject_cast<TakeoffMissionItem*>(missionController->insertTakeoffItem(Coord::zurich(), 1));
    QVERIFY(takeoffItem);
    takeoffItem->setCoordinate(Coord::zurich());
    takeoffItem->altitude()->setRawValue(100.0);

    SimpleMissionItem* wp1 = qobject_cast<SimpleMissionItem*>(missionController->insertSimpleMissionItem(Coord::seattle(), 2));
    QVERIFY(wp1);
    wp1->altitude()->setRawValue(50.0);
    wp1->speedSection()->setSpecifyFlightSpeed(true);
    wp1->speedSection()->flightSpeed()->setRawValue(7.5);

    SimpleMissionItem* wp2 = qobject_cast<SimpleMissionItem*>(missionController->insertSimpleMissionItem(Coord::sanFrancisco(), 3));
    QVERIFY(wp2);
    wp2->altitude()->setRawValue(75.0);
    // wp2 leaves speedSection unspecified: exercises the fallback to the vehicle's own default speed
    // (hover for multi-rotor, cruise otherwise) rather than inferring it from a neighboring item.
    // Captured immediately before save() so it reflects exactly the value the code under test will read.
    Vehicle*     vehicle = _masterController->managerVehicle();
    const double expectedFallbackSpeed = vehicle->multiRotor() ? vehicle->defaultHoverSpeed() : vehicle->defaultCruiseSpeed();

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("waypoints.json"));

    _masterController->saveMissionWaypointsAsJson(filename);

    QFile file(filename);
    QVERIFY(file.open(QIODevice::ReadOnly));
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &parseError);
    file.close();
    QCOMPARE(parseError.error, QJsonParseError::NoError);
    QVERIFY(doc.isObject());

    const QJsonObject root = doc.object();
    QCOMPARE(root.value(QStringLiteral("fileType")).toString(), QStringLiteral("FinalPlanWithTarget"));
    QCOMPARE(root.value(QStringLiteral("version")).toDouble(), 12.0);

    const QJsonObject launchPoint = root.value(QStringLiteral("launch_point")).toObject();
    const QGeoCoordinate launchCoord(launchPoint.value(QStringLiteral("latitude")).toDouble(),
                                      launchPoint.value(QStringLiteral("longitude")).toDouble());
    QVERIFY(launchCoord.distanceTo(Coord::zurich()) <= kCoordToleranceMeters);
    QVERIFY(qAbs(launchPoint.value(QStringLiteral("altitude")).toDouble() - 100.0) < kValueTolerance);

    const QJsonArray waypoints = root.value(QStringLiteral("waypoints")).toArray();
    QCOMPARE(waypoints.count(), 2);

    const QJsonObject jsonWp1 = waypoints.at(0).toObject();
    const QGeoCoordinate wp1Coord(jsonWp1.value(QStringLiteral("latitude")).toDouble(), jsonWp1.value(QStringLiteral("longitude")).toDouble());
    QVERIFY(wp1Coord.distanceTo(Coord::seattle()) <= kCoordToleranceMeters);
    QVERIFY(qAbs(jsonWp1.value(QStringLiteral("altitude")).toDouble() - 50.0) < kValueTolerance);
    QVERIFY(qAbs(jsonWp1.value(QStringLiteral("flight_speed")).toDouble() - 7.5) < kValueTolerance);
    QCOMPARE(jsonWp1.value(QStringLiteral("is_target")).toBool(), false);

    const QJsonObject jsonWp2 = waypoints.at(1).toObject();
    const QGeoCoordinate wp2Coord(jsonWp2.value(QStringLiteral("latitude")).toDouble(), jsonWp2.value(QStringLiteral("longitude")).toDouble());
    QVERIFY(wp2Coord.distanceTo(Coord::sanFrancisco()) <= kCoordToleranceMeters);
    QVERIFY(qAbs(jsonWp2.value(QStringLiteral("altitude")).toDouble() - 75.0) < kValueTolerance);
    QVERIFY(qAbs(jsonWp2.value(QStringLiteral("flight_speed")).toDouble() - expectedFallbackSpeed) < kValueTolerance);
    QCOMPARE(jsonWp2.value(QStringLiteral("is_target")).toBool(), true);
}

void PlanMasterControllerTest::_testSaveMissionWaypointsAsJsonRejectsPlanWithoutWaypoints()
{
    // Fresh plan only has the Mission Settings item, no MAV_CMD_NAV_WAYPOINT items to export.
    ignoreLogMessage("API.QGCApplication.AppMessage", QtDebugMsg, QRegularExpression("no waypoint items"));

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("empty.json"));

    _masterController->saveMissionWaypointsAsJson(filename);

    QVERIFY(!QFile::exists(filename));
}

void PlanMasterControllerTest::_testLoadMissionFromJsonUsesLaunchPointAndDedupesSpeed()
{
    QJsonObject launchPoint;
    launchPoint[QStringLiteral("latitude")] = 47.0;
    launchPoint[QStringLiteral("longitude")] = 8.0;
    launchPoint[QStringLiteral("altitude")] = 400.0;

    // wp1->wp2 keep the same flight_speed (should NOT re-specify it), wp2->wp3 changes (should).
    QJsonArray waypoints;
    for (const auto& wp : { std::tuple(47.1, 8.1, 50.0, 5.0), std::tuple(47.2, 8.2, 60.0, 5.0), std::tuple(47.3, 8.3, 70.0, 8.0) }) {
        QJsonObject wpObject;
        wpObject[QStringLiteral("latitude")] = std::get<0>(wp);
        wpObject[QStringLiteral("longitude")] = std::get<1>(wp);
        wpObject[QStringLiteral("altitude")] = std::get<2>(wp);
        wpObject[QStringLiteral("flight_speed")] = std::get<3>(wp);
        waypoints.append(wpObject);
    }

    QJsonObject root;
    root[QStringLiteral("fileType")] = QStringLiteral("FinalPlanWithTarget");
    root[QStringLiteral("version")] = 12.0;
    root[QStringLiteral("launch_point")] = launchPoint;
    root[QStringLiteral("waypoints")] = waypoints;

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("import.json"));
    QFile file(filename);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(QJsonDocument(root).toJson()) != -1);
    file.close();

    _masterController->loadMissionFromJson(filename);

    MissionController* missionController = _masterController->missionController();
    QVERIFY(missionController->plannedHomePosition().distanceTo(QGeoCoordinate(47.0, 8.0)) <= kCoordToleranceMeters);
    QVERIFY(qAbs(missionController->plannedHomePosition().altitude() - 400.0) < kValueTolerance);

    QmlObjectListModel* visualItems = missionController->visualItems();
    QCOMPARE(visualItems->count(), 4); // Mission settings + 3 waypoints

    SimpleMissionItem* item1 = qobject_cast<SimpleMissionItem*>(visualItems->get(1));
    QVERIFY(item1);
    QVERIFY(item1->coordinate().distanceTo(QGeoCoordinate(47.1, 8.1)) <= kCoordToleranceMeters);
    QVERIFY(qAbs(item1->altitude()->rawValue().toDouble() - 50.0) < kValueTolerance);
    QVERIFY(item1->speedSection()->specifyFlightSpeed()); // First waypoint always specifies its speed.
    QVERIFY(qAbs(item1->speedSection()->flightSpeed()->rawValue().toDouble() - 5.0) < kValueTolerance);

    SimpleMissionItem* item2 = qobject_cast<SimpleMissionItem*>(visualItems->get(2));
    QVERIFY(item2);
    QVERIFY(item2->coordinate().distanceTo(QGeoCoordinate(47.2, 8.2)) <= kCoordToleranceMeters);
    QVERIFY(!item2->speedSection()->specifyFlightSpeed()); // Same speed as item1: no redundant DO_CHANGE_SPEED.

    SimpleMissionItem* item3 = qobject_cast<SimpleMissionItem*>(visualItems->get(3));
    QVERIFY(item3);
    QVERIFY(item3->coordinate().distanceTo(QGeoCoordinate(47.3, 8.3)) <= kCoordToleranceMeters);
    QVERIFY(item3->speedSection()->specifyFlightSpeed()); // Speed changed from item2: must be specified.
    QVERIFY(qAbs(item3->speedSection()->flightSpeed()->rawValue().toDouble() - 8.0) < kValueTolerance);
}

void PlanMasterControllerTest::_testLoadMissionFromJsonFallsBackToFirstWaypointWhenNoLaunchPoint()
{
    // No "launch_point" key. The offline controller vehicle has no live coordinate and the plan
    // has no home set yet, so this must fall all the way back to the first waypoint's own coordinate.
    QJsonObject waypoint;
    waypoint[QStringLiteral("latitude")] = 10.0;
    waypoint[QStringLiteral("longitude")] = 20.0;
    waypoint[QStringLiteral("altitude")] = 30.0;

    QJsonArray waypoints;
    waypoints.append(waypoint);

    QJsonObject root;
    root[QStringLiteral("waypoints")] = waypoints;

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("no_launch_point.json"));
    QFile file(filename);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(QJsonDocument(root).toJson()) != -1);
    file.close();

    QVERIFY(!_masterController->managerVehicle()->coordinate().isValid());
    QVERIFY(!_masterController->missionController()->homePositionSet());

    _masterController->loadMissionFromJson(filename);

    QVERIFY(_masterController->missionController()->plannedHomePosition().distanceTo(QGeoCoordinate(10.0, 20.0)) <= kCoordToleranceMeters);
}

void PlanMasterControllerTest::_testLoadMissionFromJsonRejectsMissingWaypointsArray()
{
    QJsonObject root;
    root[QStringLiteral("fileType")] = QStringLiteral("FinalPlanWithTarget");

    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString filename = tempDir.filePath(QStringLiteral("no_waypoints.json"));
    QFile file(filename);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(QJsonDocument(root).toJson()) != -1);
    file.close();

    ignoreLogMessage("API.QGCApplication.AppMessage", QtDebugMsg, QRegularExpression("waypoints.*array"));

    _masterController->loadMissionFromJson(filename);

    // Plan must be left untouched: only the Mission Settings item, nothing removed or added.
    QCOMPARE(_masterController->missionController()->visualItems()->count(), 1);
}

void PlanMasterControllerTest::_testSendSavedPlanToServerMissingFileShowsError()
{
    ignoreLogMessage("API.QGCApplication.AppMessage", QtDebugMsg, QRegularExpression("Unable to open"));

    // File-open failure returns before any network request is made - safe to run without a server.
    _masterController->sendSavedPlanToServer(QStringLiteral("/nonexistent/path/plan.json"));
}

#include "UnitTest.h"

UT_REGISTER_TEST(PlanMasterControllerTest, TestLabel::Integration, TestLabel::MissionManager)
