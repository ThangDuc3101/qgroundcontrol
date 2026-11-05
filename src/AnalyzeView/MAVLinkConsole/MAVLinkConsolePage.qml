import QtQuick

import QGroundControl
import QGroundControl.Controls

AnalyzePage {
    pageComponent: pageComponent
    pageDescription: qsTr("Provides a connection to the vehicle's system shell.")
    allowPopout: true

    Component {
        id: pageComponent

        MAVLinkConsoleView {
            height: availableHeight
            width: availableWidth
        }
    }
} // AnalyzePage
