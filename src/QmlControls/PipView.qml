import QtQuick
import QtQuick.Window
import QtQuick.Effects

import QGroundControl
import QGroundControl.Controls

// Circular PIP (product request): same diameter formula as the compass's dial
// (IntegratedCompassAttitude.qml's compassRadius*2), so the two read as a matched pair. Video/map
// content is an ordinary rectangular Item with no "radius" concept of its own, and clip:true only
// ever clips to an item's rectangular bounds (never to Rectangle.radius) - so genuine circular
// clipping needs a pixel mask, not just anchoring/clip tricks. Reuses the exact MultiEffect +
// hidden-mask-Item pattern QGCAttitudeWidget.qml already uses for the compass dial itself.
Item {
    id:         _root
    width:      _pipSize
    height:     _pipSize
    visible:    item2 && item2.pipState !== item2.pipState.window && show

    property var    item1:                  null    // Required
    property var    item2:                  null    // Optional, may come and go
    property string item1IsFullSettingsKey          // Settings key to save whether item1 was saved in full mode
    property bool   show:                   true

    readonly property string _pipExpandedSettingsKey: "IsPIPVisible"

    property var    _fullItem
    property var    _pipOrWindowItem
    property alias  _windowContentItem: window.contentItem
    property alias  _pipContentItem:    pipContent
    property bool   _isExpanded:        true
    property real   _pipSize:           Math.min(parent.width * 0.15, ScreenTools.defaultFontPixelHeight * 7)
    property real   _maxSize:           0.75                // Percentage of parent control size
    property real   _minSize:           0.10
    property bool   _componentComplete: false
    // Now that _root is a circle, the corner-anchored utility icons below need to sit inset from
    // the literal corner (otherwise they'd float outside the visible circle, in the masked-away
    // area) - roughly the gap between a square's corner and its inscribed circle.
    readonly property real _cornerInset: _root.width * 0.15

    QGCPalette { id: qgcPal }

    Component.onCompleted: {
        _initForItems()
        _componentComplete = true
    }

    onItem2Changed: _initForItems()

    function showWindow() {
        window.width = _root.width
        window.height = _root.height
        window.show()
    }

    function _initForItems() {
        var item1IsFull = QGroundControl.loadBoolGlobalSetting(item1IsFullSettingsKey, true)
        if (item1 && item2) {
            item1.pipState.state = item1IsFull ? item1.pipState.fullState : item1.pipState.pipState
            item2.pipState.state = item1IsFull ? item2.pipState.pipState : item2.pipState.fullState
            _fullItem = item1IsFull ? item1 : item2
            _pipOrWindowItem = item1IsFull ? item2 : item1
        } else {
            item1.pipState.state = item1.pipState.fullState
            _fullItem = item1
            _pipOrWindowItem = null
        }
        _setPipIsExpanded(QGroundControl.loadBoolGlobalSetting(_pipExpandedSettingsKey, true))
    }

    function _swapPip() {
        var item1IsFull = false
        if (item1.pipState.state === item1.pipState.fullState) {
            item1.pipState.state = item1.pipState.pipState
            item2.pipState.state = item2.pipState.fullState
            _fullItem = item2
            _pipOrWindowItem = item1
            item1IsFull = false
        } else {
            item1.pipState.state = item1.pipState.fullState
            item2.pipState.state = item2.pipState.pipState
            _fullItem = item1
            _pipOrWindowItem = item2
            item1IsFull = true
        }
        QGroundControl.saveBoolGlobalSetting(item1IsFullSettingsKey, item1IsFull)
    }

    function _setPipIsExpanded(isExpanded) {
        QGroundControl.saveBoolGlobalSetting(_pipExpandedSettingsKey, isExpanded)
        _isExpanded = isExpanded
    }

    Window {
        id:         window
        visible:    false
        onClosing: {
            var item = contentItem.children[0]
            if (item) {
                item.pipState.windowAboutToClose()
                item.pipState.state = item.pipState.pipState
            }
        }
    }

    // Holds the actual reparented map/video content (see PipState.qml's pipState:
    // ParentChange { target: _viewControl; parent: pipView._pipContentItem }). Always hidden now
    // - it exists purely as an offscreen source for the circular mask below, which is what's
    // actually visible. Qt Quick still renders (and reparenting/anchoring still works) for a
    // hidden item as long as something is consuming its texture, same as instrument.visible:
    // false in QGCAttitudeWidget.qml.
    Item {
        id:             pipContent
        anchors.fill:   parent
        visible:        false
        clip:           true
    }

    MultiEffect {
        id:           pipMasked
        source:       pipContent
        anchors.fill: pipContent
        visible:      _isExpanded
        maskEnabled:  true
        maskSource:   pipMask
    }

    Item {
        id:      pipMask
        width:   pipContent.width
        height:  pipContent.height
        layer.enabled: true
        visible: false

        Rectangle {
            width:  parent.width
            height: parent.height
            radius: width / 2
            color:  "black"
        }
    }

    // Thin circular border so the PIP still reads as a deliberate round element (matches the
    // compass dial's own border) rather than looking like a clipping artifact
    Rectangle {
        anchors.fill: pipContent
        visible:      _isExpanded
        radius:       width / 2
        color:        "transparent"
        border.color: qgcPal.text
        border.width: 1
    }

    MouseArea {
        id:             pipMouseArea
        anchors.fill:   parent
        enabled:        _isExpanded
        preventStealing: true
        hoverEnabled:   true
        onClicked:      _swapPip()
    }

    // MouseArea to drag in order to resize the PiP area
    MouseArea {
        id:                 pipResize
        anchors.fill:       pipResizeIcon
        preventStealing:    true
        cursorShape:        Qt.PointingHandCursor

        property real initialX:     0
        property real initialWidth: 0

        onPressed: (mouse) => {
            // Remove the anchor so the our mouse coordinates stay in the same original place for drag tracking
            pipResize.anchors.fill = undefined
            pipResize.initialX = mouse.x
            pipResize.initialWidth = _root.width
        }

        onReleased: pipResize.anchors.fill = pipResizeIcon

        // Drag
        onPositionChanged: (mouse) => {
            if (pipResize.pressed) {
                var parentWidth = _root.parent.width
                var newWidth = pipResize.initialWidth + mouse.x - pipResize.initialX
                if (newWidth < parentWidth * _maxSize && newWidth > parentWidth * _minSize) {
                    _pipSize = newWidth
                }
            }
        }
    }

    // Resize icon
    Image {
        id:             pipResizeIcon
        source:         "/qmlimages/pipResize.svg"
        fillMode:       Image.PreserveAspectFit
        mipmap:         true
        anchors.right:  parent.right
        anchors.top:    parent.top
        anchors.rightMargin: _cornerInset
        anchors.topMargin:   _cornerInset
        visible:        _isExpanded && (ScreenTools.isMobile || pipMouseArea.containsMouse)
        height:         ScreenTools.defaultFontPixelHeight * 2.5
        width:          ScreenTools.defaultFontPixelHeight * 2.5
        sourceSize.height:  height
    }

    // Check min/max constraints on pip size when when parent is resized
    Connections {
        target: _root.parent

        function onWidthChanged() {
            if (!_componentComplete) {
                // Wait until first time setup is done
                return
            }
            var parentWidth = _root.parent.width
            if (_root.width > parentWidth * _maxSize) {
                _pipSize = parentWidth * _maxSize
            } else if (_root.width < parentWidth * _minSize) {
                _pipSize = parentWidth * _minSize
            }
        }
    }

    // Pip to Window
    Image {
        id:             popupPIP
        source:         "/qmlimages/PiP.svg"
        mipmap:         true
        fillMode:       Image.PreserveAspectFit
        anchors.left:   parent.left
        anchors.top:    parent.top
        anchors.leftMargin: _cornerInset
        anchors.topMargin:  _cornerInset
        visible:        _isExpanded && !ScreenTools.isMobile && pipMouseArea.containsMouse
        height:         ScreenTools.defaultFontPixelHeight * 2.5
        width:          ScreenTools.defaultFontPixelHeight * 2.5
        sourceSize.height:  height

        MouseArea {
            anchors.fill:   parent
            onClicked:      _pipOrWindowItem.pipState.state = _pipOrWindowItem.pipState.windowState
        }
    }

    Image {
        id:             hidePIP
        source:         "/qmlimages/pipHide.svg"
        mipmap:         true
        fillMode:       Image.PreserveAspectFit
        anchors.left:   parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin:   _cornerInset
        anchors.bottomMargin: _cornerInset
        visible:        _isExpanded && (ScreenTools.isMobile || pipMouseArea.containsMouse)
        height:         ScreenTools.defaultFontPixelHeight * 2.5
        width:          ScreenTools.defaultFontPixelHeight * 2.5
        sourceSize.height:  height
        MouseArea {
            anchors.fill:   parent
            onClicked:      _root._setPipIsExpanded(false)
        }
    }

    Rectangle {
        id:                     showPip
        anchors.left :          parent.left
        anchors.bottom:         parent.bottom
        height:                 ScreenTools.defaultFontPixelHeight * 2
        width:                  ScreenTools.defaultFontPixelHeight * 2
        radius:                 ScreenTools.defaultFontPixelHeight / 3
        visible:                !_isExpanded
        color:                  _fullItem.pipState.isDark ? Qt.rgba(0,0,0,0.75) : Qt.rgba(0,0,0,0.5)
        Image {
            width:              parent.width  * 0.75
            height:             parent.height * 0.75
            sourceSize.height:  height
            source:             "/res/buttonRight.svg"
            mipmap:             true
            fillMode:           Image.PreserveAspectFit
            anchors.verticalCenter:     parent.verticalCenter
            anchors.horizontalCenter:   parent.horizontalCenter
        }
        MouseArea {
            anchors.fill:   parent
            onClicked:      _root._setPipIsExpanded(true)
        }
    }
}
