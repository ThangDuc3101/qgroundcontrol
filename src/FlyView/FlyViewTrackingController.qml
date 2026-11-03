import QtQuick

import QGroundControl

// Click-to-track state shared by the FlyView toolbar and video view (one instance, exposed as
// globals.trackingController). While active, every click on the full-size video records the clicked pixel of the
// decoded video frame under "tracking" on the target (last) waypoint of the last plan sent, then saves and posts
// that plan like Send Plan does (PlanMasterController::sendTrackingToServer), with no confirmation:
//
//   "tracking": { "status": "point" | "cancelled" | "stopped", "seq": int, "timestamp_utc": ISO-8601 string,
//                 "x_px": int | null, "y_px": int | null, "frame_width": int | null, "frame_height": int | null }
//
// The pixel fields are null unless status is "point".
QtObject {
    id: root

    property bool   active:         false
    property var    point:          null    // { xNorm, yNorm } of the current point, for the on-video marker
    property int    seq:            0       // seq of the last update sent
    property string statusText:     ""      // result of the last update, shown in the toolbar
    property bool   statusIsError:  false

    property var _planController: globals.planMasterControllerFlyView
    property string _pendingDescription

    function setActive(enable) {
        if (enable === active) {
            return
        }
        active = enable
        statusText = ""
        statusIsError = false
        if (!enable) {
            point = null
            _send("stopped", null, null, null)
        }
    }

    // xNorm, yNorm: 0..1 inside the decoded video frame, origin top-left. Returns false if nothing was sent.
    function sendPoint(xNorm, yNorm) {
        var frameSize = QGroundControl.videoManager.videoSize
        if (!frameSize || frameSize.width <= 0 || frameSize.height <= 0) {
            // Without the frame size the pixel cannot be computed, and sending nulls would read as a cancel
            statusText = qsTr("Chưa có video, không gửi")
            statusIsError = true
            return false
        }
        var xPx = Math.min(frameSize.width - 1, Math.floor(xNorm * frameSize.width))
        var yPx = Math.min(frameSize.height - 1, Math.floor(yNorm * frameSize.height))
        point = { xNorm: xNorm, yNorm: yNorm }
        _send("point", xPx, yPx, frameSize)
        return true
    }

    // Withdraws the current point (e.g. tapped the wrong object)
    function cancelPoint() {
        if (!point) {
            return
        }
        point = null
        _send("cancelled", null, null, null)
    }

    function _send(status, xPx, yPx, frameSize) {
        seq++
        var tracking = {
            status:         status,
            seq:            seq,
            timestamp_utc:  new Date().toISOString(),
            x_px:           xPx,
            y_px:           yPx,
            frame_width:    frameSize ? frameSize.width : null,
            frame_height:   frameSize ? frameSize.height : null
        }
        _pendingDescription = status === "point" ? qsTr("#%1 điểm (%2, %3)").arg(seq).arg(xPx).arg(yPx)
                                                 : qsTr("#%1 %2").arg(seq).arg(status)
        var errorString = _planController.sendTrackingToServer(JSON.stringify(tracking))
        if (errorString !== "") {
            statusText = qsTr("%1: không gửi - %2").arg(_pendingDescription).arg(errorString)
            statusIsError = true
            return
        }
        statusText = qsTr("%1: đang gửi...").arg(_pendingDescription)
        statusIsError = false
    }

    // The toolbar hides the tracking controls without a vehicle, so never leave the mode on behind the user's back
    property Connections _vehicleConnections: Connections {
        target: QGroundControl.multiVehicleManager
        function onActiveVehicleChanged(activeVehicle) {
            root.setActive(false)
        }
    }

    property Connections _sendConnections: Connections {
        target: root._planController
        function onTrackingSendFinished(sentSeq, success, errorString) {
            if (sentSeq !== root.seq) {
                return // a newer update owns the status line
            }
            root.statusText = success ? qsTr("%1: đã gửi").arg(root._pendingDescription)
                                      : qsTr("%1: lỗi gửi - %2").arg(root._pendingDescription).arg(errorString)
            root.statusIsError = !success
        }
    }
}
