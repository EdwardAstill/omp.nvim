# omp.nvim

Run [Oh My Pi](https://github.com/can1357/oh-my-pi) inside a centered Neovim floating terminal,
using Neovim's current working directory (including `:lcd` and `:tcd`).
Requires Neovim 0.11+ and `omp` on PATH.

## Install with lazy.nvim

```lua
{
  "EdwardAstill/omp.nvim",
  cmd = { "Omp", "OmpToggle", "OmpHide", "OmpNew", "OmpCycle", "OmpClose" },
  opts = {},
  keys = {
    { "<leader>p", "<cmd>OmpToggle<cr>", desc = "Toggle OMP" },
  },
}
```

`:Omp` opens or focuses the centered floating panel. `:OmpToggle` shows/hides it.
`:OmpHide` or `Ctrl+q` inside the panel hides it without stopping the process.
After scrolling, click inside the panel or press Enter to return to the prompt.
That first Enter restores typing without submitting anything. Switching back to
the panel also restores typing; dragging to select terminal text still works.
Use `Ctrl+\ Ctrl+n` for terminal Normal mode, then enter these commands:

- `:OmpNew` starts and selects another independent process in the current directory.
- `:OmpCycle` selects the next session in that directory, wrapping around.
  With no sessions, it starts one.
- `:OmpClose` stops the selected process and deletes its terminal buffer, then
  shows the next session. Closing the last session hides the panel.
  With the panel hidden, it closes the current directory's selected session.

Returning to a directory reuses its selected session. Hidden sessions keep running.
An exited process restarts when selected again. Closing Neovim stops its terminal
jobs. Closing a terminal does not delete OMP's saved conversation history.

The plugin launches the real OMP TUI with `--cwd`; OMP handles authentication,
settings, and saved sessions. It does not submit prompts or change approval settings.
To override the executable, use `opts = { command = { "/path/to/omp" } }`.

## Test

From this checkout, run `nvim --headless -u NONE -l tests/terminal.lua`.
Run `nvim --headless -u NONE -l tests/focus.lua` for scrolling, mouse, and typing checks.
