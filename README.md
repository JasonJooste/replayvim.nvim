# replayvim.nvim

Record every edit to a buffer and replay it from empty.

ReplayVim keeps a compact log of every change you make to a file, stored beside it as a hidden dotfile (`foo.lua` -> `.foo.lua.replay`). 
As a compromise between granularity and space constraints, it makes one entry per edit. 
You can then replay that history from an empty buffer, or export it as a [VHS](https://github.com/charmbracelet/vhs) `.tape` script to render the session as as a gif or video file.

## Requirements

Neovim >= 0.8.

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{ "JasonJooste/replayvim.nvim" }
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**

```lua
use "JasonJooste/replayvim.nvim"
```

**[vim-plug](https://github.com/junegunn/vim-plug)**

```vim
Plug 'JasonJooste/replayvim.nvim'
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
