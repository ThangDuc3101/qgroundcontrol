import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.AnalyzeView
import QGroundControl.Controls

// The vehicle's system shell in the Fly view, kept out of the way like a chat bubble: a round button in the corner opens
// a small window above it. Nothing else in the view is blocked while it is open, and closing it keeps the session.
Item {
    id: control

    property var    vehicle
    property real   maximumWidth
    property real   maximumHeight

    readonly property real _margin: ScreenTools.defaultFontPixelWidth / 2

    property bool _open:    false
    property bool _loaded:  false   // the session starts with the first open and stays from then on

    width:      bubble.width
    height:     bubble.height
    visible:    vehicle !== null

    function _focusConsole() {
        if (_open && consoleLoader.item) {
            consoleLoader.item.focusInput()
        }
    }

    on_OpenChanged: {
        if (_open) {
            _loaded = true
            Qt.callLater(_focusConsole)
        } else if (consoleLoader.item) {
            // A hidden console keeps the keyboard otherwise, and Enter would send what is typed to the vehicle
            consoleLoader.item.releaseInput()
        }
    }

    onVisibleChanged: {
        if (!visible) {
            _open = false
        }
    }

    QGCPalette { id: qgcPal; colorGroupEnabled: control.enabled }

    Rectangle {
        id:                     consoleWindow
        anchors.right:          bubble.right
        anchors.bottom:         bubble.top
        anchors.bottomMargin:   control._margin
        width:                  Math.min(ScreenTools.defaultFontPixelWidth * 64, control.maximumWidth)
        height:                 Math.min(ScreenTools.defaultFontPixelHeight * 16, control.maximumHeight)
        radius:                 ScreenTools.defaultBorderRadius
        color:                  qgcPal.window
        border.color:           qgcPal.text
        border.width:           1
        visible:                control._open

        Keys.onEscapePressed:   control._open = false

        DeadMouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill:       parent
            anchors.margins:    control._margin * 2
            spacing:            control._margin

            RowLayout {
                Layout.fillWidth:   true
                spacing:            ScreenTools.defaultFontPixelWidth

                QGCLabel { text: qsTr("MAVLink Console") }

                QGCLabel {
                    Layout.fillWidth:       true
                    horizontalAlignment:    Text.AlignRight
                    text:                   qsTr("ARMED: lệnh chạy ngay trên FC")
                    color:                  qgcPal.colorOrange
                    visible:                control.vehicle ? control.vehicle.armed : false
                }
            }

            Loader {
                id:                 consoleLoader
                Layout.fillWidth:   true
                Layout.fillHeight:  true
                active:             control._loaded
                sourceComponent:    MAVLinkConsoleView { }
            }
        }
    }

    Rectangle {
        id:             bubble
        objectName:     "flyView_consoleBubbleButton"
        anchors.right:  parent.right
        anchors.bottom: parent.bottom
        width:          ScreenTools.defaultFontPixelHeight * 3
        height:         width
        radius:         width / 2
        color:          control._open ? qgcPal.buttonHighlight : qgcPal.windowTransparent
        border.color:   qgcPal.text
        border.width:   1

        QGCColoredImage {
            anchors.centerIn:   parent
            width:              parent.width * 0.6
            height:             width
            source:             "/qmlimages/MAVLinkConsoleIcon.svg"
            color:              control._open ? qgcPal.buttonHighlightText : qgcPal.text
        }

        MouseArea {
            anchors.fill:   parent
            cursorShape:    Qt.PointingHandCursor
            onClicked:      control._open = !control._open
        }
    }
}
