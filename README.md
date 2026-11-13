# Battery history for Omarchy

A bar widget for the [Omarchy](https://omarchy.org) shell that shows your laptop's
battery level over time, and what the machine was doing underneath it: screen on,
screensaver, display off, lid closed, charging, asleep, hibernated or powered off.

- **Graph** of battery % for the last 6 h, 12 h, 24 h, 3 days or 7 days. The line turns
  yellow while charging, and sleep, hibernation and power-off are shaded.
- **Strips** under the graph for the screen, the charger and sleep (hibernation in blue).
- **Zoom**: scroll over the graph to zoom the time axis around the pointer,
  scroll sideways to pan, double-click to show the whole range.
- **Power overlay**: the **Power** chip draws the laptop's power draw (watts, on its
  own scale on the right) over the battery line. It is shown only while on battery:
  on the charger the battery's rate is what goes into it, not what the laptop uses.
- **Power mode**: the **Mode** chip adds a strip for the power profile (power saver,
  balanced, performance) while the laptop was awake. power-profiles-daemon keeps no
  history, so the widget records each change itself (to
  `~/.local/state/kov.battery-history/profiles.tsv`); the strip starts from when the
  plugin first ran.
- **Hover** anywhere on the graph for the exact time, percentage, state, power draw
  and power mode.
- **Stats for the visible window**, updated as you zoom: screen-on time, asleep,
  hibernated, charging, battery used, drain per hour with the screen on and asleep,
  average power draw on battery, and an estimated runtime on a full charge.
- **Sleep settings**: screensaver and lock timeouts (Omarchy's own idle settings),
  the hibernate delay for suspend-then-hibernate, and a plain-language note on
  what closing the lid does on battery and on the charger.

## Install

```sh
omarchy plugin add https://github.com/KeepThisTicket/omarchy-battery-history.git --enable
```

Update later with `omarchy plugin update kov.battery-history`.

## Requirements

- Omarchy with its Quickshell-based shell and plugin support.
- A laptop battery that UPower records history for (`/var/lib/upower/history-charge-*.dat`).
- `python3`.
- Read access to the system journal (for suspend, hibernate, lid and boot events).
  On Arch, members of the `wheel` group usually have it.
- `pkexec` and a polkit agent, only for changing the hibernate delay.

## Where the data comes from

Everything is read locally. Nothing leaves the machine.

| What | Source |
|---|---|
| Battery % and charging | UPower's charge history |
| Power draw | UPower's rate history (`history-rate-*.dat`, beside the charge history) |
| Power mode | The widget's own log of power-profiles-daemon changes |
| Boots, suspend, hibernate | Kernel messages in the system journal (`PM: suspend entry/exit`, `PM: hibernation: hibernation entry/exit`) |
| Lid open / closed | `systemd-logind` messages in the journal |
| Screensaver / lock / display off | Omarchy's idle service messages in the user journal |
| Lid action, hibernate delay | `busctl` (logind) and `systemd-analyze cat-config systemd/sleep.conf` |

## What it changes

- **Power mode log**: one line per power-profile change is appended to
  `~/.local/state/kov.battery-history/profiles.tsv` (a few lines a day).
- **Screensaver / lock timeouts** are written to `idle.screensaver` and `idle.lock`
  in `~/.config/omarchy/shell.json` (via `set-idle.py`, which changes only those
  two keys). Omarchy applies them immediately.
- **Hibernate delay** is written to `/etc/systemd/sleep.conf.d/30-hibernate-delay.conf`
  through `pkexec`, so you are asked for your password. That file is rewritten
  whole, so keep other sleep settings in a separate drop-in.

## Tips for suspend-then-hibernate

The hibernate delay only matters if closing the lid uses `suspend-then-hibernate`
(`HandleLidSwitch=` in a `logind.conf.d` drop-in). logind picks the lid action once,
when the lid closes. If you close the lid on the charger with
`HandleLidSwitchExternalPower=suspend` and unplug afterwards, the laptop never
hibernates. Using `suspend-then-hibernate` there too, with `HibernateOnACPower=no`
in a `sleep.conf.d` drop-in, keeps it asleep while plugged in and hibernates
it once unplugged.

## License

MIT, see [LICENSE](LICENSE).
