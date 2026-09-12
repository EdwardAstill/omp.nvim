vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns = 300
local omp = require("omp")
local root = vim.fn.tempname() .. " omp test"
vim.fn.mkdir(root .. "/one", "p")
vim.fn.mkdir(root .. "/two", "p")
local fixture = root .. "/agent.py"
vim.fn.writefile({
  'import os, sys',
  'print("CWD=" + os.getcwd(), flush=True)',
  'print("ARGS=" + repr(sys.argv[1:]), flush=True)',
  'for line in sys.stdin:',
  '    if line.strip() == "exit": break',
}, fixture)
omp.setup({ command = { "python3", fixture } })
local function output(buf, text)
  return vim.wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(text, 1, true) ~= nil
  end)
end
vim.cmd.cd(vim.fn.fnameescape(root .. "/one"))
local editor = vim.api.nvim_get_current_win()
local editor_width = vim.api.nvim_win_get_width(editor)
local first = omp.open()
local panel = vim.api.nvim_get_current_win()
local config = vim.api.nvim_win_get_config(panel)
assert(config.relative == "editor", "OMP is not a floating window")
assert(vim.api.nvim_win_get_width(editor) == editor_width, "OMP resized the editor")
assert(math.abs(config.col - (vim.o.columns - config.width - 2) / 2) <= 1,
  "OMP is not horizontally centered")
vim.o.columns = 240
vim.api.nvim_exec_autocmds("VimResized", {})
assert(vim.api.nvim_win_get_width(panel) == 216, "OMP did not resize with the editor")
assert(output(first, "CWD=" .. root .. "/one"), "wrong process cwd")
assert(output(first, "['--cwd', '" .. root .. "/one']"), "cwd argument was not preserved")
local job = vim.bo[first].channel
assert(omp.hide())
assert(vim.fn.jobwait({ job }, 0)[1] == -1, "hide killed process")
assert(omp.open() == first, "open did not reuse process")
omp.hide()
vim.cmd("lcd " .. vim.fn.fnameescape(root .. "/two"))
local second = omp.open()
assert(second ~= first and output(second, "CWD=" .. root .. "/two"), "local cwd not respected")
omp.hide()
vim.cmd("lcd " .. vim.fn.fnameescape(root .. "/one"))
assert(omp.open() == first, "return to directory lost session")
local concurrent = omp.new()
local concurrent_job = vim.bo[concurrent].channel
assert(concurrent ~= first and output(concurrent, "CWD=" .. root .. "/one"),
  "new did not create another session in the same directory")
assert(vim.fn.jobwait({ job }, 0)[1] == -1, "new stopped the previous session")
assert(omp.cycle() == first, "cycle did not wrap to first session")
assert(omp.cycle() == concurrent, "cycle did not return to new session")
assert(omp.close(), "close did not remove selected session")
assert(vim.fn.jobwait({ concurrent_job }, 3000)[1] ~= -1, "close left process running")
assert(not vim.api.nvim_buf_is_valid(concurrent), "close retained terminal buffer")
assert(omp.open() == first, "close did not select remaining session")
assert(omp.cycle() == first, "cycle included another directory or closed session")
vim.api.nvim_chan_send(job, "exit\n")
assert(vim.wait(3000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end), "fixture did not exit")
vim.wait(50)
local restarted = omp.open()
assert(restarted ~= first and output(restarted, "CWD=" .. root .. "/one"), "exited process did not restart")
omp.toggle()
assert(not omp.hide(), "toggle did not hide")
assert(omp.close(), "hidden session did not close")
assert(not omp.close(), "close without a session should do nothing")
assert(not omp.hide(), "closing last session left panel open")
assert(vim.fn.jobwait({ vim.bo[second].channel }, 0)[1] == -1,
  "closing session stopped another directory's process")
vim.api.nvim_buf_delete(second, { force = true })
vim.fn.delete(root, "rf")
print("OMP terminal tests passed")
vim.cmd("qa!")
