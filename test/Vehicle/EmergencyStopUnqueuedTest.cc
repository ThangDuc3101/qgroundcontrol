#include "EmergencyStopUnqueuedTest.h"

#include <QtCore/QRegularExpression>

#include "MockLink.h"
#include "Vehicle.h"

void EmergencyStopUnqueuedTest::_disarmsWhileNormalDisarmIsPending()
{
    vehicle()->setArmed(true, false);
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->armed(), TestTimeout::mediumMs());

    // A normal disarm that gets no answer, as on a degraded link, stays pending in the command queue
    mockLink()->setIgnoreUnforcedArmDisarm(true);
    vehicle()->setArmed(false, false);
    QTRY_VERIFY_WITH_TIMEOUT(vehicle()->isMavCommandPending(vehicle()->defaultComponentId(), MAV_CMD_COMPONENT_ARM_DISARM),
                             TestTimeout::shortMs());

    // The queued emergency stop is refused while that disarm is pending
    expectAppMessage(QRegularExpression("Waiting on previous response to same command"));
    vehicle()->emergencyStop();
    verifyExpectedLogMessage();
    QVERIFY(vehicle()->armed());

    // The unqueued one still reaches the vehicle, every copy of it
    mockLink()->clearReceivedMavCommandCounts();
    vehicle()->emergencyStopUnqueued();
    QTRY_VERIFY_WITH_TIMEOUT(!vehicle()->armed(), TestTimeout::mediumMs());
    QTRY_COMPARE_WITH_TIMEOUT(mockLink()->receivedMavCommandCount(MAV_CMD_COMPONENT_ARM_DISARM), 3, TestTimeout::shortMs());

    // The forced disarm's ack also settles the pending normal disarm
    QTRY_VERIFY_WITH_TIMEOUT(!vehicle()->isMavCommandPending(vehicle()->defaultComponentId(), MAV_CMD_COMPONENT_ARM_DISARM),
                             TestTimeout::mediumMs());
}

#include "UnitTest.h"

UT_REGISTER_TEST(EmergencyStopUnqueuedTest, TestLabel::Integration, TestLabel::Vehicle)
