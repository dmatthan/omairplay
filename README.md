# OmairPlay

![OmairPlay](preview.png?v=2)

Turn your Omarchy machine into an AirPlay speaker with your iPhone as the remote.

Tired of Apple Music not allowing remote play? No problem. Skip the broken Linux client: play from your iPhone straight to your system speakers, headphones, etc. Choose your machine
from the iOS AirPlay list, and the audio comes out of your system.

This plugin adds a GUI and convenience features to the terminal tool `shairport-sync`. OmairPlay simplifies the setup and implements a seamless experience: it installs what's needed, opens only
the firewall ports AirPlay actually uses and only to your local network, puts
the receiver's state in your bar, and shows what's playing — all using your current
Omarchy theme, of course!

## Requirements

| | |
|---|---|
| Omarchy | 4.0.3 or newer (plugin API) |
| Audio | PipeWire with `pipewire-pulse` (the Omarchy default) |
| Discovery | `avahi-daemon` running (the Omarchy default) |
| Packages | `shairport-sync` and `nqptp` — **setup installs these** |
| Firewall | `ufw`, if enabled — **setup adds the rules** |

## Install

```bash
omarchy plugin add https://github.com/dmatthan/omairplay --enable
```

Then click the new bar icon and choose **Run setup**.

## Setup, and what it needs root for

Setup opens a terminal so you can read every command before approving the
password prompt. It:

1. Takes a system snapshot (`omarchy snapshot create`), if snapper is configured.
2. Installs `shairport-sync` and `nqptp`.
3. Enables `nqptp` as a **system** service — it needs privileged ports 319 and
   320 for AirPlay 2 clock sync.
4. Adds `ufw` rules **limited to private networks**, never to Anywhere. Each one
   is tagged `omairplay`, so you can always see what added it:

   ```bash
   sudo ufw status | grep omairplay
   ```
5. Writes the receiver's config and a user service under `$HOME`.

**The plugin itself never needs root while running.** Only setup and removal do,
and both run visibly in a terminal.

The receiver runs as a user service, `omarchy-airplay.service`. A machine gets
one AirPlay 2 receiver, so if the packaged `shairport-sync` units are enabled,
setup tells you which one to disable and how.

## Using it

Pick your machine from the AirPlay list on your phone, and play:

![Choosing the speaker on iOS, and playing to it](iphone.png)

The bar icon shows the receiver's state:

| Icon | Meaning |
|---|---|
| Speaker, dimmed | Off, or not set up |
| Speaker | Ready, waiting for a device |
| Cast | Playing |

- **Click** — open the popup
- **Right-click** — turn the receiver on or off without opening anything
- In the popup: `j`/`k` or arrows to move, `Enter` to activate, `Esc` to close

The popup shows what's playing — title, artist, album, cover art, the sending
device's volume, and a level meter driven by the receiver's real output. When
the track changes, a notification appears with the cover art.

It takes its colours and font from whichever Omarchy theme you're using:

![The popup under three Omarchy themes](themes.png?v=2)

Control playback from your phone — it stays the player throughout.

## Settings

In the popup: **speaker name** and **start at login**.

Renaming restarts the receiver, which interrupts playback, so it asks first.

The rest are available via the bar config:

```bash
omarchy bar set io.github.dmatthan.omairplay trackNotifications false
omarchy bar set io.github.dmatthan.omairplay showArtwork false
omarchy bar set io.github.dmatthan.omairplay refreshIntervalSec 5
omarchy bar move io.github.dmatthan.omairplay --section right
```

## If your phone sees the speaker but won't connect

Check the firewall. mDNS discovery reaches you through `ufw` on its own, so the
speaker can appear on your phone while the connection is still blocked.
OmairPlay reads the live `ufw` rules and says so in the popup, with a button to
re-run setup.

The same applies after your router hands out a new IPv6 prefix. Re-running
setup picks up your current addresses.

## Removing it

Two steps, and the order matters.

1. **Remove receiver** in the popup. This undoes the setup: it stops the
   receiver, disables it at login, deletes its config and cover-art cache,
   removes the firewall rules it added, and turns the `nqptp` system service
   back off if setup was the thing that enabled it.
2. Then remove the plugin itself:

   ```bash
   omarchy plugin remove io.github.dmatthan.omairplay
   ```

Setup also keeps a copy of the uninstaller outside the plugin folder, so it
works on its own:

```bash
~/.local/state/io.github.dmatthan.omairplay/airplay-remove --system
```

Every rule it adds carries the `omairplay` tag, and the uninstaller finds them
by that tag.

The `shairport-sync` and `nqptp` packages stay installed.

## What it puts on your system

Everything, in one place:

| Path | What it is |
|---|---|
| `~/.config/shairport-sync/shairport-sync.conf` | the receiver's config, generated from your settings |
| `~/.config/systemd/user/omarchy-airplay.service` | the user service that runs the receiver |
| `~/.cache/shairport-sync/` | cover art the receiver receives |
| `~/.local/state/io.github.dmatthan.omairplay/` | the uninstaller, the audio-readiness helper the service runs, the firewall rule list they share, and a note recording whether setup enabled `nqptp` |
| `ufw` rules | 11, each tagged `omairplay`, private ranges only |
| `nqptp.service` | enabled, for AirPlay 2 clock sync |
| `shairport-sync`, `nqptp` | packages, from Arch `extra` |

Nothing is written outside `$HOME` apart from those last three. No autostart
entries, no `PATH` changes, no shell-profile edits, no scheduled jobs.

The two executables in `~/.local/state/` are there on purpose: removing the
plugin deletes its folder, and the receiver would stop working if its service
pointed into it. Keeping them outside means the service survives, and the
uninstaller is still available to undo the firewall rules and the `nqptp`
service afterwards. Both are removed when the uninstaller finishes.

## Notes on safety

Omarchy plugins run unsandboxed inside the shell process, with your user's
permissions — this one included. What that means here:

- Root is used only by `bin/airplay-setup` and `bin/airplay-remove`, both run
  visibly in a terminal. Neither is invoked with `pkexec`: the plugin folder is
  user-writable, so running a script from it as root would be a way to escalate.
- Firewall rules are limited to private address ranges — RFC1918, plus IPv6
  link-local and unique-local — following the same convention as Omarchy's own
  installers. `ufw` is never disabled or reset. The widest rule, the kernel
  ephemeral range AirPlay 2 uses for its audio channels, is limited to the
  private ranges this machine actually holds an address in.
- Removal works from the `omairplay` tag on each rule, so it needs no saved
  list and never executes a command read from a file.
- Every command either half of the plugin runs is named by its full path, so
  nothing is resolved through a `PATH` you can write to. The setup and removal
  scripts restart themselves in an environment they build from scratch, so
  nothing inherited from your session can change what they run.
- The files setup places outside the plugin folder are written to exactly the
  path named, or not at all: it refuses to write through a symlink, and each
  file is moved into place in one step rather than copied over the old one.
- Firewall *state* is read from `/etc/ufw/user.rules`, which is world-readable,
  so checking it needs no privilege.
- Your local network is the trust boundary: a device has to be on it to reach
  the receiver.
- Nothing is written outside `$HOME`, apart from the packages and the `nqptp`
  system service enabled during setup.

## Licence

MIT — see [LICENSE](LICENSE).
