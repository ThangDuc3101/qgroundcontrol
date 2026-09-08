import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

//-------------------------------------------------------------------------
//-- Clock Indicator (local GCS date/time, replaces BatteryIndicator's toolbar slot)
Item {
    id:             control
    objectName:     "toolbar_clockIndicator"
    anchors.top:    parent.top
    anchors.bottom: parent.bottom
    width:          clockColumn.width

    property bool showIndicator: true

    QGCPalette { id: qgcPal }

    Timer {
        interval:         1000
        running:          true
        repeat:           true
        triggeredOnStart: true
        onTriggered: {
            const now = new Date()
            timeLabel.text = Qt.formatTime(now, Qt.locale().timeFormat(Locale.ShortFormat))
            dateLabel.text = Qt.formatDate(now, Qt.locale().dateFormat(Locale.ShortFormat))
        }
    }

    ColumnLayout {
        id:                     clockColumn
        anchors.verticalCenter: parent.verticalCenter
        spacing:                0

        QGCLabel {
            id:                 timeLabel
            Layout.alignment:   Qt.AlignHCenter
            font.pointSize:     ScreenTools.defaultFontPointSize
            color:              qgcPal.text
        }

        QGCLabel {
            id:                 dateLabel
            Layout.alignment:   Qt.AlignHCenter
            font.pointSize:     ScreenTools.smallFontPointSize
            color:              qgcPal.text
        }
    }
}
