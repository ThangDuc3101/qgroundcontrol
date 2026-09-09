import QtQuick
import QtQuick.Controls

import QGroundControl
import QGroundControl.FlyView
import QGroundControl.FlightMap
import QGroundControl.Controls

Item {
    id:     root
    clip:   true

    property bool useSmallFont: true

    property double _ar:                (cameraLoader.visible && cameraLoader.status === Loader.Ready)
                                            ? cameraLoader.item.implicitWidth / cameraLoader.item.implicitHeight
                                            : QGroundControl.videoManager.aspectRatio
    property bool   _showGrid:          QGroundControl.settingsManager.videoSettings.gridLines.rawValue
    property var    _dynamicCameras:    globals.activeVehicle ? globals.activeVehicle.cameraManager : null
    property bool   _connected:         globals.activeVehicle ? !globals.activeVehicle.communicationLost : false
    property int    _curCameraIndex:    _dynamicCameras ? _dynamicCameras.currentCamera : 0
    property bool   _isCamera:          _dynamicCameras ? _dynamicCameras.cameras.count > 0 : false
    property var    _camera:            _isCamera ? _dynamicCameras.cameras.get(_curCameraIndex) : null
    property bool   _hasZoom:           _camera && _camera.hasZoom
    property int    _fitMode:           QGroundControl.settingsManager.videoSettings.videoFit.rawValue
    property bool   _showStreamLoader:  QGroundControl.videoManager.decoding
    property bool   _showUvcLoader:     QGroundControl.videoManager.isUvc

    property bool   _isMode_FIT_WIDTH:  _fitMode === 0
    property bool   _isMode_FIT_HEIGHT: _fitMode === 1
    property bool   _isMode_FILL:       _fitMode === 2
    property bool   _isMode_NO_CROP:    _fitMode === 3

    // Pitch ladder (product request): same roll/pitch convention as QGCArtificialHorizon.qml
    property var    _horizonVehicle: globals.activeVehicle
    property real   _horizonRoll:    _horizonVehicle ? _horizonVehicle.roll.rawValue  : 0
    property real   _horizonPitch:   _horizonVehicle ? _horizonVehicle.pitch.rawValue : 0
    // Shared vertical scale for the pitch ladder
    readonly property real _pxPerDegree: root.height / 45

    function getWidth() {
        return videoBackground.getWidth()
    }
    function getHeight() {
        return videoBackground.getHeight()
    }

    property double _thermalHeightFactor: 0.85 //-- TODO

    // Icon sizing for the no-video camera-off icon, and shared sizing for the pitch ladder below.
    readonly property real _iconSize:         ScreenTools.defaultFontPixelHeight * (useSmallFont ? 4 : 6)
    readonly property real _hudLineThickness: ScreenTools.defaultFontPixelHeight * 0.06

    // Gun-sight reticle sizing
    readonly property real _crosshairArm:       _iconSize * 0.09
    readonly property real _crosshairGap:       _iconSize * 0.055
    readonly property real _crosshairThickness: ScreenTools.defaultFontPixelHeight * 0.06

        Item {
            id:             noVideo
            anchors.fill:   parent
            visible:        !_showStreamLoader && !_showUvcLoader

            Rectangle {
                anchors.fill: parent
                color:        "black"
            }

            // Camera-off icon at screen center
            Item {
                anchors.centerIn:   parent
                width:              root._iconSize
                height:             width

                QGCColoredImage {
                    anchors.fill:       parent
                    anchors.margins:    parent.width * 0.15
                    source:             "/InstrumentValueIcons/video-camera.svg"
                    fillMode:           Image.PreserveAspectFit
                    sourceSize.width:   width
                    color:              "white"
                    opacity:            0.6
                }

                // Diagonal "off" slash, same color as the camera icon
                Rectangle {
                    anchors.centerIn:   parent
                    width:              parent.width * 1.2
                    height:             ScreenTools.defaultFontPixelHeight * 0.3
                    radius:             height / 2
                    color:              "white"
                    rotation:           45
                }
            }
        }

    Rectangle {
        id:             videoBackground
        anchors.fill:   parent
        color:          "black"
        visible:        _showStreamLoader || _showUvcLoader
        function getWidth() {
            if(_ar != 0.0){
                if(_isMode_FIT_HEIGHT
                        || (_isMode_FILL && (root.width/root.height < _ar))
                        || (_isMode_NO_CROP && (root.width/root.height > _ar))){
                    // This return value has different implications depending on the mode
                    // For FIT_HEIGHT and FILL
                    //    makes so the video width will be larger than (or equal to) the screen width
                    // For NO_CROP Mode
                    //    makes so the video width will be smaller than (or equal to) the screen width
                    return root.height * _ar
                }
            }
            return root.width
        }
        function getHeight() {
            if(_ar != 0.0){
                if(_isMode_FIT_WIDTH
                        || (_isMode_FILL && (root.width/root.height > _ar))
                        || (_isMode_NO_CROP && (root.width/root.height < _ar))){
                    // This return value has different implications depending on the mode
                    // For FIT_WIDTH and FILL
                    //    makes so the video height will be larger than (or equal to) the screen height
                    // For NO_CROP Mode
                    //    makes so the video height will be smaller than (or equal to) the screen height
                    return root.width * (1 / _ar)
                }
            }
            return root.height
        }
        Loader {
            id:                 videoStreamLoader
            anchors.fill:       videoContentArea
            visible:            _showStreamLoader
            sourceComponent:    videoOutputComponent

            property bool videoDisabled: QGroundControl.settingsManager.videoSettings.videoSource.rawValue === QGroundControl.settingsManager.videoSettings.disabledVideoSource
        }
        Component {
            id: videoOutputComponent
            FlightDisplayViewVideoOutput {
            }
        }
        //-- UVC Video (USB Camera or Video Device)
        Loader {
            id:             cameraLoader
            anchors.fill:   videoContentArea
            visible:        _showUvcLoader
            source:         _showUvcLoader ? "qrc:/qml/QGroundControl/FlyView/FlightDisplayViewUVC.qml" : "qrc:/qml/QGroundControl/FlyView/FlightDisplayViewDummy.qml"
        }

        Item {
            id:                 videoContentArea
            height:             parent.getHeight()
            width:              parent.getWidth()
            anchors.centerIn:   parent
            visible:           _showStreamLoader || _showUvcLoader

            // grid lines
            Item {
                anchors.fill:   parent
                visible:        _showGrid && !QGroundControl.videoManager.fullScreen

                Rectangle {
                    color:  Qt.rgba(1,1,1,0.5)
                    height: parent.height
                    width:  1
                    x:      parent.width * 0.33
                }
                Rectangle {
                    color:  Qt.rgba(1,1,1,0.5)
                    height: parent.height
                    width:  1
                    x:      parent.width * 0.66
                }
                Rectangle {
                    color:  Qt.rgba(1,1,1,0.5)
                    width:  parent.width
                    height: 1
                    y:      parent.height * 0.33
                }
                Rectangle {
                    color:  Qt.rgba(1,1,1,0.5)
                    width:  parent.width
                    height: 1
                    y:      parent.height * 0.66
                }
            }
        }

        //-- Thermal Image
        Item {
            id:                 thermalItem
            width:              height * QGroundControl.videoManager.thermalAspectRatio
            height:             _camera ? (_camera.thermalMode === MavlinkCameraControlInterface.THERMAL_FULL ? parent.height : (_camera.thermalMode === MavlinkCameraControlInterface.THERMAL_PIP ? ScreenTools.defaultFontPixelHeight * 12 : parent.height * _thermalHeightFactor)) : 0
            anchors.centerIn:   parent
            visible:            QGroundControl.videoManager.hasThermal && _camera && _camera.thermalMode !== MavlinkCameraControlInterface.THERMAL_OFF
            function pipOrNot() {
                if(_camera) {
                    if(_camera.thermalMode === MavlinkCameraControlInterface.THERMAL_PIP) {
                        anchors.centerIn    = undefined
                        anchors.top         = parent.top
                        anchors.topMargin   = mainWindow.header.height + (ScreenTools.defaultFontPixelHeight * 0.5)
                        anchors.left        = parent.left
                        anchors.leftMargin  = ScreenTools.defaultFontPixelWidth * 12
                    } else {
                        anchors.top         = undefined
                        anchors.topMargin   = undefined
                        anchors.left        = undefined
                        anchors.leftMargin  = undefined
                        anchors.centerIn    = parent
                    }
                }
            }
            Connections {
                target:                 _camera
                function onThermalModeChanged() { thermalItem.pipOrNot() }
            }
            onVisibleChanged: {
                thermalItem.pipOrNot()
            }
            Loader {
                id:             thermalVideo
                anchors.fill:   parent
                opacity:        _camera ? (_camera.thermalMode === MavlinkCameraControlInterface.THERMAL_BLEND ? _camera.thermalOpacity / 100 : 1.0) : 0
                sourceComponent: thermalOutputComponent
                onLoaded: { if (item) item.objectName = "thermalVideo" }

                Component {
                    id: thermalOutputComponent
                    FlightDisplayViewVideoOutput {}
                }
            }
        }
        //-- Zoom
        PinchArea {
            id:             pinchZoom
            enabled:        _hasZoom
            anchors.fill:   parent
            onPinchStarted: pinchZoom.zoom = 0
            onPinchUpdated: {
                if(_hasZoom) {
                    var z = 0
                    if(pinch.scale < 1) {
                        z = Math.round(pinch.scale * -10)
                    } else {
                        z = Math.round(pinch.scale)
                    }
                    if(pinchZoom.zoom != z) {
                        _camera.stepZoom(z)
                    }
                }
            }
            property int zoom: 0
        }
    }

    // Pitch ladder (product request, replaces the old single horizon reference line): a solid
    // rung at 0° pitch (the horizon), major climb (solid) / dive (split, with a center gap -
    // the conventional way HUD ladders tell the two apart at a glance) rungs every 10° out to
    // ±30° with a numeral, and short unlabeled minor rungs every 5° in between (first feedback
    // round: 10°-only steps read as too sparse on a short/wide video frame). A plain sibling of
    // videoBackground/noVideo (not nested in either) so it always renders on top, whether or
    // not a video stream is active. The whole ladder is one rigid body: it fills root so its
    // own center coincides with root's, and translates with pitch / rotates around that shared
    // center with roll, same as QGCArtificialHorizon.qml. Each rung's local y (before that
    // transform) is fixed at -degrees * _pxPerDegree, so a rung lines up with the boresight
    // (screen center) exactly when the vehicle's pitch matches that rung's degree value.
    Item {
        id:           pitchLadder
        anchors.fill: parent

        readonly property var _rungDegrees: [
            { deg: -30, major: true  }, { deg: -25, major: false },
            { deg: -20, major: true  }, { deg: -15, major: false },
            { deg: -10, major: true  }, { deg: -5,  major: false },
            { deg:   5, major: false }, { deg:  10, major: true  },
            { deg:  15, major: false }, { deg:  20, major: true  },
            { deg:  25, major: false }, { deg:  30, major: true  }
        ]

        transform: [
            Translate {
                y: _horizonPitch * _pxPerDegree
            },
            Rotation {
                origin.x: pitchLadder.width  / 2
                origin.y: pitchLadder.height / 2
                angle:    -_horizonRoll
            }
        ]

        // 0° rung (the horizon reference) - solid, full width, unlabeled. Same size/position
        // the old horizonLine used, so attitude at rest looks unchanged.
        Rectangle {
            anchors.centerIn: parent
            width:            root.width * 0.3
            height:           ScreenTools.defaultFontPixelHeight * 0.1
            color:            "red"
        }

        Repeater {
            model: pitchLadder._rungDegrees

            Item {
                id: rung

                readonly property real _degrees: modelData.deg
                readonly property bool _major:   modelData.major
                readonly property real _rungY:   pitchLadder.height / 2 - (_degrees * _pxPerDegree)

                anchors.horizontalCenter: pitchLadder.horizontalCenter
                y:      _rungY - height / 2
                width:  _major ? root.width * 0.18 : root.width * 0.09
                height: _hudLineThickness

                // Climb rungs (positive pitch): one solid segment
                Rectangle {
                    visible:      rung._degrees > 0
                    anchors.fill: parent
                    color:        "red"
                }
                // Dive rungs (negative pitch): split with a center gap
                Rectangle {
                    visible:      rung._degrees < 0
                    anchors.left: parent.left
                    width:        parent.width / 2 - _hudLineThickness
                    height:       parent.height
                    color:        "red"
                }
                Rectangle {
                    visible:       rung._degrees < 0
                    anchors.right: parent.right
                    width:         parent.width / 2 - _hudLineThickness
                    height:        parent.height
                    color:         "red"
                }

                Text {
                    visible:                rung._major
                    anchors.left:           parent.right
                    anchors.leftMargin:     ScreenTools.defaultFontPixelWidth * 0.5
                    anchors.verticalCenter: parent.verticalCenter
                    text:                   Math.abs(rung._degrees)
                    color:                  "red"
                    font.bold:              true
                    font.pointSize:         ScreenTools.smallFontPointSize
                }
            }
        }
    }

    // Small gun-sight-style reticle (4 short arms with a center gap). A plain sibling of
    // videoBackground/noVideo (not nested in either) so it always renders on top, whether or not
    // a video stream is active — previously it lived inside noVideo and vanished as soon as
    // streaming started. (Tried swapping this for a telemetry-driven flight path marker; reverted
    // - not visible enough on-device to be worth the added complexity.)
    Item {
        id:             crosshair
        anchors.fill:   parent

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom:           parent.verticalCenter
            anchors.bottomMargin:     root._crosshairGap
            width:  root._crosshairThickness
            height: root._crosshairArm
            color:  "red"
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top:              parent.verticalCenter
            anchors.topMargin:        root._crosshairGap
            width:  root._crosshairThickness
            height: root._crosshairArm
            color:  "red"
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right:          parent.horizontalCenter
            anchors.rightMargin:    root._crosshairGap
            height: root._crosshairThickness
            width:  root._crosshairArm
            color:  "red"
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left:           parent.horizontalCenter
            anchors.leftMargin:     root._crosshairGap
            height: root._crosshairThickness
            width:  root._crosshairArm
            color:  "red"
        }
    }
}
