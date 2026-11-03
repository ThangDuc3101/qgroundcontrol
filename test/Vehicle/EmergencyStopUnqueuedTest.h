#pragma once

#include "BaseClasses/VehicleTest.h"

class EmergencyStopUnqueuedTest : public VehicleTest
{
    Q_OBJECT

private slots:
    void _disarmsWhileNormalDisarmIsPending();
};
