# replayvim.nvim

Record every edit to a buffer and replay it from empty.

ReplayVim keeps a compact log of every change you make to a file, stored
beside it as a hidden dotfile (`foo.lua` -> `.foo.lua.replay`). Recording
costs O(1) per keystroke — no full-document diffing happens as you type,
only at commit points (leaving insert mode, or a completed normal-mode
change). You can then replay that history from an empty buffer, or export
it as a [VHS](https://github.com/charmbracelet/vhs) `.tape` script that
renders the whole edit session as a GIF.

## Requirements

Neovim >= 0.8.

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{ "<your-username>/replayvim.nvim" }
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**

```lua
use "<your-username>/replayvim.nvim"
```

**[vim-plug](https://github.com/junegunn/vim-plug)**

```vim
Plug '<your-username>/replayvim.nvim'
```

**Local / no plugin manager**

Point your plugin manager at this directory directly, or symlink it into
a native package location:

```sh
ln -s /path/to/this/repo ~/.local/share/nvim/site/pack/plugins/start/replayvim.nvim
```

No `setup()` call is required — ReplayVim starts recording every normal
file buffer as soon as it loads. Call `setup()` only if you want to
override a default:

```lua
require("replayvim").setup {
  gap_ms = 20, -- ms between ops during replay
}
```

## Usage

Just edit files normally; recording happens in the background.

| Command | Effect |
|---|---|
| `:ReplayVim [gap_ms]` | Replay this file's history in a split, from empty |
| `:ReplayVimStop` | Halt a running replay |
| `:ReplayVimTape [out]` | Export the history as a VHS `.tape` file |
| `:ReplayVimCheck` | Validate the log, report any bad ops |
| `:ReplayVimClear` | Delete this file's replay log |

See `:help replayvim` for full documentation, configuration options, and
the log format.

## License

[MIT](LICENSE)
