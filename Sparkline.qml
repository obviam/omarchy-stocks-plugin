import QtQuick
import "Model.js" as Model

// Tiny intraday price line. `values` is the raw close series; the canvas
// autoscales to its own min/max so even a flat day still reads.
Canvas {
  id: root

  property var values: []
  property color lineColor: "#888888"
  property color fillColor: "transparent"
  property bool filled: false
  property real lineThickness: 1.5

  onValuesChanged: requestPaint()
  onLineColorChanged: requestPaint()
  onFillColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()

    var pad = root.lineThickness + 1
    var pts = Model.sparklinePoints(root.values, root.width, root.height, pad)
    if (pts.length < 2) return

    if (root.filled) {
      ctx.beginPath()
      ctx.moveTo(pts[0].x, root.height)
      for (var f = 0; f < pts.length; f++) ctx.lineTo(pts[f].x, pts[f].y)
      ctx.lineTo(pts[pts.length - 1].x, root.height)
      ctx.closePath()
      ctx.fillStyle = root.fillColor
      ctx.globalAlpha = 0.15
      ctx.fill()
      ctx.globalAlpha = 1.0
    }

    ctx.beginPath()
    ctx.moveTo(pts[0].x, pts[0].y)
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
    ctx.strokeStyle = root.lineColor
    ctx.lineWidth = root.lineThickness
    ctx.lineJoin = "round"
    ctx.stroke()
  }
}
