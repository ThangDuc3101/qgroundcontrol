#pragma once

#include "BaseClasses/ParameterTest.h"

class ParameterEditorControllerTest : public ParameterTest
{
    Q_OBJECT

private slots:
    void _buildDiffQGCFormat();
    void _buildDiffMPFormat();
    void _buildDiffNoDifferencesQGC();
    void _buildDiffNoDifferencesMP();
    void _buildDiffBadFormat();
    void _buildDiffMissingOnVehicle();
    void _buildDiffMPMissingParam();
    void _buildDiffSkipsHashCheck();
    void _buildDiffSkipsSensorCalibration();
    void _buildDiffComparesCalibrationByDefault();
    void _isSensorCalibrationParam();
    void _buildDiffSkipsVehicleRuntimeValues();
    void _isVehicleRuntimeParam();
};
