import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

// In-flight adjustment of the mission's final waypoint (the "is_target" point of the custom plan JSON)
// using the keyboard. The arrow keys move it relative to the leg from the previous mission point to the target: up goes
// along that leg, right goes 90 degrees clockwise from it. Confirming (button or holding Space) posts the adjusted plan
// to the upload server; closing the panel any other way restores the original position.
ColumnLayout {
    id:         root
    spacing:    ScreenTools.defaultFontPixelHeight / 2
    focus:      true

    readonly property real _largeStepMultiplier:    10 // applied while Shift is held
    readonly property var  _horizontalStepPresets:  [ 1, 2, 5, 10, 20, 50 ]
    readonly property var  _verticalStepPresets:    [ 0.5, 1, 2, 5, 10 ]
    readonly property int  _mavCmdNavWaypoint:  16 // MAV_CMD_NAV_WAYPOINT; the MAV_CMD enum is not exposed to QML
    readonly property int  _holdToConfirmMs:    1000
    readonly property real _minLegMeters:       0.1 // a shorter leg has no usable direction

    property var    _planController:        globals.planMasterControllerFlyView
    property var    _flyViewSettings:       QGroundControl.settingsManager.flyViewSettings
    property Fact   _horizontalStepFact:    _flyViewSettings.editTargetHorizontalStep
    property Fact   _verticalStepFact:      _flyViewSettings.editTargetVerticalStep
    property var    _missionController:     _planController.missionController
    // Captured once in Component.onCompleted (not bound) so Cancel can restore the starting position
    property var    _targetItem:            null
    property var    _originalCoordinate
    property real   _originalAltitude:      0
    // Captured with the original position: following each move would turn the arrow keys while the target moves
    property real   _legBearing:            0
    property bool   _hasLeg:                false
    property real   _forwardMeters:         0
    property real   _rightMeters:           0
    property real   _upMeters:              0
    property bool   _confirmed:             false
    property real   _holdProgress:          0 // 0..1 while Space is held down

    function _findTargetIndex() {
        var visualItems = _missionController.visualItems
        for (var i = visualItems.count - 1; i >= 0; i--) {
            var item = visualItems.get(i)
            if (item.isSimpleItem && item.command === _mavCmdNavWaypoint) {
                return i
            }
        }
        return -1
    }

    // The closest point the vehicle flies through before the target, which can be the takeoff or home position
    function _findLegStart(targetIndex) {
        var visualItems = _missionController.visualItems
        var targetCoordinate = visualItems.get(targetIndex).coordinate
        for (var i = targetIndex - 1; i >= 0; i--) {
            var item = visualItems.get(i)
            if (item.specifiesCoordinate && !item.isStandaloneCoordinate && item.exitCoordinate.isValid
                    && item.exitCoordinate.distanceTo(targetCoordinate) >= _minLegMeters) {
                return item.exitCoordinate
            }
        }
        return null
    }

    function _moveHorizontal(forwardMeters, rightMeters) {
        var distance = Math.sqrt(forwardMeters * forwardMeters + rightMeters * rightMeters)
        var azimuth = _legBearing + Math.atan2(rightMeters, forwardMeters) * 180 / Math.PI
        _targetItem.coordinate = _targetItem.coordinate.atDistanceAndAzimuth(distance, azimuth)
        _forwardMeters += forwardMeters
        _rightMeters += rightMeters
    }

    function _moveVertical(upMeters) {
        _targetItem.altitude.rawValue = _targetItem.altitude.rawValue + upMeters
        _upMeters += upMeters
    }

    // Steps to the next preset above/below the current value, so custom values typed in the field still cycle sensibly
    function _cycleStep(stepFact, presets, up) {
        var current = stepFact.rawValue
        var next = up ? presets[presets.length - 1] : presets[0]
        if (up) {
            for (var i = 0; i < presets.length; i++) {
                if (presets[i] > current + 1e-6) { next = presets[i]; break }
            }
        } else {
            for (var j = presets.length - 1; j >= 0; j--) {
                if (presets[j] < current - 1e-6) { next = presets[j]; break }
            }
        }
        stepFact.rawValue = next
    }

    function _confirm() {
        _confirmed = true
        globals.sentTargetOriginalCoordinate = _originalCoordinate
        globals.sentTargetCoordinate = _targetItem.coordinate
        _planController.sendCurrentPlanToServer()
        mainWindow.closeIndicatorDrawer()
    }

    function _restoreOriginal() {
        _targetItem.coordinate = _originalCoordinate
        _targetItem.altitude.rawValue = _originalAltitude
    }

    Keys.onPressed: (event) => {
        if (!_targetItem) {
            return
        }
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        var multiplier = shift ? _largeStepMultiplier : 1
        var hStep = _horizontalStepFact.rawValue * multiplier
        var vStep = _verticalStepFact.rawValue * multiplier
        switch (event.key) {
        case Qt.Key_Up:             _moveHorizontal(hStep, 0);  break
        case Qt.Key_Down:           _moveHorizontal(-hStep, 0); break
        case Qt.Key_Right:          _moveHorizontal(0, hStep);  break
        case Qt.Key_Left:           _moveHorizontal(0, -hStep); break
        case Qt.Key_PageUp:         _moveVertical(vStep);       break
        case Qt.Key_PageDown:       _moveVertical(-vStep);      break
        // [ ] cycle the horizontal step; Shift+[ ] (reported as { } on most layouts) cycle the altitude step
        case Qt.Key_BracketLeft:
        case Qt.Key_BracketRight:
            if (shift) {
                _cycleStep(_verticalStepFact, _verticalStepPresets, event.key === Qt.Key_BracketRight)
            } else {
                _cycleStep(_horizontalStepFact, _horizontalStepPresets, event.key === Qt.Key_BracketRight)
            }
            break
        case Qt.Key_BraceLeft:
        case Qt.Key_BraceRight:
            _cycleStep(_verticalStepFact, _verticalStepPresets, event.key === Qt.Key_BraceRight)
            break
        case Qt.Key_Space:
            if (!event.isAutoRepeat) {
                _holdProgress = 0
                holdTimer.start()
            }
            break
        default:                return
        }
        event.accepted = true
    }

    Keys.onReleased: (event) => {
        if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
            holdTimer.stop()
            _holdProgress = 0
            event.accepted = true
        }
    }

    Timer {
        id:         holdTimer
        interval:   20
        repeat:     true
        onTriggered: {
            root._holdProgress = Math.min(1, root._holdProgress + interval / root._holdToConfirmMs)
            if (root._holdProgress >= 1) {
                stop()
                root._confirm()
            }
        }
    }

    QGCLabel {
        text:           qsTr("Edit Target Waypoint")
        font.pointSize: ScreenTools.mediumFontPointSize
    }

    QGCLabel {
        visible:    root._targetItem === null
        text:       qsTr("The mission has no waypoint to edit.")
    }

    GridLayout {
        visible:        root._targetItem !== null
        columns:        2
        columnSpacing:  ScreenTools.defaultFontPixelWidth
        rowSpacing:     0

        QGCLabel { text: qsTr("Latitude") }
        QGCLabel { text: root._targetItem ? root._targetItem.coordinate.latitude.toFixed(7) : "" }

        QGCLabel { text: qsTr("Longitude") }
        QGCLabel { text: root._targetItem ? root._targetItem.coordinate.longitude.toFixed(7) : "" }

        QGCLabel { text: qsTr("Altitude") }
        QGCLabel { text: root._targetItem ? root._targetItem.altitude.valueString + " " + root._targetItem.altitude.units : "" }

        QGCLabel { text: qsTr("Leg bearing") }
        QGCLabel {
            text:   root._hasLeg ? qsTr("%1°").arg(root._legBearing.toFixed(1)) : qsTr("No previous point, using North")
            color:  root._hasLeg ? QGroundControl.globalPalette.text : QGroundControl.globalPalette.colorOrange
        }

        QGCLabel { text: qsTr("Offset (Fwd/Right/Up)") }
        QGCLabel {
            text: qsTr("%1 / %2 / %3 m").arg(root._forwardMeters.toFixed(1)).arg(root._rightMeters.toFixed(1)).arg(root._upMeters.toFixed(1))
        }
    }

    LabelledFactTextField {
        Layout.fillWidth:   true
        visible:            root._targetItem !== null
        label:              qsTr("Horizontal step [ ]")
        fact:               root._horizontalStepFact
        textField.onEditingFinished: root.forceActiveFocus() // give the arrow keys back to the panel
    }

    LabelledFactTextField {
        Layout.fillWidth:   true
        visible:            root._targetItem !== null
        label:              qsTr("Altitude step { }")
        fact:               root._verticalStepFact
        textField.onEditingFinished: root.forceActiveFocus()
    }

    QGCLabel {
        visible:            root._targetItem !== null
        Layout.fillWidth:   true
        text:               qsTr("Arrow keys: move relative to the leg bearing, PgUp/PgDn: altitude, Shift: x%1. Hold Space %2 s to confirm, Esc to cancel.")
                                .arg(root._largeStepMultiplier).arg(root._holdToConfirmMs / 1000)
        font.pointSize:     ScreenTools.smallFontPointSize
        wrapMode:           Text.WordWrap
        Layout.maximumWidth: ScreenTools.defaultFontPixelWidth * 40
    }

    // Hold-to-confirm progress
    Rectangle {
        Layout.fillWidth:       true
        Layout.preferredHeight: ScreenTools.defaultFontPixelHeight / 3
        visible:                root._targetItem !== null
        color:                  QGroundControl.globalPalette.windowShade
        radius:                 height / 2

        Rectangle {
            width:  parent.width * root._holdProgress
            height: parent.height
            color:  QGroundControl.globalPalette.colorGreen
            radius: parent.radius
        }
    }

    RowLayout {
        Layout.fillWidth:   true
        spacing:            ScreenTools.defaultFontPixelWidth

        QGCButton {
            Layout.fillWidth:   true
            text:               qsTr("Cancel")
            onClicked:          mainWindow.closeIndicatorDrawer()
        }

        QGCButton {
            Layout.fillWidth:   true
            text:               qsTr("Confirm && Send")
            enabled:            root._targetItem !== null
            onClicked:          root._confirm()
        }
    }

    // A new mission from the vehicle replaces the items, so the edited item no longer exists
    Connections {
        target: root._missionController
        function onVisualItemsChanged() {
            root._targetItem = null
            mainWindow.closeIndicatorDrawer()
        }
    }

    // Publish the edit state so FlyViewMap can draw the live preview
    on_TargetItemChanged: {
        globals.editTargetOriginalCoordinate = _originalCoordinate
        globals.editTargetItem = _targetItem
    }

    Component.onCompleted: {
        var targetIndex = _findTargetIndex()
        if (targetIndex >= 0) {
            var targetItem = _missionController.visualItems.get(targetIndex)
            var legStart = _findLegStart(targetIndex)
            if (legStart) {
                _legBearing = legStart.azimuthTo(targetItem.coordinate)
                _hasLeg = true
            }
            _originalCoordinate = targetItem.coordinate
            _originalAltitude = targetItem.altitude.rawValue
            _targetItem = targetItem
        }
        forceActiveFocus()
    }

    Component.onDestruction: {
        globals.editTargetItem = null
        if (!_confirmed && _targetItem) {
            _restoreOriginal()
        }
    }
}
