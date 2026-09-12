local M = {}
local sessions = {}
local options = { command = { "omp" } }
local window
local augroup = vim.api.nvim_create_augroup("OmpFloat", { clear = true })

local function directory_sessions(cwd)
  cwd = cwd or vim.fn.getcwd()
  if not sessions[cwd] then sessions[cwd] = { current = 1 } end
  return sessions[cwd], cwd
end

local function visible()
  return window and vim.api.nvim_win_is_valid(window)
end

local function float_config()
  local width = math.max(1, math.min(math.floor(vim.o.columns * 0.9), vim.o.columns - 2))
  local height = math.max(1, math.min(math.floor(vim.o.lines * 0.9), vim.o.lines - 2))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = " OMP ",
    title_pos = "center",
  }
end

vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  callback = function()
    if visible() then vim.api.nvim_win_set_config(window, float_config()) end
  end,
})

function M.setup(opts)
  options = vim.tbl_deep_extend("force", options, opts or {})
end

function M.hide()
  if not visible() then return false end
  vim.api.nvim_win_close(window, true)
  window = nil
  return true
end

local function open(cwd)
  local group
  group, cwd = directory_sessions(cwd)
  local session = group[group.current]
  if not session or not vim.api.nvim_buf_is_valid(session.buffer) or not session.job then
    if vim.fn.executable(options.command[1]) ~= 1 then
      vim.notify("OMP executable not found: " .. options.command[1], vim.log.levels.ERROR)
      return
    end
    if session and vim.api.nvim_buf_is_valid(session.buffer) then
      vim.api.nvim_buf_delete(session.buffer, { force = true })
    end
    session = { buffer = vim.api.nvim_create_buf(false, true) }
    group[group.current] = session
    vim.bo[session.buffer].bufhidden = "hide"
    vim.bo[session.buffer].swapfile = false
    local command = vim.list_extend(vim.deepcopy(options.command), { "--cwd", cwd })
    vim.api.nvim_buf_call(session.buffer, function()
      session.job = vim.fn.jobstart(command, {
        term = true,
        cwd = cwd,
        on_exit = function() session.job = nil end,
      })
    end)
    if session.job <= 0 then
      vim.api.nvim_buf_delete(session.buffer, { force = true })
      table.remove(group, group.current)
      group.current = math.max(1, math.min(group.current, #group))
      vim.notify("Failed to start OMP", vim.log.levels.ERROR)
      return
    end
    vim.bo[session.buffer].filetype = "omp"
    vim.keymap.set({ "n", "t" }, "<C-q>", M.hide, { buffer = session.buffer, desc = "Hide OMP" })
    vim.keymap.set("n", "<CR>", "<Cmd>startinsert<CR>", {
      buffer = session.buffer, desc = "Return to OMP prompt",
    })
    -- Resume after a click, leaving drag selections and TUI mouse handling intact.
    vim.keymap.set("n", "<LeftRelease>", function()
      local mouse = vim.fn.getmousepos()
      return mouse.winid == window and mouse.line > 0
          and "<LeftRelease><Cmd>startinsert<CR>" or "<LeftRelease>"
    end, { buffer = session.buffer, expr = true, desc = "Return to OMP prompt" })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = augroup,
      buffer = session.buffer,
      callback = function()
        vim.schedule(function()
          if visible() and vim.api.nvim_get_current_win() == window
              and vim.api.nvim_get_current_buf() == session.buffer and session.job
              and #vim.api.nvim_list_uis() > 0 then
            vim.cmd.startinsert()
          end
        end)
      end,
    })
  end
  if visible() and vim.api.nvim_win_get_tabpage(window) ~= vim.api.nvim_get_current_tabpage() then
    M.hide()
  end
  if visible() then
    vim.api.nvim_set_current_win(window)
    vim.api.nvim_win_set_buf(window, session.buffer)
  else
    window = vim.api.nvim_open_win(session.buffer, true, float_config())
  end
  vim.cmd("lcd " .. vim.fn.fnameescape(cwd))
  if #vim.api.nvim_list_uis() > 0 then vim.cmd.startinsert() end
  return session.buffer
end

function M.open()
  return open()
end

function M.new()
  local group = directory_sessions()
  local previous = group.current
  group.current = #group + 1
  local buffer = M.open()
  if not buffer then group.current = previous end
  return buffer
end

function M.cycle()
  local group = directory_sessions()
  if #group > 0 then group.current = group.current % #group + 1 end
  return M.open()
end

function M.close()
  local group, cwd = directory_sessions()
  -- The visible panel owns the target, even when invoked from another window.
  if visible() then
    local buffer = vim.api.nvim_win_get_buf(window)
    for path, candidate in pairs(sessions) do
      if candidate[candidate.current] and candidate[candidate.current].buffer == buffer then
        group = candidate
        cwd = path
        break
      end
    end
  end
  local session = group[group.current]
  if not session then return false end
  M.hide()
  if session.job then vim.fn.jobstop(session.job) end
  if vim.api.nvim_buf_is_valid(session.buffer) then
    vim.api.nvim_buf_delete(session.buffer, { force = true })
  end
  table.remove(group, group.current)
  if #group == 0 then
    group.current = 1
  else
    group.current = (group.current - 1) % #group + 1
    open(cwd)
  end
  return true
end

function M.toggle()
  local group = directory_sessions()
  local session = group[group.current]
  if visible() and session and vim.api.nvim_win_get_buf(window) == session.buffer
      and vim.api.nvim_win_get_tabpage(window) == vim.api.nvim_get_current_tabpage() then
    M.hide()
  else
    return M.open()
  end
end

return M
