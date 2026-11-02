local M = {}
local bridge = require("omp.bridge")
local sessions = {}
local options = { command = { "omp" } }
local window, target
local next_id = 0
local augroup = vim.api.nvim_create_augroup("OmpFloat", { clear = true })

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "OmpSessionsChanged" })
end

local function find(id)
  for cwd, group in pairs(sessions) do
    for index, session in ipairs(group) do
      if session.id == id then return session, group, index, cwd end
    end
  end
end

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

local function open(cwd, hidden)
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
    local previous = session
    if previous then bridge.stop(previous) else next_id = next_id + 1 end
    session = {
      buffer = vim.api.nvim_create_buf(false, true), id = previous and previous.id or next_id,
      name = previous and previous.name, file = previous and previous.file, cwd = cwd, status = "starting",
    }
    group[group.current] = session
    vim.bo[session.buffer].bufhidden = "hide"
    vim.bo[session.buffer].swapfile = false
    local command = vim.list_extend(vim.deepcopy(options.command), { "--cwd", cwd })
    if session.file and vim.fn.filereadable(session.file) == 1 then
      vim.list_extend(command, { "--resume", session.file })
    end
    local ok, extra, env = pcall(bridge.start, session, changed)
    if not ok then
      bridge.stop(session)
      vim.notify("Could not connect OMP to Neovim: " .. tostring(extra), vim.log.levels.ERROR)
      return
    end
    vim.list_extend(command, extra)
    vim.api.nvim_buf_call(session.buffer, function()
      session.job = vim.fn.jobstart(command, {
        term = true,
        cwd = cwd,
        env = env,
        on_exit = function()
          session.job, session.status = nil, "stopped"
          bridge.stop(session)
          changed()
        end,
      })
    end)
    if session.job <= 0 then
      bridge.stop(session)
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
  target = session.id
  changed()
  if hidden then return session.buffer end
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

function M.start()
  return open(nil, true)
end

function M.open()
  return open()
end

function M.new(cwd)
  local group
  group, cwd = directory_sessions(cwd)
  local previous = group.current
  group.current = #group + 1
  local buffer = open(cwd)
  if not buffer then group.current = previous end
  return buffer
end

function M.cycle()
  local group = directory_sessions()
  if #group > 0 then group.current = group.current % #group + 1 end
  return M.open()
end

function M.close(id)
  local group, cwd = directory_sessions()
  local was_visible = visible()
  local index
  if id then
    local session
    session, group, index, cwd = find(id)
    if not session then return false end
    group.current = index
  end
  -- The visible panel owns the target, even when invoked from another window.
  if not id and visible() then
    local buffer = vim.api.nvim_win_get_buf(window)
    for path, candidate in pairs(sessions) do
      if candidate[candidate.current] and candidate[candidate.current].buffer == buffer then
        group = candidate
        cwd = path
        break
      end
    end
  elseif not id and target then
    local session
    session, group, index, cwd = find(target)
    if not session then return false end
    group.current = index
  end
  local session = group[group.current]
  if not session then return false end
  M.hide()
  bridge.stop(session)
  if session.job then vim.fn.jobstop(session.job) end
  if vim.api.nvim_buf_is_valid(session.buffer) then
    vim.api.nvim_buf_delete(session.buffer, { force = true })
  end
  table.remove(group, group.current)
  if #group == 0 then
    group.current = 1
    if target == session.id then target = nil end
  else
    group.current = (group.current - 1) % #group + 1
    if target == session.id then target = group[group.current].id end
    if was_visible then open(cwd) end
  end
  changed()
  return true
end

function M.list()
  local result = {}
  for _, group in pairs(sessions) do
    for _, session in ipairs(group) do
      result[#result + 1] = {
        id = session.id, name = session.name or ("Session " .. session.id),
        cwd = session.project or session.cwd, status = session.job and session.status or "stopped",
        selected = target == session.id, buffer = session.buffer,
      }
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

function M.select(id, show)
  local session, group, index, cwd = find(id)
  if not session then return false end
  target, group.current = id, index
  changed()
  if show then return open(cwd) end
  return true
end

function M.open_selected()
  if target then return M.select(target, true) end
  return M.open()
end

local function request(id, message)
  local session = find(id or target)
  if not session or not session.job then
    vim.notify("Choose a running OMP session with :OmpSessions first", vim.log.levels.WARN)
    return false
  end
  return bridge.request(session, message, function(error)
    if error then vim.notify(error, vim.log.levels.ERROR) end
  end)
end

function M.send(text)
  if not text:find("%S") then return false end
  if not M.open_selected() then return false end
  return request(nil, { type = "draft", text = text })
end

function M.interrupt(id)
  return request(id, { type = "abort" })
end

function M.rename(id, name)
  return request(id, { type = "rename", name = name })
end

function M.toggle()
  local session = target and find(target)
  if visible() and session and vim.api.nvim_win_get_buf(window) == session.buffer
      and vim.api.nvim_win_get_tabpage(window) == vim.api.nvim_get_current_tabpage() then
    M.hide()
  else
    return M.open_selected()
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    for _, group in pairs(sessions) do
      for _, session in ipairs(group) do bridge.stop(session) end
    end
  end,
})

return M
