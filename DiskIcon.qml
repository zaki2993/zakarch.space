import QtQuick
import QtQuick.Shapes

// Bar glyph: a ring gauge of used disk space around a platter dot.
Item {
  id: root

  property real used: 0            // 0..1
  property color color: "#888888"

  readonly property real s: width / 16

  Shape {
    anchors.fill: parent
    opacity: 0.25
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.color
      strokeWidth: 1.8 * root.s
      fillColor: "transparent"
      PathAngleArc { centerX: 8 * root.s; centerY: 8 * root.s; radiusX: 6.2 * root.s; radiusY: 6.2 * root.s; startAngle: 0; sweepAngle: 360 }
    }
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.color
      strokeWidth: 1.8 * root.s
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      PathAngleArc {
        centerX: 8 * root.s; centerY: 8 * root.s
        radiusX: 6.2 * root.s; radiusY: 6.2 * root.s
        startAngle: -90; sweepAngle: 360 * Math.max(0, Math.min(1, root.used))
      }
    }
  }

  Rectangle {
    x: 6.2 * root.s; y: 6.2 * root.s
    width: 3.6 * root.s; height: width
    radius: width / 2
    color: root.color
  }
}
