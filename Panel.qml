import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Battery level over time, with what the machine was doing underneath it:
// charger, screen (on / screensaver / display off / lid closed) and sleep.
// Built like omarchy.power's pane; the strips borrow elsewhen's daylight
// strip, and charging takes its daylight yellow.
Panel {
  id: root
  moduleName: "kov.battery-history"
  ipcTarget: "kov.battery-history"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string range: {
    var v = String(setting("range", "24h"))
    return Model.rangeIndex(v) >= 0 ? v : "24h"
  }
  property var batteryLog: null
  property bool loading: false
  property real hoverFraction: -1  // 0..1 across the plot, -1 when not scrubbing

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color chargeColor: "#E5C736"
  readonly property color hibernateColor: "#7FB4E0"  // cold: powered down, RAM on disk
  readonly property color faint: Qt.darker(fg, 1.4)

  readonly property bool batteryPresent: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent)
  }
  readonly property real livePercent: {
    var d = UPower.displayDevice
    return d && d.isPresent ? Math.max(0, Math.min(1, d.percentage)) * 100 : NaN
  }
  readonly property string liveState: {
    var d = UPower.displayDevice
    if (!d || !d.isPresent) return ""
    if (d.state === UPowerDeviceState.Charging) return "charging"
    if (UPower.onBattery) return "discharging"
    return "fully-charged"
  }

  // The fetched range, and the window of it on screen. Scrolling over the
  // plot zooms the window; zoomSpan 0 shows everything, zoomEnd -1 keeps
  // the window's right edge on "now" so a refresh slides it along.
  readonly property real dataStart: batteryLog ? batteryLog.start : 0
  readonly property real dataEnd: batteryLog ? batteryLog.now : 1
  readonly property real minZoomSpan: 1800
  property real zoomSpan: 0
  property real zoomEnd: -1
  readonly property bool zoomed: zoomSpan > 0
  readonly property real t1: zoomed && zoomEnd >= 0 ? Math.min(zoomEnd, dataEnd) : dataEnd
  readonly property real t0: zoomed ? Math.max(dataStart, t1 - zoomSpan) : dataStart

  function resetZoom() { root.zoomSpan = 0; root.zoomEnd = -1 }

  function zoomAt(anchor, factor, pan) {
    if (!root.batteryLog) return
    var v = Model.zoomView(root.t0, root.t1, root.dataStart, root.dataEnd, anchor, factor, pan, root.minZoomSpan)
    if (v.end - v.start >= root.dataEnd - root.dataStart - 1) { root.resetZoom(); return }
    root.zoomSpan = v.end - v.start
    root.zoomEnd = v.end >= root.dataEnd - 1 ? -1 : v.end
  }
  readonly property var samples: batteryLog ? Model.withLivePoint(batteryLog.samples, batteryLog.now, livePercent, liveState) : []
  readonly property var screenSegs: batteryLog ? batteryLog.screen : []
  readonly property var powerSegs: batteryLog ? batteryLog.power : []

  // Power draw overlay: UPower's rate history, on battery only (on the
  // charger the rate is what goes into the battery, not what the laptop
  // uses). Toggled by the Power chip; setting "showPower".
  readonly property bool showPower: setting("showPower", false) === true
  readonly property color powerColor: "#E0694A"
  readonly property var rates: batteryLog && Array.isArray(batteryLog.rate) ? batteryLog.rate : []
  readonly property real rateGap: Model.rateGap(batteryLog ? batteryLog.rateBucket : 60)
  readonly property real powerMax: Model.rateScale(rates, t0, t1)
  readonly property real shownWatts: hoverTime < 0 ? NaN : Model.rateAt(rates, hoverTime, rateGap)
  readonly property var avgDraw: Model.averageRate(rates, t0, t1)

  function watts(v) {
    return (v === null || v === undefined || isNaN(v)) ? "—" : strings.t("watts").arg(Commons.I18n.formatNumber(v, 1))
  }

  function setShowPower(on) {
    root.settings = Object.assign({}, root.settings, { showPower: on })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }
  // Stats for the window on screen, so they follow the zoom. Raw samples,
  // without the live point, so the full range matches the collector's.
  readonly property var stats: batteryLog
    ? Model.windowStats(batteryLog.samples, batteryLog.screen, batteryLog.power, t0, t1)
    : ({})

  readonly property real hoverTime: hoverFraction < 0 ? -1 : t0 + hoverFraction * (t1 - t0)
  readonly property real shownPercent: hoverTime < 0 ? livePercent : Model.valueAt(samples, hoverTime)

  readonly property string collectorPath: decodeURIComponent(Qt.resolvedUrl("collect.py").toString().replace(/^file:\/\//, ""))

  function tr(key) { return strings.t(key) }
  function pct(v) { return isNaN(v) ? "—" : Commons.I18n.formatNumber(Math.round(v)) + "%" }
  function rate(v) { return (v === null || v === undefined) ? "—" : strings.t("perHour").arg(Commons.I18n.formatNumber(v, 1)) }
  function locale() { return Qt.locale(Commons.I18n.formatLocale) }
  function fmt(t, f) { return new Date(t * 1000).toLocaleString(root.locale(), f) }

  function setRange(value) {
    if (value === root.range) return
    root.resetZoom()
    root.settings = Object.assign({}, root.settings, { range: value })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    Qt.callLater(root.refresh)
  }

  function refresh() {
    if (collector.running) { collector.pending = true; return }
    root.loading = true
    collector.command = ["python3", "-I", root.collectorPath, String(Model.rangeSeconds(root.range))]
    collector.running = true
  }

  function ingest(text) {
    root.loading = false
    try {
      var parsed = JSON.parse(text)
      if (parsed && Array.isArray(parsed.samples) && Array.isArray(parsed.screen)) root.batteryLog = parsed
    } catch (e) {
      console.warn("kov.battery-history: bad collector output")
    }
    if (collector.pending) { collector.pending = false; Qt.callLater(root.refresh) }
  }

  readonly property string statusText: {
    if (hoverTime >= 0) {
      var parts = [fmt(hoverTime, "ddd HH:mm")]
      var s = Model.segmentAt(screenSegs, hoverTime)
      if (s) parts.push(tr("screen." + s))
      var p = Model.segmentAt(powerSegs, hoverTime)
      if (p && s !== "off" && s !== "hibernate") parts.push(tr("power." + p))
      if (showPower && !isNaN(shownWatts)) parts.push(watts(shownWatts))
      return parts.join(" · ")
    }
    if (!batteryLog) return loading ? tr("loading") : tr("noData")
    if (zoomed) {
      var sameDay = new Date(t0 * 1000).toDateString() === new Date(t1 * 1000).toDateString()
      return fmt(t0, "ddd HH:mm") + " – " + fmt(t1, sameDay ? "HH:mm" : "ddd HH:mm")
    }
    return strings.t("summary").arg(tr("range." + range)).arg(Model.formatDuration(stats.screenOn))
  }

  onOpenedChanged: if (opened) { resetZoom(); refresh(); readSleep() }
  Timer { interval: 60000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // ---------- Sleep settings ----------
  // Screensaver/lock live in shell.json (idle.screensaver, idle.lock, seconds,
  // 0 = off) and are written through the shell, like the bar's own edits.
  // The hibernate delay is a system file, written through pkexec so the
  // polkit agent asks for the password.
  readonly property var screensaverPresets: [0, 60, 150, 300, 600]
  readonly property var lockPresets: [0, 300, 600, 900, 1800]
  readonly property var hibernatePresets: [1800, 3600, 7200, 14400, 28800]
  readonly property string hibernateDropIn: "/etc/systemd/sleep.conf.d/30-hibernate-delay.conf"
  property int screensaverSecs: 150
  property int lockSecs: 300
  property var hibernateDelaySecs: null  // null = unset (battery-based), -1 = unreadable
  property string lidAction: ""
  property string lidActionAc: ""
  property bool hibernateOnAc: true
  property bool hibernateSaving: false
  property string sleepError: ""

  FileView {
    id: idleFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.readIdle(text())
  }

  function readIdle(raw) {
    try {
      var cfg = JSON.parse(raw)
      var idle = cfg && cfg.idle && typeof cfg.idle === "object" ? cfg.idle : {}
      // A pick still being written wins over the file until it lands.
      if (!("screensaver" in root.pendingIdle)) root.screensaverSecs = Model.idleSeconds(idle.screensaver, 150)
      if (!("lock" in root.pendingIdle)) root.lockSecs = Model.idleSeconds(idle.lock, 300)
    } catch (e) {
      // Mid-write or hand-edited into invalid JSON: keep what is shown.
    }
  }

  // The shell's mutateShellConfig only lets a bar plugin edit `bar` (the
  // rest of the copy it hands over is thrown away), so idle goes through
  // set-idle.py, which edits shell.json directly. Picks made while a write
  // is running are queued and sent together after it.
  readonly property string idleWriterPath: decodeURIComponent(Qt.resolvedUrl("set-idle.py").toString().replace(/^file:\/\//, ""))
  property var pendingIdle: ({})

  function setIdle(key, secs) {
    var n = Number(secs)
    if (!(n >= 0) || Math.floor(n) !== n || (key !== "screensaver" && key !== "lock")) return
    var next = Object.assign({}, root.pendingIdle)
    next[key] = n
    root.pendingIdle = next
    if (key === "screensaver") root.screensaverSecs = n
    else root.lockSecs = n
    root.idleError = ""
    root.flushIdle()
  }

  function flushIdle() {
    if (idleWriter.running) return
    var args = []
    for (var k in root.pendingIdle) args.push(k + "=" + root.pendingIdle[k])
    if (args.length === 0) return
    root.pendingIdle = ({})
    idleWriter.command = ["python3", "-I", root.idleWriterPath].concat(args)
    idleWriter.running = true
  }

  property string idleError: ""

  Process {
    id: idleWriter
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) console.warn("kov.battery-history: set-idle: " + text.trim()) }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.idleError = strings.t("sleep.idleSaveFailed")
        idleFile.reload()  // show what is really saved
      }
      root.flushIdle()
    }
  }

  function readSleep() {
    if (!sleepReader.running) sleepReader.running = true
  }

  function ingestSleep(text) {
    var parts = String(text || "").split("--\n")
    root.hibernateDelaySecs = Model.parseSpan(parts[0])
    var props = (parts[1] || "").match(/"([^"]*)"/g) || []
    root.lidAction = props.length > 0 ? props[0].replace(/"/g, "") : ""
    root.lidActionAc = props.length > 1 ? props[1].replace(/"/g, "") : ""
    // systemd's default is yes; only an explicit false-ish value turns it off.
    root.hibernateOnAc = !/^(no|false|0|off)$/i.test(String(parts[2] || "").trim())
  }

  function setHibernateDelay(secs) {
    var n = Number(secs)
    if (root.hibernatePresets.indexOf(n) < 0 && n !== root.hibernateDelaySecs) return
    var value = Model.spanValue(n)
    if (!/^[0-9]+(min|h)$/.test(value) || sleepWriter.running) return
    root.sleepError = ""
    root.hibernateSaving = true
    sleepWriter.command = ["pkexec", "/usr/bin/sh", "-c",
      "set -e; mkdir -p /etc/systemd/sleep.conf.d; printf '[Sleep]\\nHibernateDelaySec=%s\\n' \"$1\" > " + root.hibernateDropIn,
      "sh", value]
    sleepWriter.running = true
  }

  readonly property string lidStatus: {
    if (root.lidAction === "suspend-then-hibernate") {
      var line = root.hibernateDelaySecs === null
        ? strings.t("sleep.lidLowBattery")
        : strings.t("sleep.lidAfter").arg(Model.formatDuration(root.hibernateDelaySecs))
      if (root.lidActionAc === "suspend") line += " " + strings.t("sleep.lidAcSleeps")
      else if (root.lidActionAc === "suspend-then-hibernate" && !root.hibernateOnAc)
        line += " " + strings.t("sleep.lidAcWaits")
      return line
    }
    if (root.lidAction) return strings.t("sleep.lidOther").arg(root.lidAction)
    return ""
  }

  Process {
    id: sleepReader
    command: ["sh", "-c",
      "systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | sed -n 's/^HibernateDelaySec=//p' | tail -n1; echo '--'; " +
      "busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch HandleLidSwitchExternalPower 2>/dev/null; echo '--'; " +
      "systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | sed -n 's/^HibernateOnACPower=//p' | tail -n1"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.ingestSleep(text) }
  }

  Process {
    id: sleepWriter
    onExited: function(exitCode, exitStatus) {
      root.hibernateSaving = false
      // 126/127: the password dialog was dismissed or failed.
      if (exitCode !== 0) root.sleepError = exitCode === 126 || exitCode === 127
        ? strings.t("sleep.cancelled") : strings.t("sleep.saveFailed")
      root.readSleep()
    }
  }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: collector
    property bool pending: false
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.ingest(text) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄧"
    tooltipText: root.tr("title")
    onPressed: function(b) { if (root.batteryPresent) root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.setRange(Model.shiftRange(root.range, dx)) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰄧"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.tr("title")
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText.toUpperCase()
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.pct(root.shownPercent)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Range, and the power overlay toggle ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(rangeGroup.implicitHeight, powerToggle.implicitHeight)

          ButtonGroup {
            id: rangeGroup
            spacing: Style.space(6)
            focusable: false
            options: Model.RANGES.map(function(r) { return { value: r.value, label: strings.t("chip." + r.value) } })
            value: root.range
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.setRange(v) }
          }

          Button {
            id: powerToggle
            anchors.right: parent.right
            text: root.tr("chip.power")
            tooltipText: root.tr("chip.powerTip")
            selected: root.showPower
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.setShowPower(!root.showPower)
          }
        }

        // ---------- Plot: chart, strips, time axis ----------
        Item {
          id: plot
          width: parent.width
          readonly property real gutter: Style.space(52)
          // Room for the watt axis on the right while the overlay is on.
          readonly property real rightGutter: root.showPower ? Style.space(40) : 0
          readonly property real plotX: gutter
          readonly property real plotW: width - gutter - rightGutter
          readonly property real chartH: Style.space(128)
          readonly property real laneH: Math.max(4, Style.space(6))
          readonly property real laneGap: Style.space(12)
          readonly property real lanesTop: chartH + Style.space(14)
          readonly property real axisTop: lanesTop + 3 * laneH + 2 * laneGap + Style.space(8)
          implicitHeight: axisTop + Style.font.caption + Style.space(4)

          function xFor(t) { return plotX + plotW * (t - root.t0) / Math.max(1, root.t1 - root.t0) }

          // Y labels
          Repeater {
            model: [100, 50, 0]
            Text {
              required property var modelData
              textFormat: Text.PlainText
              text: Commons.I18n.formatNumber(modelData) + "%"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.left
              anchors.rightMargin: -plot.gutter + Style.space(10)
              y: chart.yFor(modelData) - height / 2
            }
          }

          // Watt labels on the right, in the overlay's colour
          Repeater {
            model: root.showPower ? [1, 0.5, 0] : []
            Text {
              required property var modelData
              textFormat: Text.PlainText
              text: root.watts(root.powerMax * modelData).replace(/\.0(?=\D*$)/, "")
              color: root.powerColor
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              x: plot.plotX + plot.plotW + Style.space(6)
              y: chart.yFor(modelData * 100) - height / 2
            }
          }

          Canvas {
            id: chart
            x: plot.plotX
            width: plot.plotW
            height: plot.chartH
            antialiasing: true

            readonly property real pad: Style.space(4)
            function yFor(p) { return pad + (1 - p / 100) * (height - 2 * pad) }
            function yForW(w) { return yFor(100 * Math.min(1, w / Math.max(1, root.powerMax))) }
            function xFor(t) { return width * (t - root.t0) / Math.max(1, root.t1 - root.t0) }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height
              var fg = String(root.fg)

              // Guides at 0 / 25 / 50 / 75 / 100
              ctx.strokeStyle = fg
              ctx.lineWidth = 1
              for (var g = 0; g <= 100; g += 25) {
                ctx.globalAlpha = g % 50 === 0 ? 0.10 : 0.05
                var gy = Math.round(yFor(g)) + 0.5
                ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
              }

              // Asleep / off shading behind the line
              var segs = root.screenSegs || []
              var hib = String(root.hibernateColor)
              for (var i = 0; i < segs.length; i++) {
                var c = segs[i][2]
                if (c !== "sleep" && c !== "off" && c !== "hibernate") continue
                ctx.fillStyle = c === "hibernate" ? hib : fg
                ctx.globalAlpha = c === "off" ? 0.07 : c === "hibernate" ? 0.10 : 0.04
                var sx = xFor(segs[i][0]), ex = xFor(segs[i][1])
                ctx.fillRect(sx, pad, Math.max(1, ex - sx), h - 2 * pad)
              }

              var s = root.samples
              if (!s || s.length === 0) return

              // Only the samples in view, plus one either side; points past
              // the edges fall off the canvas, which clips the segments
              // that cross them.
              var vis = Model.visibleRange(s, root.t0, root.t1)
              function px(k) { return xFor(s[k][0]) }
              function py(k) { return yFor(s[k][1]) }

              // Area under the line
              ctx.globalAlpha = 0.10
              ctx.fillStyle = fg
              ctx.beginPath()
              ctx.moveTo(px(vis.lo), h - pad)
              for (var k = vis.lo; k <= vis.hi; k++) ctx.lineTo(px(k), py(k))
              ctx.lineTo(px(vis.hi), h - pad)
              ctx.closePath()
              ctx.fill()

              // The line, yellow while charging
              ctx.globalAlpha = 1
              ctx.lineWidth = Math.max(1.5, Style.space(2))
              ctx.lineJoin = "round"
              ctx.lineCap = "round"
              var charge = String(root.chargeColor)
              var current = null
              for (var j = vis.lo + 1; j <= vis.hi; j++) {
                var col = s[j - 1][2] === "charging" ? charge : fg
                if (col !== current) {
                  if (current !== null) ctx.stroke()
                  ctx.strokeStyle = col
                  ctx.beginPath()
                  ctx.moveTo(px(j - 1), py(j - 1))
                  current = col
                }
                ctx.lineTo(px(j), py(j))
              }
              if (current !== null) ctx.stroke()

              // Power draw on its own watt scale, broken across gaps
              // (charging, asleep, off), over the battery line.
              var r = root.rates
              if (!root.showPower || !r || r.length === 0) return
              var rv = Model.visibleRange(r, root.t0, root.t1)
              ctx.globalAlpha = 0.9
              ctx.strokeStyle = String(root.powerColor)
              ctx.lineWidth = Math.max(1, Style.space(1.5))
              ctx.beginPath()
              for (var q = rv.lo; q <= rv.hi; q++) {
                var rx = xFor(r[q][0]), ry = yForW(r[q][1])
                if (q === rv.lo || r[q][0] - r[q - 1][0] > root.rateGap) {
                  // A lone point still shows as a short tick.
                  ctx.moveTo(rx - 1, ry)
                }
                ctx.lineTo(rx, ry)
              }
              ctx.stroke()
            }

            Connections {
              target: root
              function onShowPowerChanged() { chart.requestPaint() }
              function onRatesChanged() { chart.requestPaint() }
              function onPowerMaxChanged() { chart.requestPaint() }
              function onSamplesChanged() { chart.requestPaint() }
              function onScreenSegsChanged() { chart.requestPaint() }
              function onFgChanged() { chart.requestPaint() }
              function onHibernateColorChanged() { chart.requestPaint() }
              function onT0Changed() { chart.requestPaint() }
              function onT1Changed() { chart.requestPaint() }
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
          }

          // Strips
          Lane {
            width: plot.width
            gutter: plot.gutter
            trackWidth: plot.plotW
            y: plot.lanesTop
            label: root.tr("lane.screen")
            segments: root.screenSegs
            colorFor: function(c) {
              if (c === "on") return Util.alpha(root.fg, 0.85)
              if (c === "idle") return Util.alpha(root.fg, 0.45)
              if (c === "dark") return Util.alpha(root.fg, 0.22)
              return "transparent"
            }
          }
          Lane {
            width: plot.width
            gutter: plot.gutter
            trackWidth: plot.plotW
            y: plot.lanesTop + plot.laneH + plot.laneGap
            label: root.tr("lane.charger")
            segments: root.powerSegs
            colorFor: function(c) {
              if (c === "charging") return root.chargeColor
              if (c === "plugged") return Util.alpha(root.chargeColor, 0.45)
              return "transparent"
            }
          }
          Lane {
            width: plot.width
            gutter: plot.gutter
            trackWidth: plot.plotW
            y: plot.lanesTop + 2 * (plot.laneH + plot.laneGap)
            label: root.tr("lane.sleep")
            segments: root.screenSegs
            colorFor: function(c) {
              if (c === "sleep") return Util.alpha(root.fg, 0.5)
              if (c === "hibernate") return root.hibernateColor
              if (c === "off") return Util.alpha(root.fg, 0.18)
              return "transparent"
            }
          }

          // Time axis
          Repeater {
            model: root.batteryLog ? Model.ticks(root.t0, root.t1) : []
            Item {
              required property var modelData
              x: plot.xFor(modelData.t)
              Rectangle {
                x: 0
                y: 0
                width: 1
                height: plot.chartH
                color: root.fg
                opacity: modelData.kind === "day" ? 0.10 : 0.04
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.kind === "day" ? root.fmt(modelData.t, "ddd") : root.fmt(modelData.t, "HH:mm")
                color: modelData.kind === "day" ? root.fg : root.faint
                opacity: modelData.kind === "day" ? 0.8 : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: modelData.kind === "day"
                y: plot.axisTop
                x: Math.max(-plot.xFor(modelData.t) + plot.plotX, Math.min(-width / 2, plot.width - plot.xFor(modelData.t) - width))
              }
            }
          }

          // Scrub readout
          Rectangle {
            visible: root.hoverFraction >= 0
            x: Math.round(plot.plotX + plot.plotW * Math.max(0, root.hoverFraction))
            y: 0
            width: 1
            height: plot.axisTop - Style.space(4)
            color: root.fg
            opacity: 0.45
          }
          Rectangle {
            visible: root.hoverFraction >= 0 && !isNaN(root.shownPercent)
            width: Math.max(7, Style.space(8))
            height: width
            radius: width / 2
            color: Model.segmentAt(root.powerSegs, root.hoverTime) === "charging" ? root.chargeColor : root.fg
            x: Math.round(plot.plotX + plot.plotW * Math.max(0, root.hoverFraction) - width / 2)
            y: chart.yFor(isNaN(root.shownPercent) ? 0 : root.shownPercent) - height / 2
          }
          Rectangle {
            visible: root.showPower && root.hoverFraction >= 0 && !isNaN(root.shownWatts)
            width: Math.max(6, Style.space(7))
            height: width
            radius: width / 2
            color: root.powerColor
            x: Math.round(plot.plotX + plot.plotW * Math.max(0, root.hoverFraction) - width / 2)
            y: chart.yForW(isNaN(root.shownWatts) ? 0 : root.shownWatts) - height / 2
          }

          MouseArea {
            x: plot.plotX
            width: plot.plotW
            height: plot.axisTop
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.CrossCursor
            function track(mx) { root.hoverFraction = Math.max(0, Math.min(1, mx / width)) }
            onPositionChanged: function(m) { track(m.x) }
            onPressed: function(m) { track(m.x) }
            onExited: root.hoverFraction = -1
            onContainsMouseChanged: if (!containsMouse && !pressed) root.hoverFraction = -1
            // Scroll up zooms in on the time under the cursor, down zooms
            // out; sideways scroll pans. Double-click shows the whole range.
            onWheel: function(w) {
              w.accepted = true
              var anchor = Math.max(0, Math.min(1, w.x / width))
              var dy = w.angleDelta.y / 120, dx = w.angleDelta.x / 120
              if (dy !== 0) root.zoomAt(anchor, Math.pow(0.8, dy), 0)
              else if (dx !== 0 && root.zoomed) root.zoomAt(anchor, 1, -dx * 0.1)
              track(w.x)
            }
            onDoubleClicked: root.resetZoom()
          }
        }

        // ---------- Legend ----------
        Flow {
          width: parent.width
          spacing: Style.space(12)
          LegendDot { swatch: Util.alpha(root.fg, 0.85); text: root.tr("legend.on") }
          LegendDot { swatch: Util.alpha(root.fg, 0.45); text: root.tr("legend.idle") }
          LegendDot { swatch: Util.alpha(root.fg, 0.22); text: root.tr("legend.dark") }
          LegendDot { swatch: root.chargeColor; text: root.tr("legend.charging") }
          LegendDot { swatch: Util.alpha(root.fg, 0.5); text: root.tr("legend.sleep") }
          LegendDot { swatch: root.hibernateColor; text: root.tr("legend.hibernate") }
          LegendDot { visible: root.showPower; swatch: root.powerColor; text: root.tr("legend.power") }
        }

        // ---------- Stats ----------
        PanelSeparator { foreground: root.fg }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.batteryLog !== null

          PanelSectionHeader {
            text: root.tr("stats.header")
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(20)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: root.tr("stats.screenOn"); value: Model.formatDuration(root.stats.screenOn) }
              InfoPair { label: root.tr("stats.asleep"); value: Model.formatDuration(root.stats.asleep) }
              InfoPair { label: root.tr("stats.hibernated"); value: Model.formatDuration(root.stats.hibernated) }
              InfoPair { label: root.tr("stats.charging"); value: Model.formatDuration(root.stats.charging) }
              InfoPair { label: root.tr("stats.used"); value: root.pct(root.stats.used) }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: root.tr("stats.drainOn"); value: root.rate(root.stats.drainScreenOn) }
              InfoPair { label: root.tr("stats.drainSleep"); value: root.rate(root.stats.drainAsleep) }
              InfoPair { label: root.tr("stats.lid"); value: Model.formatDuration(root.stats.lidClosed) }
              InfoPair { label: root.tr("stats.avgDraw"); value: root.watts(root.avgDraw) }
              InfoPair {
                label: root.tr("stats.runtime")
                value: root.stats.drainScreenOn ? Model.formatDuration(100 / root.stats.drainScreenOn * 3600) : "—"
              }
            }
          }
        }

        // ---------- Sleep settings ----------
        PanelSeparator { foreground: root.fg }

        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.tr("sleep.header")
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          SettingRow {
            label: root.tr("sleep.screensaver")
            options: Model.chipOptions(root.screensaverPresets, root.screensaverSecs, root.tr("sleep.off"))
            value: String(root.screensaverSecs)
            onPicked: function(v) { root.setIdle("screensaver", v) }
          }

          SettingRow {
            label: root.tr("sleep.lock")
            options: Model.chipOptions(root.lockPresets, root.lockSecs, root.tr("sleep.off"))
            value: String(root.lockSecs)
            onPicked: function(v) { root.setIdle("lock", v) }
          }

          SettingRow {
            label: root.tr("sleep.hibernate")
            options: Model.chipOptions(root.hibernatePresets,
                                       typeof root.hibernateDelaySecs === "number" ? root.hibernateDelaySecs : -1,
                                       root.tr("sleep.off"))
            value: root.hibernateDelaySecs === null ? "" : String(root.hibernateDelaySecs)
            enabled: !root.hibernateSaving
            opacity: enabled ? 1 : 0.5
            onPicked: function(v) { root.setHibernateDelay(v) }
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: root.idleError !== "" ? root.idleError : root.sleepError !== "" ? root.sleepError : root.lidStatus
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component SettingRow: Row {
    id: setting
    property string label: ""
    property var options: []
    property string value: ""
    signal picked(string value)

    width: parent.width
    spacing: Style.space(8)

    Text {
      width: Style.space(118)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: setting.label
      color: root.fg
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    ButtonGroup {
      spacing: Style.space(4)
      focusable: false
      options: setting.options
      value: setting.value
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onChanged: function(v) { if (setting.enabled) setting.picked(v) }
    }
  }

  // A thin rounded strip, like elsewhen's daylight strip, lit where the
  // timeline's category maps to a colour.
  component Lane: Item {
    id: lane
    property string label: ""
    property var segments: []
    property var colorFor: function(c) { return "transparent" }
    property real gutter: 0
    property real trackWidth: 0

    height: Math.max(4, Style.space(6))

    Text {
      textFormat: Text.PlainText
      text: lane.label
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
      x: 0
      width: lane.gutter - Style.space(10)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }

    Rectangle {
      id: track
      x: lane.gutter
      width: lane.trackWidth
      height: parent.height
      radius: height / 2
      color: Util.alpha(root.fg, 0.08)
      clip: true

      // Square-ended runs inside the rounded track, so back-to-back states
      // read as one strip rather than a string of beads. Runs under a pixel
      // wide (a few seconds of screensaver at the 7-day scale) are dropped.
      Repeater {
        model: lane.segments
        Rectangle {
          required property var modelData
          readonly property color fill: lane.colorFor(modelData[2])
          readonly property real x0: track.width * (modelData[0] - root.t0) / Math.max(1, root.t1 - root.t0)
          readonly property real x1: track.width * (modelData[1] - root.t0) / Math.max(1, root.t1 - root.t0)
          visible: fill.a > 0 && x1 - x0 >= 1 && x1 > 0 && x0 < track.width
          x: Math.max(0, x0)
          width: Math.min(track.width, x1) - x
          height: track.height
          // Only the ends of the track are rounded.
          radius: (x0 <= 0 || x1 >= track.width) ? height / 2 : 0
          color: fill
        }
      }
    }
  }

  component LegendDot: Row {
    property color swatch: root.fg
    property string text: ""
    spacing: Style.space(5)
    Rectangle {
      width: Math.max(6, Style.space(7))
      height: width
      radius: width / 2
      color: parent.swatch
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      text: parent.text
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
