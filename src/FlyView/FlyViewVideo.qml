import QtQuick

import QGroundControl
import QGroundControl.Controls

Item {
    id: _root

    property Item pipView
    property Item pipState: videoPipState

    PipState {
        id:         videoPipState
        pipView:    _root.pipView
        isDark:     true

        onWindowAboutToOpen: {
            QGroundControl.videoManager.stopVideo()
            videoStartDelay.start()
        }

        onWindowAboutToClose: {
            QGroundControl.videoManager.stopVideo()
            videoStartDelay.start()
        }

        onStateChanged: {
            if (pipState.state !== pipState.fullState) {
                QGroundControl.videoManager.fullScreen = false
            }
        }
    }

    Timer {
        id:           videoStartDelay
        interval:     2000;
        running:      false
        repeat:       false
        onTriggered:  QGroundControl.videoManager.startVideo()
    }

    //-- Video Streaming
    FlightDisplayViewVideo {
        id:             videoStreaming
        anchors.fill:   parent
        useSmallFont:   _root.pipState.state !== _root.pipState.fullState
        visible:        QGroundControl.videoManager.isStreamSource || QGroundControl.videoManager.isUvc
    }

    QGCLabel {
        text: qsTr("Double-click to exit full screen")
        font.pointSize: ScreenTools.largeFontPointSize
        visible: QGroundControl.videoManager.fullScreen
        anchors.centerIn: parent

        onVisibleChanged: {
            if (visible) {
                labelAnimation.start()
            }
        }

        PropertyAnimation on opacity {
            id: labelAnimation
            duration: 10000
            from: 1.0
            to: 0.0
            easing.type: Easing.InExpo
        }
    }

    OnScreenGimbalController {
        id:                      onScreenGimbalController
        anchors.fill:            parent
        cameraTrackingEnabled:   !!(videoStreaming._camera && videoStreaming._camera.trackingEnabled)
    }

    OnScreenCameraTrackingController {
        id:                      cameraTrackingController
        anchors.fill:            parent
        camera:                  videoStreaming._camera
        videoWidth:              videoStreaming.getWidth()
        videoHeight:             videoStreaming.getHeight()
    }

    property var _tracking: globals.trackingController

    // Maps a point in this item to 0..1 coordinates inside the decoded video frame (the content area is centered
    // and may be letterboxed or cropped depending on the fill mode). Returns null outside the frame.
    function _videoFramePoint(x, y) {
        var frameWidth = videoStreaming.getWidth()
        var frameHeight = videoStreaming.getHeight()
        if (frameWidth <= 0 || frameHeight <= 0) {
            return null
        }
        var xNorm = (x - (width - frameWidth) / 2) / frameWidth
        var yNorm = (y - (height - frameHeight) / 2) / frameHeight
        if (xNorm < 0 || xNorm >= 1 || yNorm < 0 || yNorm >= 1) {
            return null
        }
        return { xNorm: xNorm, yNorm: yNorm }
    }

    MouseArea {
        id:                         flyViewVideoMouseArea
        anchors.fill:               parent
        enabled:                    pipState.state === pipState.fullState
        acceptedButtons:            Qt.LeftButton | Qt.RightButton

        property real _pressX:      0
        property real _pressY:      0
        property bool _dragging:    false
        property bool _doubleClicked: false
        readonly property real _dragThreshold: 10

        // Defer single-click handling so a double-click (fullscreen toggle) doesn't also
        // fire an unintended gimbal click-to-point/tracking command on its first click.
        Timer {
            id:         singleClickTimer
            interval:   Qt.styleHints.mouseDoubleClickInterval
            repeat:     false

            property real clickX: 0
            property real clickY: 0

            onTriggered: {
                onScreenGimbalController.mouseClicked(clickX, clickY)
                cameraTrackingController.mouseClicked(clickX, clickY)
            }
        }

        onDoubleClicked: {
            // Tracking mode sends every click, so rapid clicks must not be swallowed as a fullscreen toggle
            if (_root._tracking.active) {
                return
            }
            // Fires on the second press of a double-click. The second release still emits
            // onReleased, so flag it to prevent re-arming the single-click timer.
            _doubleClicked = true
            singleClickTimer.stop()
            QGroundControl.videoManager.fullScreen = !QGroundControl.videoManager.fullScreen
        }

        onPressed: (mouse) => {
            // Right click withdraws the current tracking point; it has no other use on the video
            if (mouse.button === Qt.RightButton) {
                if (_root._tracking.active) {
                    _root._tracking.cancelPoint()
                }
                return
            }
            _pressX = mouse.x
            _pressY = mouse.y
            _dragging = false
            // Clear any stale flag (e.g. double-click followed by drag releases through the
            // drag branch without consuming it). Safe: pressed is emitted before doubleClicked.
            _doubleClicked = false
        }

        onPositionChanged: (mouse) => {
            if (_root._tracking.active || !(mouse.buttons & Qt.LeftButton)) {
                return
            }
            if (!_dragging && (Math.abs(mouse.x - _pressX) >= _dragThreshold || Math.abs(mouse.y - _pressY) >= _dragThreshold)) {
                _dragging = true
                onScreenGimbalController.mouseDragStart(_pressX, _pressY)
                cameraTrackingController.mouseDragStart(_pressX, _pressY)
            }
            if (_dragging) {
                onScreenGimbalController.mouseDragPositionChanged(mouse.x, mouse.y)
                cameraTrackingController.mouseDragPositionChanged(mouse.x, mouse.y)
            }
        }

        onReleased: (mouse) => {
            if (mouse.button !== Qt.LeftButton) {
                return
            }
            if (_root._tracking.active) {
                // Send immediately: no single-click deferral and no gimbal / MAVLink camera tracking
                var framePoint = _root._videoFramePoint(mouse.x, mouse.y)
                if (framePoint) {
                    _root._tracking.sendPoint(framePoint.xNorm, framePoint.yNorm)
                }
                return
            }
            if (_dragging) {
                onScreenGimbalController.mouseDragEnd()
                cameraTrackingController.mouseDragEnd(mouse.x, mouse.y)
            } else if (_doubleClicked) {
                // Second release of a double-click - fullscreen toggle already handled
                _doubleClicked = false
            } else {
                singleClickTimer.clickX = mouse.x
                singleClickTimer.clickY = mouse.y
                singleClickTimer.restart()
            }
            _dragging = false
        }
    }

    // Marker on the current tracking point
    Item {
        x:          (_root.width - videoStreaming.getWidth()) / 2 + (_root._tracking.point ? _root._tracking.point.xNorm * videoStreaming.getWidth() : 0)
        y:          (_root.height - videoStreaming.getHeight()) / 2 + (_root._tracking.point ? _root._tracking.point.yNorm * videoStreaming.getHeight() : 0)
        visible:    _root._tracking.active && _root._tracking.point !== null && _root.pipState.state === _root.pipState.fullState

        readonly property real _size: ScreenTools.defaultFontPixelHeight * 2.5

        Rectangle {
            x:              -width / 2
            y:              -height / 2
            width:          parent._size
            height:         width
            radius:         width / 2
            color:          "transparent"
            border.color:   "red"
            border.width:   2
        }
        Rectangle { x: -parent._size / 2; y: -1; width: parent._size; height: 2; color: "red" }
        Rectangle { x: -1; y: -parent._size / 2; width: 2; height: parent._size; color: "red" }
    }

    ProximityRadarVideoView{
        anchors.fill:   parent
        vehicle:        QGroundControl.multiVehicleManager.activeVehicle
    }

    ObstacleDistanceOverlayVideo {
        id: obstacleDistance
        showText: pipState.state === pipState.fullState
    }
}
