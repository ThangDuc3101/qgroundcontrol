import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FlyView

RowLayout {
    // TelemetryValuesBar used to live here; it now sits bottom-center in FlyViewWidgetLayer.qml (product request)

    FlyViewInstrumentPanel {
        id:                 instrumentPanel
        Layout.alignment:   Qt.AlignBottom
        visible:            QGroundControl.corePlugin.options.flyView.showInstrumentPanel && _showSingleVehicleUI
    }
}
