# omp.nvim

Run [Oh My Pi](https://github.com/can1357/oh-my-pi) inside a centered Neovim floating terminal,
using Neovim's current working directory (including `:lcd` and `:tcd`).
Requires Neovim 0.11+ and `omp` on PATH.

## Install with lazy.nvim

```lua
{
  "EdwardAstill/omp.nvim",
  cmd = { "Omp", "OmpToggle", "OmpHide", "OmpNew", "OmpCycle", "OmpClose", "OmpSessions" },
  opts = {},
  keys = {
    { "<leader>p", "<cmd>OmpSessions<cr>", desc = "OMP sessions" },
  },
}
```

`:OmpSessions` opens a picker for processes owned by this Neovim. It shows the
name, directory, state, and selected send target (`>`). Enter selects and opens;
`s` selects without opening; `n` creates a session in the editor's directory;
`r` renames; `x` interrupts; `d` closes the process; `q`/Escape returns to editing.
Closing a process preserves its saved conversation.

`:Omp` opens the selected session in the centered floating panel. `:OmpToggle` shows/hides it.
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

The picker includes this Neovim's sessions across working directories. Hidden sessions keep running.
Opening an exited process resumes its known saved conversation when available. Closing Neovim stops its terminal
jobs. Closing a terminal does not delete OMP's saved conversation history.

The plugin launches the real OMP TUI with `--cwd`; OMP handles authentication,
settings, and saved sessions. `/resume` inside OMP searches saved conversations;
Tab switches between current-project and all-project history. `/new` starts a
fresh conversation within the same process.
To override the executable, use `opts = { command = { "/path/to/omp" } }`.

## Drafts from the editor

`require("omp").start()` starts a fresh conversation for the current directory
without opening a panel or moving editor focus; repeated calls reuse that process.
Call it during interactive Neovim startup to have OMP ready in the background.

`require("omp").send(text)` opens the selected session and appends text to its
editable draft, with blank lines left for an instruction. It starts a session if
needed and waits for startup before staging. Existing draft text is preserved;
nothing submits or queues until the user presses Enter, even while OMP is busy.
Hosts can use this to stage file paths or quoted selections with file/line context.
`require("omp").interrupt()` interrupts the selected agent.

An OMP extension edits the prompt over a private local socket, loaded only for
these terminals. Subagents do not connect. Restart existing processes after
updating. `User OmpAgentEnd` fires when an agent turn finishes, including manually
submitted prompts; hosts can use it to reload saved buffers. The picker tracks
runtime processes, while OMP owns saved history. Sessions in other terminals are
not listed.

## Test

From this checkout, run `nvim --headless -u NONE -l tests/terminal.lua`.
Run `nvim --headless -u NONE -l tests/focus.lua` for scrolling, mouse, and typing checks.
Run `nvim --headless -u NONE -l tests/sessions.lua` for draft staging, manual submission, and picker controls
(requires Bun; uses a fake agent and sends no model requests).
