# omp.nvim

Run [Oh My Pi](https://github.com/can1357/oh-my-pi) inside a Neovim terminal split,
using Neovim's current working directory (including `:lcd` and `:tcd`).
Requires Neovim 0.11+ and `omp` on PATH.

## Install with lazy.nvim

```lua
{
  "EdwardAstill/omp.nvim",
  opts = {},
  keys = {
    { "<leader>p", "<cmd>OmpToggle<cr>", desc = "Toggle OMP" },
  },
}
```

`:Omp` opens or focuses the right-hand panel. `:OmpToggle` shows/hides it.
`:OmpHide` or `Ctrl+q` inside the panel hides it without stopping the process.
Use `Ctrl+\ Ctrl+n` for terminal Normal mode. Each working directory gets its own
process; returning to a directory reuses its running session. An exited process
restarts on the next open. Closing Neovim stops its terminal jobs.

The plugin launches the real OMP TUI with `--cwd`; OMP handles authentication,
settings, and saved sessions. It does not submit prompts or change approval settings.
To override the executable, use `opts = { command = { "/path/to/omp" } }`.

## Test

From this checkout, run `nvim --headless -u NONE -l tests/terminal.lua`.
