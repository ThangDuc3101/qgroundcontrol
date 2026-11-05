import QtQuick

import QGroundControl
import QGroundControl.Controls

// Switches the control mode of the companion computer, which is its own mode, not a PX4 flight mode. A hold goes from
// auto to manual GPS and from either manual mode back to auto. A click swaps manual GPS and manual image, and does
// nothing in auto.
// The label follows what the companion computer reports (Vehicle::uavControlMode), never the last press, so an
// unconfirmed change or a lost server shows as such instead of as the mode that was asked for.
QGCDelayButton {
    id: control

    property var vehicle

    readonly property string _mode:         vehicle ? vehicle.uavControlMode : ""
    readonly property bool   _modeKnown:    _mode !== ""
    readonly property int    _clickMaxMs:   400     // a longer press is an abandoned hold, not a click
    readonly property int    _confirmMs:    5000    // longer than the POST timeout plus a poll of /uav_info
    readonly property int    _errorShownMs: 3000

    property string _requestedMode: ""  // waiting for the companion computer to report this
    property bool   _failed:        false
    property double _pressedAtMs:   0

    delay:          1000
    enabled:        _modeKnown
    fontWeight:     Font.Bold
    textColor:      "white"
    text:           _failed                 ? qsTr("LỖI ĐỔI CHẾ ĐỘ")
                  : _requestedMode !== ""   ? qsTr("ĐANG ĐỔI...")
                  : _mode === "auto"        ? qsTr("CHẾ ĐỘ: TỰ ĐỘNG")
                  : _mode === "manual_gps"  ? qsTr("CHẾ ĐỘ: THỦ CÔNG GPS")
                  : _mode === "manual_image" ? qsTr("CHẾ ĐỘ: THỦ CÔNG ẢNH")
                  :                           qsTr("CHẾ ĐỘ: CHƯA RÕ")
    backgroundColor: _failed                ? "#8b1a1a"
                   : !_modeKnown            ? "#555555"
                   : _mode === "auto"       ? "#1b7f3b"
                   : _mode === "manual_gps" ? "#b86e00"
                   :                          "#1f5fa8"

    function _fail() {
        confirmTimer.stop()
        _requestedMode = ""
        _failed = true
        errorTimer.restart()
    }

    function _request(mode) {
        if (!vehicle || !_modeKnown || _requestedMode !== "") {
            return
        }
        _failed = false
        errorTimer.stop()
        _requestedMode = mode
        confirmTimer.restart()
        vehicle.sendUavControlMode(mode)
    }

    onPressed:      _pressedAtMs = Date.now()
    onActivated:    _request(_mode === "auto" ? "manual_gps" : "auto")

    // Also comes after a hold, which the press time rules out
    onClicked: {
        if (_mode !== "auto" && Date.now() - _pressedAtMs < _clickMaxMs) {
            _showHelp = false
            _request(_mode === "manual_gps" ? "manual_image" : "manual_gps")
        }
    }

    on_ModeChanged: {
        if (_requestedMode !== "" && _mode === _requestedMode) {
            confirmTimer.stop()
            _requestedMode = ""
        }
    }

    onVehicleChanged: {
        confirmTimer.stop()
        errorTimer.stop()
        _requestedMode = ""
        _failed = false
    }

    Connections {
        target:                 control.vehicle
        ignoreUnknownSignals:   true
        function onUavControlModeSendFinished(success, errorString) {
            if (!success && control._requestedMode !== "") {
                console.warn("Control mode change failed:", errorString)
                control._fail()
            }
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
