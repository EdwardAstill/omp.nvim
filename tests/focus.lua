local root = vim.fn.tempname() .. " omp focus"
vim.fn.mkdir(root, "p")
local fixture = root .. "/agent.py"
local input = root .. "/input"
vim.fn.writefile({
  "import os, sys, tty",
  "tty.setraw(sys.stdin.fileno())",
  "with open(sys.argv[1], 'wb', buffering=0) as received:",
  "    os.write(1, b''.join(b'history %d\\r\\n' % i for i in range(150)))",
  "    os.write(1, b'PROMPT> \\r\\nfooter one\\r\\nfooter two\\x1b[2A\\r\\x1b[8C')",
  "    while True:",
  "        data = os.read(0, 1024)",
  "        if data == b'\\x01':",
  "            os.write(1, b'\\x1b[?1000h\\x1b[?1006h')",
  "        else:",
  "            received.write(data)",
}, fixture)

-- An attached UI is needed to exercise actual terminal modes and mouse events.
local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE" }, { rpc = true })
local function rpc(method, ...)
  return vim.rpcrequest(child, method, ...)
end
local function lua(code, ...)
  return rpc("nvim_exec_lua", code, { ... })
end
local function wait_for(check, message)
  assert(vim.wait(3000, check, 10), message)
end
local function mode(expected)
  wait_for(function() return lua("return vim.fn.mode()") == expected end,
    "expected mode " .. expected .. ", got " .. lua("return vim.fn.mode()"))
end
local function received()
  return table.concat(vim.fn.readfile(input, "b"), "\n")
end
local function mouse(button, action, row, col)
  rpc("nvim_input_mouse", button, action, "", 0, row, col)
  -- Mouse coordinates are shared state, so let each event finish before the next.
  vim.wait(30)
end

local ok, err = xpcall(function()
  rpc("nvim_ui_attach", 120, 40, { rgb = true })
  lua([[
    local repo, fixture, input = ...
    vim.opt.rtp:prepend(repo)
    vim.o.mouse = "a"
    vim.keymap.set("n", "i", "k")
    require("omp").setup({ command = { "python3", fixture, input } })
  ]], vim.fn.getcwd(), fixture, input)
  local editor = rpc("nvim_get_current_win")
  local buffer = lua('return require("omp").open()')
  local panel = rpc("nvim_get_current_win")
  mode("t")
  wait_for(function()
    return table.concat(rpc("nvim_buf_get_lines", buffer, 0, -1, false), "\n"):find("footer two", 1, true)
  end, "fixture did not draw the prompt")
  local prompt = rpc("nvim_win_get_cursor", panel)
  local config = rpc("nvim_win_get_config", panel)
  local row, col = config.row + 5, config.col + 5
  local function scroll()
    local topline = lua("return vim.fn.line('w0')")
    mouse("wheel", "up", row, col)
    mouse("wheel", "up", row, col)
    mode("n")
    assert(lua("return vim.fn.line('w0')") < topline, "mouse wheel did not scroll history")
  end

  scroll()
  rpc("nvim_input", "<CR>")
  mode("t")
  assert(vim.deep_equal(rpc("nvim_win_get_cursor", panel), prompt), "Enter did not restore the prompt cursor")
  assert(received() == "", "returning to the prompt submitted input")
  rpc("nvim_input", "hello<CR>")
  wait_for(function() return received() == "hello\r" end, "typing did not reach the process exactly once")

  scroll()
  mouse("left", "press", row, col)
  mouse("left", "release", row, col)
  mode("t")
  assert(vim.deep_equal(rpc("nvim_win_get_cursor", panel), prompt), "click did not restore the prompt cursor")
  rpc("nvim_input", " world")
  wait_for(function() return received() == "hello\r world" end, "click did not restore typing")

  scroll()
  mouse("left", "press", row + 2, col)
  mouse("left", "drag", row + 3, col + 5)
  mouse("left", "release", row + 3, col + 5)
  mode("v")
  rpc("nvim_input", "<Esc>")
  mode("n")
  rpc("nvim_input", "<CR>")
  mode("t")
  rpc("nvim_input", "<C-\\><C-n>")
  mode("n")
  vim.wait(50)
  assert(lua("return vim.fn.mode()") == "n", "intentional Normal mode was overridden")

  rpc("nvim_set_current_win", editor)
  mode("n")
  rpc("nvim_set_current_win", panel)
  mode("t")
  mouse("left", "press", 0, 0)
  mouse("left", "release", 0, 0)
  mode("n")
  assert(rpc("nvim_get_current_win") == editor, "clicking outside the panel stole focus")
  mouse("left", "press", row, col)
  mouse("left", "release", row, col)
  mode("t")
  assert(rpc("nvim_get_current_win") == panel, "clicking back did not focus the panel")

  -- A queued focus callback must not reopen or focus a panel hidden immediately.
  lua([[
    local editor, panel = ...
    vim.api.nvim_set_current_win(editor)
    vim.api.nvim_set_current_win(panel)
    require("omp").hide()
  ]], editor, panel)
  mode("n")
  assert(rpc("nvim_get_current_win") == editor, "hidden panel stole focus")
  assert(lua('return require("omp").open()') == buffer, "focus recovery replaced the process")
  mode("t")

  -- OMP's fullscreen overlays enable mouse reporting; those events still belong to OMP.
  lua("vim.api.nvim_chan_send(vim.bo[...].channel, '\001')", buffer)
  vim.wait(50)
  mouse("wheel", "up", row, col)
  mode("t")
  wait_for(function() return received():find("\27[<64;", 1, true) ~= nil end, "TUI did not receive the wheel event")
  mouse("left", "press", row, col)
  mouse("left", "release", row, col)
  mode("t")
  wait_for(function() return received():find("m", #"hello\r world" + 1, true) ~= nil end, "TUI did not receive mouse release")
end, debug.traceback)

vim.fn.jobstop(child)
vim.fn.jobwait({ child }, 3000)
vim.fn.delete(root, "rf")
assert(ok, err)
print("OMP focus tests passed")
vim.cmd("qa!")
