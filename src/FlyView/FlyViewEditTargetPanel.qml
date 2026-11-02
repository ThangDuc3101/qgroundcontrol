import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

// In-flight adjustment of the mission's final waypoint (the "is_target" point of the custom plan JSON)
// using the keyboard. Confirming (button or holding Space) posts the adjusted plan to the upload server;
// closing the panel any other way restores the original position.
ColumnLayout {
    id:         root
    spacing:    ScreenTools.defaultFontPixelHeight / 2
    focus:      true

    readonly property real _smallStepMeters:    1
    readonly property real _largeStepMeters:    10
    readonly property int  _mavCmdNavWaypoint:  16 // MAV_CMD_NAV_WAYPOINT; the MAV_CMD enum is not exposed to QML
    readonly property int  _holdToConfirmMs:    1000

    property var    _planController:        globals.planMasterControllerFlyView
    property var    _missionController:     _planController.missionController
    // Captured once in Component.onCompleted (not bound) so Cancel can restore the starting position
    property var    _targetItem:            null
    property var    _originalCoordinate
    property real   _originalAltitude:      0
    property real   _northMeters:           0
    property real   _eastMeters:            0
    property real   _upMeters:              0
    property bool   _confirmed:             false
    property real   _holdProgress:          0 // 0..1 while Space is held down

    function _findTargetItem() {
        var visualItems = _missionController.visualItems
        for (var i = visualItems.count - 1; i >= 0; i--) {
            var item = visualItems.get(i)
            if (item.isSimpleItem && item.command === _mavCmdNavWaypoint) {
                return item
            }
        }
        return null
    }

    function _moveHorizontal(northMeters, eastMeters) {
        var distance = Math.sqrt(northMeters * northMeters + eastMeters * eastMeters)
        var azimuth = Math.atan2(eastMeters, northMeters) * 180 / Math.PI
        _targetItem.coordinate = _targetItem.coordinate.atDistanceAndAzimuth(distance, azimuth)
        _northMeters += northMeters
        _eastMeters += eastMeters
    }

    function _moveVertical(upMeters) {
        _targetItem.altitude.rawValue = _targetItem.altitude.rawValue + upMeters
        _upMeters += upMeters
    }

    function _confirm() {
        _confirmed = true
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
        var step = (event.modifiers & Qt.ShiftModifier) ? _largeStepMeters : _smallStepMeters
        switch (event.key) {
        case Qt.Key_Up:         _moveHorizontal(step, 0);   break
        case Qt.Key_Down:       _moveHorizontal(-step, 0);  break
        case Qt.Key_Right:      _moveHorizontal(0, step);   break
        case Qt.Key_Left:       _moveHorizontal(0, -step);  break
        case Qt.Key_PageUp:     _moveVertical(step);        break
        case Qt.Key_PageDown:   _moveVertical(-step);       break
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

        QGCLabel { text: qsTr("Offset (N/E/Up)") }
        QGCLabel { text: qsTr("%1 / %2 / %3 m").arg(root._northMeters).arg(root._eastMeters).arg(root._upMeters) }
    }

    QGCLabel {
        visible:            root._targetItem !== null
        Layout.fillWidth:   true
        text:               qsTr("Arrow keys: move %1 m, PgUp/PgDn: altitude. Hold Shift for %2 m. Hold Space %3 s to confirm, Esc to cancel.")
                                .arg(root._smallStepMeters).arg(root._largeStepMeters).arg(root._holdToConfirmMs / 1000)
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
        var targetItem = _findTargetItem()
        if (targetItem) {
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
