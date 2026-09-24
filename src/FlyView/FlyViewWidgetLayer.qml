import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

import QtLocation
import QtPositioning
import QtQuick.Window
import QtQml.Models

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FlyView
import QGroundControl.FlightMap
import QGroundControl.Viewer3D

// This is the ui overlay layer for the widgets/tools for Fly View
Item {
    id: _root

    property var    parentToolInsets
    property var    totalToolInsets:        _totalToolInsets
    property var    mapControl
    property var    viewer3DCameraController
    property color  mainStatusBGColor:      qgcPal.brandingPurple // FlyViewToolBar's live status color (red/green/yellow/idle)

    property var    _activeVehicle:         QGroundControl.multiVehicleManager.activeVehicle
    property var    _planMasterController:  globals.planMasterControllerFlyView
    property var    _missionController:     _planMasterController.missionController
    property var    _geoFenceController:    _planMasterController.geoFenceController
    property var    _rallyPointController:  _planMasterController.rallyPointController
    property var    _guidedController:      globals.guidedControllerFlyView
    property real   _margins:               ScreenTools.defaultFontPixelWidth / 2
    property real   _toolsMargin:           ScreenTools.defaultFontPixelWidth * 0.75
    property rect   _centerViewport:        Qt.rect(0, 0, width, height)
    property real   _rightPanelWidth:       ScreenTools.defaultFontPixelWidth * 30
    property real   _layoutMargin:          ScreenTools.defaultFontPixelWidth * 0.75
    property bool   _layoutSpacing:         ScreenTools.defaultFontPixelWidth
    property bool   _showSingleVehicleUI:   true

    // Drag-to-resize state for bottomCenterTelemetryBar (product request). Session-only, not persisted.
    property real         _telemetryBarUserScale: 1.0
    readonly property real _telemetryBarMinScale:  0.6
    readonly property real _telemetryBarMaxScale:  2.5

    QGCToolInsets {
        id:                     _totalToolInsets
        leftEdgeTopInset:       Math.max(toolStrip.leftEdgeTopInset, parentToolInsets.leftEdgeTopInset)
        leftEdgeCenterInset:    toolStrip.leftEdgeCenterInset
        leftEdgeBottomInset:    virtualJoystickMultiTouch.visible ? virtualJoystickMultiTouch.leftEdgeBottomInset : parentToolInsets.leftEdgeBottomInset
        rightEdgeTopInset:      topRightPanel.rightEdgeTopInset
        rightEdgeCenterInset:   topRightPanel.rightEdgeCenterInset
        rightEdgeBottomInset:   bottomRightRowLayout.rightEdgeBottomInset
        topEdgeLeftInset:       Math.max(toolStrip.topEdgeLeftInset, parentToolInsets.topEdgeLeftInset)
        topEdgeCenterInset:     mapScale.topEdgeCenterInset
        topEdgeRightInset:      topRightPanel.topEdgeRightInset
        bottomEdgeLeftInset:    virtualJoystickMultiTouch.visible ? virtualJoystickMultiTouch.bottomEdgeLeftInset : parentToolInsets.bottomEdgeLeftInset
        bottomEdgeCenterInset:  bottomCenterTelemetryBar.bottomEdgeCenterInset
        bottomEdgeRightInset:   virtualJoystickMultiTouch.visible ? virtualJoystickMultiTouch.bottomEdgeRightInset : bottomRightRowLayout.bottomEdgeRightInset
    }

    FlyViewTopRightPanel {
        id:                     topRightPanel
        anchors.top:            parent.top
        anchors.right:          parent.right
        maximumHeight:          parent.height - (bottomRightRowLayout.height + _margins * 4)

        property real topEdgeRightInset:    height + _layoutMargin
        property real rightEdgeTopInset:    width + _layoutMargin
        property real rightEdgeCenterInset: rightEdgeTopInset
    }

    FlyViewTopRightColumnLayout {
        id:                 topRightColumnLayout
        anchors.top:        parent.top
        anchors.right:      parent.right
        spacing:            _layoutSpacing
        visible:           !topRightPanel.visible

        property real topEdgeRightInset:    childrenRect.height + _layoutMargin
        property real rightEdgeTopInset:    width + _layoutMargin
        property real rightEdgeCenterInset: rightEdgeTopInset
    }

    FlyViewBottomRightRowLayout {
        id:                 bottomRightRowLayout
        anchors.bottom:     parent.bottom
        anchors.right:      parent.right
        spacing:            _layoutSpacing

        property real bottomEdgeRightInset:     height + _layoutMargin
        property real rightEdgeBottomInset:     width + _layoutMargin
    }

    //-- Telemetry values, moved out of bottomRightRowLayout to sit bottom-center (product request)
    TelemetryValuesBar {
        id:                     bottomCenterTelemetryBar
        anchors.bottom:         parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        scale:                  _telemetryBarUserScale
        transformOrigin:        Item.Bottom
        borderColor:            mainStatusBGColor // tracks the toolbar's live status color, right after the Q logo
        borderWidth:            2
        settingsGroup:          factValueGrid.telemetryBarSettingsGroup
        specificVehicleForCard: null // Tracks active vehicle

        property real bottomEdgeCenterInset: height + _layoutMargin
    }

    // Drag handle to resize bottomCenterTelemetryBar on the fly (product request). Drag to scale
    // up/down, double-click/tap to reset to 1:1. Same pipResize.svg + top-right placement as
    // PipView's resize handle. bottomCenterTelemetryBar's transformOrigin is Item.Bottom (bottom
    // edge fixed, grows symmetrically left/right/up), so its actual *visual* top-right corner under
    // "scale" is at local (width/2 * (1 + scale), height * (1 - scale)) — track that point
    // explicitly rather than anchoring to the unscaled .right/.top, which "scale" doesn't move.
    Image {
        id:             telemetryBarResizeIcon
        source:         "/qmlimages/pipResize.svg"
        fillMode:       Image.PreserveAspectFit
        mipmap:         true
        height:         ScreenTools.defaultFontPixelHeight * 1.5
        width:          height
        x:              bottomCenterTelemetryBar.x + (bottomCenterTelemetryBar.width / 2) * (1 + bottomCenterTelemetryBar.scale) - width / 2
        y:              bottomCenterTelemetryBar.y + bottomCenterTelemetryBar.height * (1 - bottomCenterTelemetryBar.scale) - height / 2
        z:              QGroundControl.zOrderTopMost

        MouseArea {
            id:                 telemetryBarResizeDrag
            anchors.fill:       parent
            preventStealing:    true
            cursorShape:        Qt.PointingHandCursor

            property real _pressX:           0
            property real _pressY:           0
            property real _scaleAtPressStart: 1.0

            onPressed: (mouse) => {
                _pressX = mouse.x
                _pressY = mouse.y
                _scaleAtPressStart = _telemetryBarUserScale
            }

            onPositionChanged: (mouse) => {
                if (pressed) {
                    const delta = ((mouse.x - _pressX) + (mouse.y - _pressY)) / (ScreenTools.defaultFontPixelHeight * 8)
                    _telemetryBarUserScale = Math.min(_telemetryBarMaxScale, Math.max(_telemetryBarMinScale, _scaleAtPressStart + delta))
                }
            }

            onDoubleClicked: _telemetryBarUserScale = 1.0
        }
    }

    FlyViewMissionCompleteDialog {
        missionController:      _missionController
        geoFenceController:     _geoFenceController
        rallyPointController:   _rallyPointController
    }

    // Prevent the map's PinchHandler from stealing touch grabs from the joystick pads (issue #13450)
    Binding {
        target:   mapControl
        property: "pinchZoomDisabledByVirtualJoysticks"
        value:    virtualJoystickMultiTouch.visible && virtualJoystickMultiTouch.item && virtualJoystickMultiTouch.item.stickActive
    }

    //-- Virtual Joystick
    Loader {
        id:                         virtualJoystickMultiTouch
        z:                          QGroundControl.zOrderTopMost + 1
        anchors.right:              parent.right
        anchors.rightMargin:        anchors.leftMargin
        height:                     Math.min(parent.height * 0.25, ScreenTools.defaultFontPixelWidth * 16)
        visible:                    _virtualJoystickEnabled && !QGroundControl.videoManager.fullScreen && !(_activeVehicle ? _activeVehicle.usingHighLatencyLink : false)
        anchors.bottom:             parent.bottom
        anchors.bottomMargin:       bottomLoaderMargin
        anchors.left:               parent.left
        anchors.leftMargin:         ( y > toolStrip.y + toolStrip.height ? toolStrip.width / 2 : toolStrip.width * 1.05 + toolStrip.x)
        source:                     "qrc:/qml/QGroundControl/FlyView/VirtualJoystick.qml"
        active:                     _virtualJoystickEnabled && !(_activeVehicle ? _activeVehicle.usingHighLatencyLink : false)

        property real bottomEdgeLeftInset:     parent.height-y
        property bool autoCenterThrottle:      QGroundControl.settingsManager.appSettings.virtualJoystickAutoCenterThrottle.rawValue
        property bool leftHandedMode:          QGroundControl.settingsManager.appSettings.virtualJoystickLeftHandedMode.rawValue
        property bool _virtualJoystickEnabled: QGroundControl.settingsManager.appSettings.virtualJoystick.rawValue
        property real bottomEdgeRightInset:    parent.height-y
        property var  _pipViewMargin:          _pipView.visible ? parentToolInsets.bottomEdgeLeftInset + ScreenTools.defaultFontPixelHeight * 2 :
                                               bottomRightRowLayout.height + ScreenTools.defaultFontPixelHeight * 1.5

        property var  bottomLoaderMargin:      _pipViewMargin >= parent.height / 2 ? parent.height / 2 : _pipViewMargin

        // Width is difficult to access directly hence this hack which may not work in all circumstances
        property real leftEdgeBottomInset:  visible ? bottomEdgeLeftInset + width/18 - ScreenTools.defaultFontPixelHeight*2 : 0
        property real rightEdgeBottomInset: visible ? bottomEdgeRightInset + width/18 - ScreenTools.defaultFontPixelHeight*2 : 0
        property real rootWidth:            _root.width
        property var  itemX:                virtualJoystickMultiTouch.x   // real X on screen

        onRootWidthChanged: virtualJoystickMultiTouch.status == Loader.Ready && visible ? virtualJoystickMultiTouch.item.uiTotalWidth = rootWidth : undefined
        onItemXChanged:     virtualJoystickMultiTouch.status == Loader.Ready && visible ? virtualJoystickMultiTouch.item.uiRealX = itemX : undefined

        //Loader status logic
        onLoaded: {
            if (virtualJoystickMultiTouch.visible) {
                virtualJoystickMultiTouch.item.calibration = true
                virtualJoystickMultiTouch.item.uiTotalWidth = rootWidth
                virtualJoystickMultiTouch.item.uiRealX = itemX
            } else {
                virtualJoystickMultiTouch.item.calibration = false
            }
        }
    }

    FlyViewToolStrip {
        id:                     toolStrip
        anchors.left:           parent.left
        anchors.top:            parent.top
        z:                      QGroundControl.zOrderWidgets
        maxHeight:              parent.height - y - parentToolInsets.bottomEdgeLeftInset - _toolsMargin
        visible:                false // temporarily hidden (product request); restore "!QGroundControl.videoManager.fullScreen" to bring back Takeoff/Land/RTL/... actions

        onDisplayPreFlightChecklist: {
            if (!preFlightChecklistLoader.active) {
                preFlightChecklistLoader.active = true
            }
            preFlightChecklistLoader.item.open()
        }

        property real topEdgeLeftInset:     visible ? y + height : 0
        property real leftEdgeTopInset:     visible ? x + width : 0
        property real leftEdgeCenterInset:  leftEdgeTopInset
    }

    VehicleWarnings {
        anchors.centerIn:   parent
        z:                  QGroundControl.zOrderTopMost
    }

    // Operator message from the external UAV info server (Vehicle::uavInfoReceived), auto-hides after 5s.
    // Top-center rather than top-right: the top-right slot holds the compass/attitude instrument panel.
    Rectangle {
        id:                         uavMessageContainer
        anchors.top:                parent.top
        anchors.topMargin:          ScreenTools.defaultFontPixelHeight * 0.5
        anchors.horizontalCenter:   parent.horizontalCenter
        width:                      uavMessageLabel.implicitWidth + (_margins * 4)
        height:                     uavMessageLabel.implicitHeight + (_margins * 2)
        color:                      Qt.rgba(0.8, 0, 0, 0.9)
        border.color:               _uavMessageAccentRed
        border.width:               3
        radius:                     8
        z:                          QGroundControl.zOrderWidgets
        visible:                    uavMessageLabel.text !== ""

        readonly property color _uavMessageAccentRed: "#ff0000"

        // 2 "glow" outlines
        Rectangle {
            anchors.fill:       parent
            anchors.margins:    -4
            color:              "transparent"
            border.color:       parent._uavMessageAccentRed
            border.width:       2
            radius:             parent.radius + 2
            opacity:            0.4
            z:                  -1
        }
        Rectangle {
            anchors.fill:       parent
            anchors.margins:    -8
            color:              "transparent"
            border.color:       parent._uavMessageAccentRed
            border.width:       1
            radius:             parent.radius + 4
            opacity:            0.2
            z:                  -2
        }

        QGCLabel {
            id:                 uavMessageLabel
            anchors.centerIn:   parent
            font.pointSize:     ScreenTools.defaultFontPointSize * 2
            font.bold:          true
            font.family:        "Monospace"
            color:              "#ffffff"
            text:               ""

            Connections {
                target:                 _activeVehicle
                ignoreUnknownSignals:   true
                function onUavInfoReceived(boardStatus, message) {
                    if (message) {
                        uavMessageLabel.text = message
                    }
                }
            }

            Timer {
                id:             hideMessageTimer
                interval:       5000
                running:        uavMessageLabel.text !== ""
                repeat:         false
                onTriggered:    uavMessageLabel.text = ""
            }

            onTextChanged: if (text !== "") hideMessageTimer.restart()
        }
    }

    MapScale {
        id:                 mapScale
        anchors.left:       parent.left
        anchors.leftMargin: _totalToolInsets.leftEdgeTopInset + _toolsMargin // clears toolStrip (if re-enabled) and the top-left video PIP
        anchors.top:        parent.top
        mapControl:         _mapControl
        autoHide:           true
        visible:            !ScreenTools.isTinyScreen && QGroundControl.corePlugin.options.flyView.showMapScale && QGCViewer3DManager.displayMode !== QGCViewer3DManager.View3D && mapControl.pipState.state === mapControl.pipState.fullState

        property real topEdgeCenterInset: visible ? y + height : 0
    }

    Viewer3DScaleBar {
        objectName:         "viewer3DScaleBar"
        anchors.left:       parent.left
        anchors.leftMargin: _totalToolInsets.leftEdgeTopInset + _toolsMargin // clears toolStrip (if re-enabled) and the top-left video PIP
        anchors.top:        parent.top
        controller:         _root.viewer3DCameraController
        autoHide:           true
        visible:            !ScreenTools.isTinyScreen && QGroundControl.corePlugin.options.flyView.showMapScale && QGCViewer3DManager.displayMode === QGCViewer3DManager.View3D && !!_root.viewer3DCameraController
    }

    Loader {
        id: preFlightChecklistLoader
        sourceComponent: preFlightChecklistPopup
        active: false
    }

    Component {
        id: preFlightChecklistPopup
        FlyViewPreFlightChecklistPopup {
        }
    }
}
