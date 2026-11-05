import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FlyView

Item {
    required property var guidedValueSlider

    id:     control
    width:  parent.width
    height: ScreenTools.toolbarHeight

    property var    _activeVehicle:     QGroundControl.multiVehicleManager.activeVehicle
    property bool   _communicationLost: _activeVehicle ? _activeVehicle.vehicleLinkManager.communicationLost : false
    property color  _mainStatusBGColor: qgcPal.brandingPurple
    property real   _leftRightMargin:   ScreenTools.defaultFontPixelWidth * 0.75
    property var    _guidedController:  globals.guidedControllerFlyView
    property string _currentBoardStatus: "Đang kết nối..." // from the external UAV info server, see Vehicle::uavInfoReceived

    function dropMainStatusIndicatorTool() {
        mainStatusIndicator.dropMainStatusIndicator();
    }

    QGCPalette { id: qgcPal }

    Connections {
        target:                 _activeVehicle
        enabled:                _activeVehicle !== null
        ignoreUnknownSignals:   true
        function onUavInfoReceived(boardStatus, message) {
            if (_activeVehicle) control._currentBoardStatus = boardStatus
        }
    }

    QGCFlickable {
        id:                 toolBarFlickable
        anchors.fill:       parent
        // The emergency disarm button is pinned outside the scrolling area, see emergencyDisarmPanel
        anchors.rightMargin: emergencyDisarmPanel.visible ? emergencyDisarmPanel.width : 0
        contentWidth:       toolBarLayout.width
        flickableDirection: Flickable.HorizontalFlick

        Row {
            id:         toolBarLayout
            height:     parent.height
            spacing:    0

            Item {
                id:     leftPanel
                width:  leftPanelLayout.implicitWidth
                height: parent.height

                // Gradient background behind Q button and main status indicator
                Rectangle {
                    id:         gradientBackground
                    height:     parent.height
                    width:      mainStatusLayout.width
                    opacity:    qgcPal.windowTransparent.a

                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: _mainStatusBGColor }
                        //GradientStop { position: qgcButton.x + qgcButton.width; color: _mainStatusBGColor }
                        GradientStop { position: 1; color: qgcPal.window }
                    }
                }

                // Standard toolbar background to the right of the gradient
                Rectangle {
                    anchors.left:   gradientBackground.right
                    anchors.right:  parent.right
                    height:         parent.height
                    color:          qgcPal.windowTransparent
                }

                RowLayout {
                    id:         leftPanelLayout
                    height:     parent.height
                    spacing:    ScreenTools.defaultFontPixelWidth * 2

                    RowLayout {
                        id:         mainStatusLayout
                        height:     parent.height
                        spacing:    0

                        QGCToolBarButton {
                            id:                 qgcButton
                            objectName:         "toolbar_qgcLogo"
                            Layout.fillHeight:  true
                            icon.source:        "/res/QGCLogoFull.svg"
                            logo:               true
                            onClicked:          mainWindow.showToolSelectDialog()
                        }

                        MainStatusIndicator {
                            id:                 mainStatusIndicator
                            objectName:         "toolbar_mainStatusIndicator"
                            Layout.fillHeight:  true
                        }
                    }

                    QGCButton {
                        id:         disconnectButton
                        text:       qsTr("Disconnect")
                        onClicked:  _activeVehicle.closeVehicle()
                        visible:    _activeVehicle && _communicationLost
                    }

                    FlightModeIndicator {
                        objectName:         "toolbar_flightModeIndicator"
                        Layout.fillHeight:  true
                        visible:            _activeVehicle
                    }

                    QGCButton {
                        id:         editTargetButton
                        objectName: "toolbar_editTargetButton"
                        text:       qsTr("Edit Target")
                        visible:    _activeVehicle !== null && globals.planMasterControllerFlyView.containsItems
                        onClicked:  mainWindow.showIndicatorDrawer(editTargetPanelComponent, editTargetButton)

                        Component {
                            id: editTargetPanelComponent

                            ToolIndicatorPage {
                                contentComponent: Component { FlyViewEditTargetPanel { } }
                            }
                        }
                    }

                    QGCButton {
                        id:         paramCheckButton
                        objectName: "toolbar_paramCheckButton"
                        text:       qsTr("Kiểm tra Params")
                        visible:    _activeVehicle !== null
                        onClicked:  paramCheckDialogFactory.open()

                        QGCPopupDialogFactory {
                            id:                 paramCheckDialogFactory
                            dialogComponent:    paramCheckDialogComponent
                        }

                        Component {
                            id: paramCheckDialogComponent
                            FlyViewParamCheckDialog { }
                        }
                    }

                    ControlModeButton {
                        objectName:             "toolbar_controlModeButton"
                        vehicle:                _activeVehicle
                        visible:                _activeVehicle !== null
                        Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 24
                    }

                    // Click-to-track: while on, each click on the full-size video posts the pixel to the companion computer
                    QGCButton {
                        id:         trackingButton
                        objectName: "toolbar_trackingButton"
                        text:       globals.trackingController.active ? qsTr("Tracking: BẬT") : qsTr("Tracking")
                        visible:    _activeVehicle !== null
                        checked:    globals.trackingController.active
                        onClicked:  globals.trackingController.setActive(!globals.trackingController.active)
                    }

                    // Shown for the whole tracking session (enabled only with a point) so the toolbar does not reflow
                    // on every click; the tracking status line is drawn over the video instead (FlyViewVideo)
                    QGCButton {
                        objectName: "toolbar_trackingCancelButton"
                        text:       qsTr("Hủy điểm (Esc)")
                        visible:    trackingButton.visible && globals.trackingController.active
                        enabled:    globals.trackingController.point !== null
                        onClicked:  globals.trackingController.cancelPoint()
                    }
                }
            }
            Item {
                id:     centerPanel
                // center panel takes up all remaining space in toolbar between left and right panels
                // never narrower than the board status box, so on small screens the toolbar scrolls instead of the box
                // overlapping the buttons next to it
                width:  Math.max(guidedActionConfirm.visible ? guidedActionConfirm.width : 0,
                                 boardStatusBox.visible ? boardStatusBox.width + ScreenTools.defaultFontPixelWidth * 2 : 0,
                                 toolBarFlickable.width - (leftPanel.width + rightPanel.width))
                height: parent.height

                Rectangle {
                    anchors.fill:   parent
                    color:          qgcPal.windowTransparent
                }

                // Board (fuze) status from the external UAV info server
                Rectangle {
                    id:                 boardStatusBox
                    anchors.centerIn:   parent
                    width:              ScreenTools.defaultFontPixelWidth * 18
                    height:             parent.height * 0.8
                    color:              _currentBoardStatus === "True" ? Qt.rgba(1, 0, 0, 0.25) : Qt.rgba(0, 0.5, 0, 0.2)
                    border.color:       _currentBoardStatus === "True" ? "#ff0000" : "#00ff00"
                    border.width:       3
                    radius:             6
                    visible:            _activeVehicle && !guidedActionConfirm.visible

                    SequentialAnimation on border.color {
                        running:    _currentBoardStatus === "True"
                        loops:      Animation.Infinite
                        ColorAnimation { from: "#ff0000"; to: "#ff6666"; duration: 400 }
                        ColorAnimation { from: "#ff6666"; to: "#ff0000"; duration: 400 }
                    }

                    QGCLabel {
                        anchors.centerIn:   parent
                        text:               _currentBoardStatus === "True"  ? "NGÒI MỞ"
                                          : _currentBoardStatus === "False" ? "AN TOÀN"
                                          : "CHƯA MỞ NGÒI"
                        color:              parent.border.color
                        font.bold:          true
                        font.family:        "Monospace"
                        font.pointSize:     ScreenTools.smallFontPointSize * 1.1
                    }
                }

                GuidedActionConfirm {
                    id:                         guidedActionConfirm
                    height:                     parent.height
                    anchors.horizontalCenter:   parent.horizontalCenter
                    guidedController:           control._guidedController
                    guidedValueSlider:          control.guidedValueSlider
                    messageDisplay:             guidedActionMessageDisplay
                }
            }

            Item {
                id:     rightPanel
                width:  flyViewIndicators.width
                height: parent.height

                Rectangle {
                    anchors.fill:   parent
                    color:          qgcPal.windowTransparent
                }

                FlyViewToolBarIndicators {
                    id:     flyViewIndicators
                    height: parent.height
                }
            }
        }
    }

    // Emergency disarm: hold to confirm, then force-disarm immediately (param2 = 21196), bypassing every firmware
    // check (in air, landing, etc.) and the command queue. No further confirmation dialog. Pinned to the right edge,
    // outside the scrolling toolbar, so it never moves, is never scrolled away and a long press is never taken as a
    // scroll gesture.
    Rectangle {
        id:             emergencyDisarmPanel
        anchors.right:  parent.right
        width:          emergencyDisarmButton.width + _leftRightMargin * 2
        height:         parent.height
        color:          qgcPal.windowTransparent
        visible:        _activeVehicle !== null

        QGCDelayButton {
            id:                 emergencyDisarmButton
            objectName:         "toolbar_emergencyDisarmButton"
            anchors.centerIn:   parent
            text:               qsTr("DISARM KHẨN CẤP")
            delay:              1000
            fontWeight:         Font.Bold
            backgroundColor:    pressed ? "#7f0000" : "#d00000"
            textColor:          "white"
            onActivated:        if (_activeVehicle) _activeVehicle.emergencyStopUnqueued()
        }
    }

    // The guided action message display is outside of the GuidedActionConfirm control so that it doesn't end up as
    // part of the Flickable
    Rectangle {
        id:                         guidedActionMessageDisplay
        anchors.top:                control.bottom
        anchors.topMargin:          _margins
        x:                          control.mapFromItem(guidedActionConfirm.parent, guidedActionConfirm.x, 0).x + (guidedActionConfirm.width - guidedActionMessageDisplay.width) / 2
        width:                      messageLabel.contentWidth + (_margins * 2)
        height:                     messageLabel.contentHeight + (_margins * 2)
        color:                      qgcPal.windowTransparent
        radius:                     ScreenTools.defaultBorderRadius
        visible:                    guidedActionConfirm.visible

        QGCLabel {
            id:         messageLabel
            x:          _margins
            y:          _margins
            width:      ScreenTools.defaultFontPixelWidth * 30
            wrapMode:   Text.WordWrap
            text:       guidedActionConfirm.message
        }

        PropertyAnimation {
            id:         messageOpacityAnimation
            target:     guidedActionMessageDisplay
            property:   "opacity"
            from:       1
            to:         0
            duration:   500
        }

        Timer {
            id:             messageFadeTimer
            interval:       4000
            onTriggered:    messageOpacityAnimation.start()
        }
    }

    ParameterDownloadProgress {
        anchors.fill: parent
    }
}
