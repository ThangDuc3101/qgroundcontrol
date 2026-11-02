import QGroundControl
import QGroundControl.FlyView

ToolStripAction {
    text:       qsTr("Edit Target")
    iconSource: "/InstrumentValueIcons/edit-pencil.svg"
    visible:    _activeVehicle !== null && _planController.containsItems

    property var _activeVehicle:    QGroundControl.multiVehicleManager.activeVehicle
    property var _planController:   globals.planMasterControllerFlyView

    dropPanelComponent: Component {
        FlyViewEditTargetDropPanel {
        }
    }
}
