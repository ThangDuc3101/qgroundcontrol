#pragma once

#include "BaseClasses/VehicleTest.h"

class UavControlModeTest : public VehicleTest
{
    Q_OBJECT

private slots:
    void _followsReportedMode();
    void _unknownWhenServerStopsReporting();
    void _postsModeChange();
    void _reportsFailedModeChange();
    void _refusesUnknownMode();
    void _followsReportedAi();
    void _modeChangeCarriesAi();
    void _postsAiChange();
    void _refusesAiOutsideAutoOrRange();
    void _aiCannotUndoUnconfirmedModeChange();
    void _keepsRequestsInOrder();
};
