// Pure helpers for the battery history panel. No QML imports, so they can
// be exercised with plain node.

var RANGES = [
  { value: "6h", seconds: 6 * 3600 },
  { value: "12h", seconds: 12 * 3600 },
  { value: "24h", seconds: 24 * 3600 },
  { value: "3d", seconds: 3 * 86400 },
  { value: "7d", seconds: 7 * 86400 }
]

function rangeSeconds(value) {
  for (var i = 0; i < RANGES.length; i++)
    if (RANGES[i].value === value) return RANGES[i].seconds
  return 86400
}

function rangeIndex(value) {
  for (var i = 0; i < RANGES.length; i++)
    if (RANGES[i].value === value) return i
  return value === "24h" ? -1 : rangeIndex("24h")  // unknown: the 24h default
}

function shiftRange(value, delta) {
  var i = Math.max(0, Math.min(RANGES.length - 1, rangeIndex(value) + delta))
  return RANGES[i].value
}

// "4h 51m", "12m", "2d 3h", "<1m"
function formatDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  if (s < 60) return s > 0 ? "<1m" : "0m"
  var m = Math.floor(s / 60)
  var h = Math.floor(m / 60)
  var d = Math.floor(h / 24)
  if (d > 0) return h % 24 ? d + "d " + (h % 24) + "h" : d + "d"
  if (h > 0) return m % 60 ? h + "h " + (m % 60) + "m" : h + "h"
  return m + "m"
}

// Battery % at time t, linear between UPower's samples (which it writes
// only when the value moves), held flat before the first sample.
function valueAt(samples, t) {
  if (!samples || samples.length === 0) return NaN
  if (t <= samples[0][0]) return samples[0][1]
  for (var i = 1; i < samples.length; i++) {
    var b = samples[i]
    if (t <= b[0]) {
      var a = samples[i - 1]
      var span = b[0] - a[0]
      return span > 0 ? a[1] + (b[1] - a[1]) * (t - a[0]) / span : b[1]
    }
  }
  return samples[samples.length - 1][1]
}

function segmentAt(segments, t) {
  if (!segments) return ""
  for (var i = 0; i < segments.length; i++) {
    var s = segments[i]
    if (t >= s[0] && t < s[1]) return s[2]
  }
  if (segments.length && t >= segments[segments.length - 1][1] - 1) return segments[segments.length - 1][2]
  return ""
}

// Tick marks aligned to the local clock. Each tick is
// { t: seconds, kind: "day" | "hour" } — the caller formats the label.
// Steps shrink below an hour when the view is zoomed in.
function ticks(start, end) {
  var span = end - start
  var stepM
  if (span <= 1 * 3600) stepM = 10
  else if (span <= 1.5 * 3600) stepM = 15
  else if (span <= 3 * 3600) stepM = 30
  else if (span <= 6.5 * 3600) stepM = 60
  else if (span <= 13 * 3600) stepM = 120
  else if (span <= 25 * 3600) stepM = 240
  else if (span <= 4 * 86400) stepM = 720
  else stepM = 1440

  var out = []
  var d = new Date(start * 1000)
  d.setSeconds(0, 0)
  if (stepM < 60) d.setMinutes(Math.floor(d.getMinutes() / stepM) * stepM)
  else d.setMinutes(0)
  if (stepM === 1440) d.setHours(0)
  var inc = Math.min(stepM, 60)
  var guard = 0
  while (d.getTime() / 1000 <= end && guard++ < 400) {
    var t = d.getTime() / 1000
    var mins = d.getHours() * 60 + d.getMinutes()
    if (t > start && mins % stepM === 0)
      out.push({ t: t, kind: mins === 0 ? "day" : "hour" })
    d.setMinutes(d.getMinutes() + inc)
  }
  return out
}

// Zoom the visible window [viewStart, viewEnd] by `factor` (<1 zooms in),
// keeping the time under `anchor` (0..1 across the plot) where it is, then
// shift it by `pan` (a fraction of the new span). The result stays inside
// the data and is never narrower than minSpan.
function zoomView(viewStart, viewEnd, dataStart, dataEnd, anchor, factor, pan, minSpan) {
  var full = Math.max(1, dataEnd - dataStart)
  var cur = Math.max(1, viewEnd - viewStart)
  var span = Math.min(full, Math.max(Math.min(minSpan, full), cur * factor))
  var at = viewStart + anchor * cur
  var start = at - anchor * span + (pan || 0) * span
  start = Math.max(dataStart, Math.min(dataEnd - span, start))
  return { start: start, end: start + span }
}

// ---------- Stats ----------
// The collector's stats, computed for any [start, end] inside the data so
// they follow the zoomed window. Mirrors the stats block in collect.py.

var GAP_SECONDS = 45 * 60  // sample gaps longer than this are not used for drain rates

// Seconds per category of the [a, b] part of the segments.
function overlap(a, b, segs) {
  var out = {}
  for (var i = 0; i < (segs || []).length; i++) {
    var lo = Math.max(a, segs[i][0]), hi = Math.min(b, segs[i][1])
    if (hi > lo) out[segs[i][2]] = (out[segs[i][2]] || 0) + (hi - lo)
  }
  return out
}

function windowStats(samples, screen, power, start, end) {
  var totals = overlap(start, end, screen)
  var ptotals = overlap(start, end, power)
  function tot(o, k) { return o[k] || 0 }

  // Spread each discharging step's drop over the screen states it spanned.
  var drop = {}, onBatt = {}
  samples = samples || []
  for (var i = 1; i < samples.length; i++) {
    var s0 = samples[i - 1], s1 = samples[i]
    if (s1[0] <= start) continue
    if (s0[0] >= end) break
    if (s0[2] !== "discharging" || s1[2] !== "discharging") continue
    var a = Math.max(s0[0], start), b = Math.min(s1[0], end)
    if (b <= a || s1[1] > s0[1]) continue
    var span = s1[0] - s0[0]
    var parts = overlap(s0[0], s1[0], screen)
    if (span - tot(parts, "sleep") - tot(parts, "hibernate") - tot(parts, "off") > GAP_SECONDS) continue
    var inWindow = span ? (b - a) / span : 0
    for (var c in parts) {
      var share = span ? parts[c] / span : 0
      drop[c] = tot(drop, c) + (s0[1] - s1[1]) * share * inWindow
      onBatt[c] = tot(onBatt, c) + parts[c] * inWindow
    }
  }

  function rate(cats) {
    var d = 0, h = 0
    for (var k = 0; k < cats.length; k++) { d += tot(drop, cats[k]); h += tot(onBatt, cats[k]) / 3600 }
    return h > 0.25 ? Math.round(d / h * 100) / 100 : null
  }

  var used = 0
  for (var u in drop) used += drop[u]

  return {
    screenOn: Math.round(tot(totals, "on") + tot(totals, "idle")),
    screenActive: Math.round(tot(totals, "on")),
    displayOff: Math.round(tot(totals, "dark")),
    lidClosed: Math.round(tot(totals, "lid")),
    asleep: Math.round(tot(totals, "sleep")),
    hibernated: Math.round(tot(totals, "hibernate")),
    off: Math.round(tot(totals, "off")),
    charging: Math.round(tot(ptotals, "charging")),
    plugged: Math.round(tot(ptotals, "charging") + tot(ptotals, "plugged")),
    onBattery: Math.round(tot(ptotals, "battery")),
    drainScreenOn: rate(["on", "idle"]),
    drainAsleep: rate(["sleep"]),
    drainAwakeDark: rate(["dark", "lid"]),
    used: Math.round(used * 10) / 10
  }
}

// First and last sample indexes needed to draw [start, end]: the last one
// at or before start through the first one at or after end.
function visibleRange(samples, start, end) {
  var n = samples ? samples.length : 0
  if (n === 0) return { lo: 0, hi: -1 }
  var lo = 0
  while (lo + 1 < n && samples[lo + 1][0] <= start) lo++
  var hi = lo
  while (hi + 1 < n && samples[hi][0] < end) hi++
  return { lo: lo, hi: hi }
}

// The live reading appended at "now", so the line always reaches the
// right edge and matches the bar icon.
function withLivePoint(samples, now, percent, state) {
  var out = (samples || []).slice()
  if (isNaN(percent)) return out
  var last = out.length ? out[out.length - 1] : null
  if (!last || now > last[0]) out.push([now, percent, state || (last ? last[2] : "discharging")])
  return out
}

// ---------- Power ----------
// rates are [[t, watts], ...] from the collector, on battery only, one point
// per time bucket. Points further apart than `gap` seconds are separate runs
// (charging, asleep or off in between), so lines break there.

// Gap past which two power points are not joined.
function rateGap(bucket) {
  return Math.max(600, 3 * (Number(bucket) || 60))
}

// A round top for the watt axis: 5, 10, 15, 20, 30, 40, 60, 80, 100, ...
function niceCeil(v) {
  var steps = [5, 10, 15, 20, 30, 40, 60, 80, 100, 150, 200, 300, 500]
  for (var i = 0; i < steps.length; i++) if (v <= steps[i]) return steps[i]
  return Math.ceil(v / 100) * 100
}

// The scale top for the points in [start, end].
function rateScale(rates, start, end) {
  var top = 0
  for (var i = 0; i < (rates || []).length; i++) {
    var r = rates[i]
    if (r[0] >= start && r[0] <= end && r[1] > top) top = r[1]
  }
  return niceCeil(Math.max(top, 1))
}

// Watts at time t, linear between neighbouring points; NaN off the data or
// inside a gap.
function rateAt(rates, t, gap) {
  var n = rates ? rates.length : 0
  for (var i = 0; i < n; i++) {
    if (rates[i][0] < t) continue
    if (rates[i][0] === t) return rates[i][1]
    if (i === 0) return t >= rates[0][0] - gap / 2 ? rates[0][1] : NaN
    var a = rates[i - 1], b = rates[i]
    if (b[0] - a[0] > gap) {
      if (t - a[0] <= gap / 2) return a[1]
      if (b[0] - t <= gap / 2) return b[1]
      return NaN
    }
    return a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0])
  }
  return n && t - rates[n - 1][0] <= gap / 2 ? rates[n - 1][1] : NaN
}

// Mean draw over the points in [start, end] (each bucket is the same length
// of time, so a plain mean is the time-weighted one); null without data.
function averageRate(rates, start, end) {
  var sum = 0, n = 0
  for (var i = 0; i < (rates || []).length; i++) {
    if (rates[i][0] < start || rates[i][0] > end) continue
    sum += rates[i][1]
    n++
  }
  return n ? Math.round(sum / n * 10) / 10 : null
}

// ---------- Sleep settings ----------

// The idle service's own rule: a non-negative number of seconds, 0 = off.
function idleSeconds(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? Math.floor(n) : fallback
}

// Chip label for a duration: "Off", "45s", "2½m", "10m", "2h".
function shortSpan(secs, offLabel) {
  if (secs <= 0) return offLabel
  if (secs % 3600 === 0) return (secs / 3600) + "h"
  if (secs % 60 === 0) return (secs / 60) + "m"
  if (secs > 60 && secs % 60 === 30) return Math.floor(secs / 60) + "½m"
  return secs + "s"
}

// The preset chips, plus the current value when it is not one of them, so a
// hand-edited setting still shows as selected rather than vanishing.
function chipOptions(presets, current, offLabel) {
  var values = presets.slice()
  if (current >= 0 && values.indexOf(current) < 0) values.push(current)
  values.sort(function(a, b) { return a - b })
  return values.map(function(v) { return { value: String(v), label: shortSpan(v, offLabel) } })
}

// systemd time span ("2h", "1h 30min", "90min", "7200") -> seconds.
// null when unset, -1 when it cannot be read.
function parseSpan(text) {
  var s = String(text || "").trim().toLowerCase()
  if (!s) return null
  var units = { "": 1, s: 1, sec: 1, second: 1, seconds: 1, m: 60, min: 60, minute: 60, minutes: 60,
                h: 3600, hr: 3600, hour: 3600, hours: 3600, d: 86400, day: 86400, days: 86400,
                w: 604800, week: 604800, weeks: 604800 }
  var re = /(\d+(?:\.\d+)?)\s*([a-z]*)/g
  var total = 0, m, matched = false
  while ((m = re.exec(s)) !== null) {
    if (!(m[2] in units)) return -1
    total += Number(m[1]) * units[m[2]]
    matched = true
  }
  return matched ? Math.round(total) : -1
}

// Seconds -> the value written to sleep.conf ("30min", "2h").
function spanValue(secs) {
  return secs % 3600 === 0 ? (secs / 3600) + "h" : Math.round(secs / 60) + "min"
}

if (typeof module !== "undefined") {
  module.exports = {
    RANGES: RANGES,
    rangeSeconds: rangeSeconds,
    rangeIndex: rangeIndex,
    shiftRange: shiftRange,
    formatDuration: formatDuration,
    valueAt: valueAt,
    segmentAt: segmentAt,
    ticks: ticks,
    zoomView: zoomView,
    visibleRange: visibleRange,
    overlap: overlap,
    windowStats: windowStats,
    withLivePoint: withLivePoint,
    rateGap: rateGap,
    niceCeil: niceCeil,
    rateScale: rateScale,
    rateAt: rateAt,
    averageRate: averageRate,
    idleSeconds: idleSeconds,
    shortSpan: shortSpan,
    chipOptions: chipOptions,
    parseSpan: parseSpan,
    spanValue: spanValue
  }
}
