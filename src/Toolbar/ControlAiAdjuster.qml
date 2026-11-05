import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

// Adjusts the AI value of the companion computer, shown next to ControlModeButton and only in auto. The value follows
// what the companion computer reports (Vehicle::uavControlAi), never the last press; a pending one is marked with "…".
RowLayout {
    id: control

    property var vehicle

    readonly property bool _auto:           vehicle ? vehicle.uavControlMode === "auto" : false
    readonly property real _ai:             vehicle ? vehicle.uavControlAi : -1
    readonly property bool _aiKnown:        _ai >= 0
    readonly property bool _pending:        _requestedAi >= 0
    readonly property real _shownAi:        _pending ? _requestedAi : _ai
    readonly property real _step:           0.1
    readonly property real _minAi:          0
    readonly property real _maxAi:          1
    readonly property int  _sendDelayMs:    400     // several presses in a row go out as one request
    readonly property int  _confirmMs:      5000    // longer than the POST timeout plus a poll of /uav_info
    readonly property int  _errorShownMs:   3000

    property real _requestedAi: -1  // waiting for the companion computer to report this, negative when none
    property bool _failed:      false

    spacing:    ScreenTools.defaultFontPixelWidth / 2
    visible:    _auto

    function _sameAi(first, second) {
        return Math.abs(first - second) < _step / 10
    }

    function _reset() {
        sendTimer.stop()
        confirmTimer.stop()
        errorTimer.stop()
        _requestedAi = -1
        _failed = false
    }

    function _fail() {
        _reset()
        _failed = true
        errorTimer.restart()
    }

    function _adjust(delta) {
        const next = Number((_shownAi + delta).toFixed(1))
        _failed = false
        errorTimer.stop()
        confirmTimer.stop()
        _requestedAi = Math.min(_maxAi, Math.max(_minAi, next))
        sendTimer.restart()
    }

    on_AutoChanged:     _reset()
    onVehicleChanged:   _reset()

    on_AiChanged: {
        if (_pending && !sendTimer.running && _sameAi(_ai, _requestedAi)) {
            confirmTimer.stop()
            _requestedAi = -1
        }
    }

    QGCPalette { id: qgcPal; colorGroupEnabled: control.enabled }

    QGCButton {
        objectName:             "controlAi_decrease"
        text:                   "−"
        enabled:                control._aiKnown && control._shownAi > control._minAi
        Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 5
        onClicked:              control._adjust(-control._step)
    }

    QGCLabel {
        objectName:             "controlAi_value"
        color:                  control._failed ? qgcPal.colorRed : qgcPal.text
        font.bold:              true
        horizontalAlignment:    Text.AlignHCenter
        text:                   control._failed     ? qsTr("AI: LỖI")
                              : !control._aiKnown   ? qsTr("AI: --")
                              : control._pending    ? qsTr("AI: %1…").arg(control._shownAi.toFixed(1))
                              :                       qsTr("AI: %1").arg(control._shownAi.toFixed(1))
        Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 9
    }

    QGCButton {
        objectName:             "controlAi_increase"
        text:                   "+"
        enabled:                control._aiKnown && control._shownAi < control._maxAi
        Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 5
        onClicked:              control._adjust(control._step)
    }

    Connections {
        target:                 control.vehicle
        ignoreUnknownSignals:   true
        function onUavControlModeSendFinished(success, errorString) {
            if (!success && control._pending && !sendTimer.running) {
                console.warn("AI value change failed:", errorString)
                control._fail()
            }
        }
    }

    Timer {
        id:             sendTimer
        interval:       control._sendDelayMs
        onTriggered: {
            if (!control.vehicle || control._sameAi(control._requestedAi, control._ai)) {
                control._requestedAi = -1
                return
            }
            confirmTimer.restart()
            control.vehicle.sendUavControlAi(control._requestedAi)
        }
    }

    Timer {
        id:             confirmTimer
        interval:       control._confirmMs
        onTriggered:    control._fail()
    }

    Timer {
        id:             errorTimer
        interval:       control._errorShownMs
        onTriggered:    control._failed = false
    }
}
