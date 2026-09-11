local M = {}
local sessions = {}
local options = { command = { "omp" } }
local window

local function visible()
  return window and vim.api.nvim_win_is_valid(window)
end

function M.setup(opts)
  options = vim.tbl_deep_extend("force", options, opts or {})
end

function M.hide()
  if not visible() then return false end
  if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(window)) == 1 then
    vim.api.nvim_win_call(window, function() vim.cmd("aboveleft new") end)
  end
  vim.api.nvim_win_close(window, true)
  window = nil
  return true
end

function M.open()
  local cwd = vim.fn.getcwd()
  local session = sessions[cwd]
  if not session or not vim.api.nvim_buf_is_valid(session.buffer) or not session.job then
    if vim.fn.executable(options.command[1]) ~= 1 then
      vim.notify("OMP executable not found: " .. options.command[1], vim.log.levels.ERROR)
      return
    end
    if session and vim.api.nvim_buf_is_valid(session.buffer) then
      vim.api.nvim_buf_delete(session.buffer, { force = true })
    end
    session = { buffer = vim.api.nvim_create_buf(false, true) }
    sessions[cwd] = session
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
      sessions[cwd] = nil
      vim.notify("Failed to start OMP", vim.log.levels.ERROR)
      return
    end
    vim.bo[session.buffer].filetype = "omp"
    vim.keymap.set({ "n", "t" }, "<C-q>", M.hide, { buffer = session.buffer, desc = "Hide OMP" })
  end
  if visible() and vim.api.nvim_win_get_tabpage(window) ~= vim.api.nvim_get_current_tabpage() then
    M.hide()
  end
  if visible() then
    vim.api.nvim_set_current_win(window)
    vim.api.nvim_win_set_buf(window, session.buffer)
  else
    vim.cmd("botright vsplit")
    window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(window, session.buffer)
    vim.api.nvim_win_set_width(window, math.max(1, math.floor(vim.o.columns * 0.4)))
  end
  vim.cmd("lcd " .. vim.fn.fnameescape(cwd))
  if #vim.api.nvim_list_uis() > 0 then vim.cmd.startinsert() end
  return session.buffer
end

function M.toggle()
  local session = sessions[vim.fn.getcwd()]
  if visible() and session and vim.api.nvim_win_get_buf(window) == session.buffer
      and vim.api.nvim_win_get_tabpage(window) == vim.api.nvim_get_current_tabpage() then
    M.hide()
  else
    return M.open()
  end
end

return M
