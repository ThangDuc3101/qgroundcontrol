import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

// Quick access to the RC/Joystick and Data Link loss failsafe settings from the Safety setup page
Item {
    id:             control
    objectName:     "toolbar_px4FailsafeIndicator"
    anchors.top:    parent.top
    anchors.bottom: parent.bottom
    width:          failsafeIcon.width * 1.1

    property bool showIndicator: _activeVehicle !== null

    property var _activeVehicle: QGroundControl.multiVehicleManager.activeVehicle

    QGCColoredImage {
        id:                 failsafeIcon
        anchors.top:        parent.top
        anchors.bottom:     parent.bottom
        width:              height
        sourceSize.height:  height
        source:             "/InstrumentValueIcons/shield.svg"
        fillMode:           Image.PreserveAspectFit
        color:              qgcPal.buttonText
    }

    MouseArea {
        anchors.fill:   parent
        onClicked:      mainWindow.showIndicatorDrawer(failsafeInfoPage, control)
    }

    Component {
        id: failsafeInfoPage

        ToolIndicatorPage {
            showExpand:         false
            waitForParameters:  true

            contentComponent: ColumnLayout {
                spacing: ScreenTools.defaultFontPixelHeight / 2

                FactPanelController { id: controller }

                SettingsGroupLayout {
                    Layout.fillWidth:   true
                    heading:            qsTr("RC/Joystick Loss Failsafe")

                    LabelledFactComboBox {
                        Layout.fillWidth:   true
                        visible:            fact !== null
                        label:              qsTr("Failsafe action")
                        fact:               controller.getParameterFact(-1, "NAV_RCL_ACT", false)
                        indexModel:         false
                    }

                    LabelledFactTextField {
                        Layout.fillWidth:   true
                        visible:            fact !== null
                        label:              qsTr("RC/joystick loss timeout")
                        fact:               controller.getParameterFact(-1, "COM_RC_LOSS_T", false)
                    }
                }

                SettingsGroupLayout {
                    Layout.fillWidth:   true
                    heading:            qsTr("Data Link Loss Failsafe")

                    LabelledFactComboBox {
                        Layout.fillWidth:   true
                        visible:            fact !== null
                        label:              qsTr("Failsafe action")
                        fact:               controller.getParameterFact(-1, "NAV_DLL_ACT", false)
                        indexModel:         false
                    }

                    LabelledFactTextField {
                        Layout.fillWidth:   true
                        visible:            fact !== null
                        label:              qsTr("Data link loss timeout")
                        fact:               controller.getParameterFact(-1, "COM_DL_LOSS_T", false)
                    }
                }
            }
        }
    }
}
