import QtQuick
import qs.Commons

// A small history graph: one or two series of non-negative numbers, oldest
// first, drawn as lines scaled to the largest value on screen (or `ceiling`
// when it is set, e.g. 1.0 for a share).
Canvas {
  id: root

  property var series: []          // [number]
  property var series2: []         // optional second line, e.g. upload
  property real ceiling: 0         // 0 = auto-scale
  property color color: Color.accent
  property color color2: Color.foreground
  property int capacity: 60

  implicitHeight: Style.space(20)

  onSeriesChanged: requestPaint()
  onSeries2Changed: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function peak() {
    if (root.ceiling > 0) return root.ceiling
    var m = 0
    for (var i = 0; i < root.series.length; i++) m = Math.max(m, Number(root.series[i]) || 0)
    for (var j = 0; j < root.series2.length; j++) m = Math.max(m, Number(root.series2[j]) || 0)
    return m > 0 ? m : 1
  }

  function line(ctx, data, colour, fill) {
    if (!data || data.length < 2) return
    var top = root.peak()
    var step = root.width / Math.max(1, root.capacity - 1)
    var x0 = root.width - (data.length - 1) * step
    ctx.beginPath()
    for (var i = 0; i < data.length; i++) {
      var v = Math.max(0, Math.min(1, (Number(data[i]) || 0) / top))
      var x = x0 + i * step
      var y = root.height - 1 - v * (root.height - 2)
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
    }
    ctx.strokeStyle = colour
    ctx.lineWidth = 1.5
    ctx.stroke()
    if (fill) {
      ctx.lineTo(root.width, root.height)
      ctx.lineTo(x0, root.height)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(colour.r, colour.g, colour.b, 0.15)
      ctx.fill()
    }
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    // Faint baseline, so the graph's area reads as a graph before it fills up.
    ctx.strokeStyle = Qt.rgba(root.color2.r, root.color2.g, root.color2.b, 0.18)
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, root.height - 0.5)
    ctx.lineTo(root.width, root.height - 0.5)
    ctx.stroke()
    root.line(ctx, root.series, root.color, true)
    root.line(ctx, root.series2, root.color2, false)
  }
}
