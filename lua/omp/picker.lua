local M = {}
local api = vim.api
local window, buffer, rows

local function visible()
  return window and api.nvim_win_is_valid(window)
end

local function current()
  if not visible() then return end
  return rows[api.nvim_win_get_cursor(window)[1]]
end

function M.hide()
  if visible() then api.nvim_win_close(window, true) end
  window, buffer = nil, nil
end

function M.refresh()
  if not visible() then return end
  local selection = current()
  rows = require("omp").list()
  local lines, cursor = {}, 1
  for index, session in ipairs(rows) do
    local label = ("%s %d  %-12s %s  [%s]"):format(
      session.selected and ">" or " ", session.id, session.status, session.name,
      vim.fn.fnamemodify(session.cwd, ":~"))
    lines[index] = label:gsub("%c", " ")
    if selection and selection.id == session.id or not selection and session.selected then cursor = index end
  end
  if #lines == 0 then lines = { "No sessions yet. Press n to start OMP." } end
  vim.bo[buffer].modifiable = true
  api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  api.nvim_win_set_cursor(window, { cursor, 0 })
end

function M.open()
  if visible() then M.hide(); return end
  local omp = require("omp")
  local cwd = vim.fn.getcwd()
  omp.hide()
  rows = {}
  buffer = api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "omp-sessions"
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(12, vim.o.lines - 6))
  window = api.nvim_open_win(buffer, true, {
    relative = "editor", width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    style = "minimal", border = "rounded", title = " OMP sessions · > send target ",
    footer = " Enter open · s select · n new · r name · x stop · d close · q back ",
  })
  vim.wo[window].cursorline = true
  vim.wo[window].wrap = false
  local function map(keys, callback, description)
    vim.keymap.set("n", keys, callback, { buffer = buffer, desc = description })
  end
  map("<CR>", function()
    local session = current()
    if session then M.hide(); omp.select(session.id, true) end
  end, "Open OMP session")
  map("s", function()
    local session = current()
    if session then
      omp.select(session.id)
      M.hide()
      vim.notify("OMP target: " .. session.name)
    end
  end, "Select OMP send target")
  map("n", function() M.hide(); omp.new(cwd) end, "New OMP session")
  map("d", function()
    local session = current()
    if session then omp.close(session.id); M.refresh() end
  end, "Close OMP process (keep saved conversation)")
  map("x", function()
    local session = current()
    if session then omp.interrupt(session.id) end
  end, "Interrupt OMP work")
  map("r", function()
    local session = current()
    if not session then return end
    vim.ui.input({ prompt = "OMP session name: ", default = session.name }, function(name)
      if name and name:find("%S") then omp.rename(session.id, name) end
    end)
  end, "Rename OMP session")
  for _, key in ipairs({ "q", "<Esc>", "<C-q>" }) do map(key, M.hide, "Close OMP session picker") end
  M.refresh()
end

api.nvim_create_autocmd("User", {
  group = api.nvim_create_augroup("OmpSessionPicker", { clear = true }),
  pattern = "OmpSessionsChanged", callback = M.refresh,
})

return M
