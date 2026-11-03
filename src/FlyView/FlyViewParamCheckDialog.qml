import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

// Pre-flight parameter check. Compares the vehicle's parameters with a reference PX4 .params file whose path
// is remembered in FlyViewSettings.paramCheckReferenceFile, lists every mismatch and, after a hold-to-confirm,
// writes the reference value of each mismatched parameter to the vehicle. Parameters that exist in the file
// but not on the vehicle are reported but never written. Read-only parameters are skipped by
// ParameterEditorController::buildDiffFromFile. Writing is refused while the vehicle is armed. Every check first
// re-reads all parameters from the vehicle, since QGC's copy can be stale (e.g. params changed by another GCS or
// the vehicle rebooted on the same link). Sensor calibration parameters are neither compared nor written: they belong
// to this vehicle's own sensors (see ParameterEditorController::isSensorCalibrationParam). Neither are the flight
// counters and learned declination PX4 maintains itself (isVehicleRuntimeParam).
QGCPopupDialog {
    id:         root
    title:      qsTr("Kiểm tra Params")
    buttons:    Dialog.Close

    readonly property int _holdToConfirmMs: 1000

    property var    _activeVehicle:     QGroundControl.multiVehicleManager.activeVehicle
    property var    _parameterManager:  _activeVehicle ? _activeVehicle.parameterManager : null
    property var    _appSettings:       QGroundControl.settingsManager.appSettings
    property Fact   _referenceFileFact: QGroundControl.settingsManager.flyViewSettings.paramCheckReferenceFile
    property string _referenceFile:     _referenceFileFact.rawValue
    property int    _mismatchCount:     paramController.diffList.count
    property int    _writableCount:     0 // mismatches that exist on the vehicle and can be written
    property string _state:             "noFile" // noFile, notReady, refreshing, refreshFailed, error, pass, fail, writing, writeFailed
    property bool   _refreshProgressSeen: false
    property var    _failedWrites:      []       // names of parameters whose write failed during the last update
    property bool   _armed:             _activeVehicle ? _activeVehicle.armed : false

    readonly property color _passColor: "#00c000"
    readonly property color _failColor: "#ff0000"
    readonly property color _infoColor: QGroundControl.globalPalette.text

    function _runCheck() {
        paramController.clearDiff()
        _writableCount = 0
        if (_referenceFile === "") {
            _state = "noFile"
            return
        }
        if (!_parameterManager || !_parameterManager.parametersReady) {
            _state = "notReady"
            return
        }
        if (!paramController.buildDiffFromFile(_referenceFile)) {
            _state = "error"
            return
        }
        var writable = 0
        for (var i = 0; i < paramController.diffList.count; i++) {
            var diff = paramController.diffList.get(i)
            // PX4 rejects PARAM_SET for unknown names, so never send parameters the vehicle does not have
            diff.load = !diff.noVehicleValue
            if (diff.load) {
                writable++
            }
        }
        _writableCount = writable
        _state = _mismatchCount === 0 ? "pass" : "fail"
    }

    // Re-reads every parameter from the vehicle, then compares (see onLoadProgressChanged)
    function _startCheck() {
        paramController.clearDiff()
        _writableCount = 0
        if (_referenceFile === "") {
            _state = "noFile"
            return
        }
        if (!_parameterManager || !_parameterManager.parametersReady) {
            _state = "notReady" // the initial download in progress is fresh; compare when it completes
            return
        }
        _state = "refreshing"
        _refreshProgressSeen = false
        refreshTimeoutTimer.restart()
        _parameterManager.refreshAllParameters()
    }

    function _writeReferenceValues() {
        if (_armed) {
            return
        }
        _failedWrites = []
        _state = "writing"
        paramController.sendDiff()
        if (!_parameterManager.pendingWrites) {
            settleTimer.restart()
        }
    }

    // Re-check after an update. A failed write leaves the value QGC set locally until the vehicle's real value is
    // read back, so wait for that read-back and never report a pass while any write failed.
    function _finishWrite() {
        var failed = _failedWrites
        _runCheck()
        if (failed.length > 0) {
            _failedWrites = failed
            _state = "writeFailed"
        }
    }

    Timer {
        id:         refreshTimeoutTimer
        interval:   120000
        onTriggered: {
            if (root._state === "refreshing") {
                root._state = "refreshFailed" // never compare against values that may be stale
            }
        }
    }

    Timer {
        id:         settleTimer
        interval:   2000
        onTriggered: root._finishWrite()
    }

    function _fileName(path) {
        return path.substring(Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\")) + 1)
    }

    ParameterEditorController {
        id:                         paramController
        diffSkipSensorCalibration:  true
        diffSkipVehicleRuntime:     true
    }

    Component.onCompleted:      _startCheck()
    Component.onDestruction:    paramController.clearDiff()

    Connections {
        target:                 root._parameterManager
        ignoreUnknownSignals:   true
        function onParametersReadyChanged(parametersReady) {
            if (parametersReady && root._state === "notReady") {
                root._runCheck()
            }
        }
        // Every write acked or given up: re-check once failed parameters have been read back
        function onPendingWritesChanged(pendingWrites) {
            if (root._state !== "writing") {
                return
            }
            if (pendingWrites) {
                settleTimer.stop()
            } else {
                settleTimer.restart()
            }
        }
        // A refresh reports progress, then drops back to 0 once every parameter has been received
        function onLoadProgressChanged(value) {
            if (root._state !== "refreshing") {
                return
            }
            if (value > 0) {
                root._refreshProgressSeen = true
            } else if (root._refreshProgressSeen) {
                refreshTimeoutTimer.stop()
                root._runCheck()
            }
        }
        function on_ParamSetFailure(componentId, paramName) {
            if (root._state === "writing") {
                root._failedWrites = root._failedWrites.concat([paramName])
            }
        }
    }

    QGCFileDialog {
        id:             fileDialog
        title:          qsTr("Chọn file params chuẩn")
        folder:         root._appSettings.parameterSavePath
        nameFilters:    [ qsTr("Parameter Files (*.%1)").arg(root._appSettings.parameterFileExtension), qsTr("All Files (*)") ]

        onAcceptedForLoad: (file) => {
            close()
            root._referenceFileFact.rawValue = file
            root._startCheck()
        }
    }

    ColumnLayout {
        spacing: ScreenTools.defaultDialogControlSpacing

        // Result banner
        Rectangle {
            Layout.fillWidth:       true
            Layout.minimumWidth:    ScreenTools.defaultFontPixelWidth * 60
            implicitHeight:         statusLabel.implicitHeight + ScreenTools.defaultFontPixelHeight
            radius:                 ScreenTools.defaultBorderRadius
            border.width:           3
            border.color:           root._state === "pass" ? root._passColor : (["fail", "error", "writeFailed", "refreshFailed"].indexOf(root._state) >= 0 ? root._failColor : root._infoColor)
            color:                  Qt.rgba(border.color.r, border.color.g, border.color.b, 0.2)

            QGCLabel {
                id:                 statusLabel
                anchors.centerIn:   parent
                font.bold:          true
                font.pointSize:     ScreenTools.mediumFontPointSize
                color:              parent.border.color
                text: {
                    switch (root._state) {
                    case "noFile":   return qsTr("Chưa chọn file params chuẩn")
                    case "notReady": return qsTr("Đang tải params từ máy bay...")
                    case "refreshing": return qsTr("Đang đọc lại params từ máy bay... %1%").arg(Math.round((root._parameterManager ? root._parameterManager.loadProgress : 0) * 100))
                    case "refreshFailed": return qsTr("Không đọc lại được params từ máy bay")
                    case "error":    return qsTr("Không đọc được file params chuẩn")
                    case "pass":     return qsTr("ĐẠT - params khớp với file chuẩn")
                    case "fail":     return qsTr("KHÔNG ĐẠT - %1 tham số sai khác").arg(root._mismatchCount)
                    case "writing":  return qsTr("Đang cập nhật tham số...")
                    case "writeFailed": return qsTr("GHI LỖI - %1 tham số không ghi được").arg(root._failedWrites.length)
                    }
                    return ""
                }
            }
        }

        QGCLabel {
            Layout.fillWidth:   true
            Layout.maximumWidth: ScreenTools.defaultFontPixelWidth * 70
            text:               root._referenceFile === "" ? qsTr("File chuẩn: (chưa chọn)") : qsTr("File chuẩn: %1").arg(root._fileName(root._referenceFile))
            elide:              Text.ElideMiddle
        }

        QGCFlickable {
            Layout.preferredWidth:  diffGrid.implicitWidth
            Layout.preferredHeight: Math.min(diffGrid.implicitHeight, root.maxContentAvailableHeight * 0.6)
            contentWidth:           diffGrid.implicitWidth
            contentHeight:          diffGrid.implicitHeight
            clip:                   true
            visible:                root._mismatchCount > 0

            ColumnLayout {
                id:         diffGrid
                spacing:    ScreenTools.defaultFontPixelHeight / 4

                property real _nameWidth:   ScreenTools.defaultFontPixelWidth * 18
                property real _valueWidth:  ScreenTools.defaultFontPixelWidth * 24

                RowLayout {
                    spacing: ScreenTools.defaultFontPixelWidth * 2
                    QGCLabel { Layout.preferredWidth: diffGrid._nameWidth;  text: qsTr("Tham số");       font.bold: true }
                    QGCLabel { Layout.preferredWidth: diffGrid._valueWidth; text: qsTr("File chuẩn");    font.bold: true }
                    QGCLabel { Layout.preferredWidth: diffGrid._valueWidth; text: qsTr("Trên máy bay");  font.bold: true }
                }

                Repeater {
                    model: paramController.diffList

                    RowLayout {
                        spacing: ScreenTools.defaultFontPixelWidth * 2
                        QGCLabel { Layout.preferredWidth: diffGrid._nameWidth;  text: object.name }
                        QGCLabel {
                            Layout.preferredWidth:  diffGrid._valueWidth
                            text:                   object.fileValue + " " + object.units
                            wrapMode:               Text.WordWrap // enum values can be long sentences
                        }
                        QGCLabel {
                            Layout.preferredWidth:  diffGrid._valueWidth
                            text:                   object.noVehicleValue ? qsTr("không có trên máy bay") : object.vehicleValue + " " + object.units
                            color:                  root._failColor
                            wrapMode:               Text.WordWrap
                        }
                    }
                }
            }
        }

        QGCLabel {
            Layout.fillWidth:       true
            Layout.maximumWidth:    ScreenTools.defaultFontPixelWidth * 70
            visible:                root._state === "writeFailed"
            wrapMode:               Text.WordWrap
            color:                  root._failColor
            text:                   qsTr("Không ghi được: %1. Giá trị trên máy bay có thể chưa đổi hoặc đã đổi muộn: bấm \"Kiểm tra lại\" để đọc lại giá trị thật.").arg(root._failedWrites.join(", "))
        }

        QGCLabel {
            Layout.fillWidth:       true
            Layout.maximumWidth:    ScreenTools.defaultFontPixelWidth * 70
            visible:                (root._state === "fail" || root._state === "writeFailed") && root._armed
            wrapMode:               Text.WordWrap
            color:                  root._failColor
            text:                   qsTr("Máy bay đang ARM: chỉ được kiểm tra, không được cập nhật tham số.")
        }

        QGCLabel {
            Layout.fillWidth:       true
            Layout.maximumWidth:    ScreenTools.defaultFontPixelWidth * 70
            visible:                ["pass", "fail", "writeFailed"].indexOf(root._state) >= 0 && paramController.diffSkippedParams.length > 0
            wrapMode:               Text.WordWrap
            font.pointSize:         ScreenTools.smallFontPointSize
            text:                   qsTr("Bỏ qua %1 tham số hiệu chuẩn cảm biến (CAL_*, TC_*, SENS_BOARD_*_OFF, SENS_DPRES_OFF, ASPD_SCALE_1..3): không so sánh, không ghi.")
                                        .arg(paramController.diffSkippedParams.length)
        }

        QGCLabel {
            Layout.fillWidth:       true
            Layout.maximumWidth:    ScreenTools.defaultFontPixelWidth * 70
            visible:                ["pass", "fail", "writeFailed"].indexOf(root._state) >= 0 && paramController.diffSkippedRuntimeParams.length > 0
            wrapMode:               Text.WordWrap
            font.pointSize:         ScreenTools.smallFontPointSize
            text:                   qsTr("Bỏ qua %1 bộ đếm và giá trị tự học (%2): không so sánh, không ghi.")
                                        .arg(paramController.diffSkippedRuntimeParams.length).arg(paramController.diffSkippedRuntimeParams.join(", "))
        }

        QGCLabel {
            Layout.fillWidth:       true
            Layout.maximumWidth:    ScreenTools.defaultFontPixelWidth * 70
            visible:                root._state === "fail" && root._writableCount < root._mismatchCount
            wrapMode:               Text.WordWrap
            font.pointSize:         ScreenTools.smallFontPointSize
            text:                   qsTr("Các tham số 'không có trên máy bay' sẽ không được ghi.")
        }

        RowLayout {
            Layout.fillWidth:   true
            spacing:            ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:       root._referenceFile === "" ? qsTr("Chọn file") : qsTr("Đổi file")
                enabled:    root._state !== "writing" && root._state !== "refreshing"
                onClicked:  fileDialog.openForLoad()
            }

            QGCButton {
                text:       qsTr("Kiểm tra lại")
                enabled:    root._referenceFile !== "" && root._state !== "writing" && root._state !== "refreshing"
                onClicked:  root._startCheck()
            }

            Item { Layout.fillWidth: true }

            QGCDelayButton {
                text:               qsTr("Giữ để cập nhật %1 tham số").arg(root._writableCount)
                visible:            (root._state === "fail" || root._state === "writeFailed") && root._writableCount > 0
                enabled:            !root._armed
                delay:              root._holdToConfirmMs
                onActivated:        root._writeReferenceValues()
            }
        }
    }
}
