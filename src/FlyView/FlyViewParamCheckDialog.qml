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
// ParameterEditorController::buildDiffFromFile.
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
    property string _state:             "noFile" // noFile, notReady, error, pass, fail, writing

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

    function _writeReferenceValues() {
        _state = "writing"
        paramController.sendDiff()
        if (!_parameterManager.pendingWrites) {
            _runCheck()
        }
    }

    function _fileName(path) {
        return path.substring(Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\")) + 1)
    }

    ParameterEditorController { id: paramController }

    Component.onCompleted:      _runCheck()
    Component.onDestruction:    paramController.clearDiff()

    Connections {
        target:                 root._parameterManager
        ignoreUnknownSignals:   true
        function onParametersReadyChanged(parametersReady) {
            if (parametersReady && root._state === "notReady") {
                root._runCheck()
            }
        }
        // Re-check once every write has been acked (or has given up) so the result reflects the vehicle
        function onPendingWritesChanged(pendingWrites) {
            if (!pendingWrites && root._state === "writing") {
                root._runCheck()
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
            root._runCheck()
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
            border.color:           root._state === "pass" ? root._passColor : (root._state === "fail" || root._state === "error" ? root._failColor : root._infoColor)
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
                    case "error":    return qsTr("Không đọc được file params chuẩn")
                    case "pass":     return qsTr("ĐẠT - params khớp với file chuẩn")
                    case "fail":     return qsTr("KHÔNG ĐẠT - %1 tham số sai khác").arg(root._mismatchCount)
                    case "writing":  return qsTr("Đang cập nhật tham số...")
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
                enabled:    root._state !== "writing"
                onClicked:  fileDialog.openForLoad()
            }

            QGCButton {
                text:       qsTr("Kiểm tra lại")
                enabled:    root._referenceFile !== "" && root._state !== "writing"
                onClicked:  root._runCheck()
            }

            Item { Layout.fillWidth: true }

            QGCDelayButton {
                text:               qsTr("Giữ để cập nhật %1 tham số").arg(root._writableCount)
                visible:            root._state === "fail" && root._writableCount > 0
                delay:              root._holdToConfirmMs
                onActivated:        root._writeReferenceValues()
            }
        }
    }
}
