# Cliamp

Bar widget for [cliamp](https://cliamp.stream), the terminal internet-radio
player, for the Omarchy shell bar.

The button only appears while cliamp is actually playing, so it costs no bar
space the rest of the time. Clicking it opens a dropdown with prev /
play-pause / next / stop, a volume-ish station picker, and a search box that
queries the [Radio Browser](https://radio-browser.info) directory so you can
find any station and favourite it without leaving the panel.

## Requirements

- Omarchy shell
- [cliamp](https://cliamp.stream) installed and running
- `python3` and `curl`

## Install

One command:

```sh
omarchy plugin add https://github.com/RobbieUK1/omarchy-cliamp.git --enable
```

The button appears in the bar's **left** section immediately — nothing to copy
and no `shell.json` to edit. Add `--yes` to skip the placement question.

### Optional: survive `omarchy refresh shell`

`omarchy refresh shell` regenerates `shell.json` from the shipped defaults and
drops every widget that is not in them, which silently removes this one.
`ensure-bar.sh` puts it back. Wire it up with a systemd path unit that watches
`shell.json`:

`~/.config/systemd/user/omarchy-cliamp-bar.path`

```ini
[Unit]
Description=Watch shell.json and keep the Cliamp bar widget present

[Path]
PathChanged=%h/.config/omarchy/shell.json
Unit=omarchy-cliamp-bar.service

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/omarchy-cliamp-bar.service`

```ini
[Unit]
Description=Re-add the Cliamp bar widget after shell.json changes

[Service]
Type=oneshot
ExecStart=%h/.config/omarchy/plugins/robbie.cliamp/ensure-bar.sh
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now omarchy-cliamp-bar.path
```

The script is a no-op when the widget is already present or the plugin has been
disabled, so it never fights a removal you did on purpose.

## How it works

`Panel.qml` is a thin UI; the work happens in `cliamp.py`, which exists because
these things are awkward from QML:

| Subcommand  | What it does                                                        |
|-------------|---------------------------------------------------------------------|
| `poll`      | One call returning a normalized snapshot plus both station lists     |
| `play <url>`| Play a stream in the running instance right now                      |
| `search <q>`| Query the Radio Browser directory for matching stations              |
| `favorite`  | Toggle a station in `~/.config/cliamp/favorites.toml`               |
| `raw <args>`| Pass-through to the `cliamp` CLI for playback control                |

Every subcommand prints a single line of JSON, except `raw`, which stays silent
so a wall of error text never reaches the widget.

The built-in station list comes from cliamp's upstream `streams.m3u` and is
cached, so the widget does not wait on the network on every poll. Favourites
are read from and written back to `~/.config/cliamp/favorites.toml`.

## License

MIT
