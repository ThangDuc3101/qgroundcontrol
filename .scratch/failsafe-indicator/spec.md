# Spec: Đưa RC Loss / Data Link Loss Failsafe ra FlyView (PX4)

Status: done

Đã làm ở commit `d559cba68` (feat(PX4): add failsafe toolbar indicator to FlyView), file `src/FirmwarePlugin/PX4/PX4FailsafeIndicator.qml`.

## Mục tiêu

Đưa nguyên hai mục **RC/Joystick Loss Failsafe** và **Data Link Loss Failsafe** của trang Vehicle Setup > Safety ra FlyView để chỉnh nhanh.

**Giữ nguyên logic của trang Safety:** cùng tham số, cùng control, cùng hành vi. Không thêm logic trạng thái, màu cảnh báo hay khoá khi armed.

## Nguồn gốc

Trang Safety của PX4 được sinh từ `src/AutoPilotPlugins/PX4/VehicleConfig/Safety.VehicleConfig.json` (khoảng dòng 90–138). Sau khi generate, hai mục này chỉ gồm:

```qml
FactPanelController { id: controller }

ConfigSection {
    heading: "RC/Joystick Loss Failsafe"
    iconSource: "/qmlimages/RCLoss.svg"
    LabelledFactComboBox  { label: "Failsafe action";          fact: controller.getParameterFact(-1, "NAV_RCL_ACT", false); indexModel: false }
    LabelledFactTextField { label: "RC/joystick loss timeout"; fact: controller.getParameterFact(-1, "COM_RC_LOSS_T", false) }
}
ConfigSection {
    heading: "Data Link Loss Failsafe"
    iconSource: "/qmlimages/DatalinkLoss.svg"
    LabelledFactComboBox  { label: "Failsafe action";          fact: controller.getParameterFact(-1, "NAV_DLL_ACT", false); indexModel: false }
    LabelledFactTextField { label: "Data link loss timeout";   fact: controller.getParameterFact(-1, "COM_DL_LOSS_T", false) }
}
```

## Thiết kế UI

Một icon trên toolbar FlyView. Bấm vào icon sẽ mở drawer chứa đúng hai mục trên.

```
┌ toolbar ──────────────────────────────────────────┐
│ Mode  GPS  Tele  RC  [🛡 Failsafe]  Batt  ...      │
└───────────────────────┬───────────────────────────┘
                        ↓ bấm
        ┌ RC/Joystick Loss Failsafe ───────────┐
        │ Failsafe action    [ Return mode ▼]  │
        │ RC/joystick loss timeout  [ 0.5 ] s  │
        ├ Data Link Loss Failsafe ─────────────┤
        │ Failsafe action    [ Return mode ▼]  │
        │ Data link loss timeout    [ 10  ] s  │
        └──────────────────────────────────────┘
```

## Triển khai

1. Tạo `src/FirmwarePlugin/PX4/PX4FailsafeIndicator.qml`:
   - Phần icon và MouseArea theo mẫu `src/Toolbar/RCRSSIIndicator.qml`.
   - Drawer là một `ToolIndicatorPage { waitForParameters: true }`, có `contentComponent` chứa `FactPanelController` và hai `ConfigSection` copy y nguyên từ trang Safety đã generate.
   - `showIndicator: _activeVehicle !== null`.
2. Đăng ký file QML trong `CMakeLists.txt` của module PX4 FirmwarePlugin.
3. Override `PX4FirmwarePlugin::toolIndicators()` theo mẫu `APMFirmwarePlugin::toolIndicators` (`src/FirmwarePlugin/APM/APMFirmwarePlugin.cc:631`). Gọi lớp gốc trước, rồi chèn URL của indicator mới. `AGENTS.md` quy định logic riêng cho PX4 phải đi qua FirmwarePlugin.
4. Trước khi code: đọc `CODING_STYLE.md`. Done = `just build` + `just lint` + commit `feat(PX4): ...`.

## Đánh đổi

Drawer copy hai mục thay vì dùng chung với JSON. Nếu sau này sửa `Safety.VehicleConfig.json` thì phải sửa cả file indicator. Chấp nhận được vì chỉ có 4 control.

## Kiểm thử

Chạy PX4 SITL và kết nối QGC. Đổi giá trị từ drawer trên FlyView, rồi kiểm tra trang Safety và Parameters hiển thị cùng giá trị (và ngược lại).
