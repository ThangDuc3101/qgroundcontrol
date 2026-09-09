import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FlyView

RowLayout {
    // TelemetryValuesBar used to live here; it now sits bottom-center in FlyViewWidgetLayer.qml (product request)
    // FlyViewInstrumentPanel (compass/attitude) used to live here too; it now sits top-right in
    // FlyViewTopRightColumnLayout.qml, in the slot left by the hidden PhotoVideoControl (product request)
}
