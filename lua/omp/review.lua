local M = {}
local api = vim.api
local active

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "OMP" })
end

local function lines(buffer)
  return api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function replace(buffer, text)
  vim.bo[buffer].modifiable = true
  api.nvim_buf_set_lines(buffer, 0, -1, false, text)
  vim.bo[buffer].modifiable = false
end

local function hunks(review)
  return vim.diff(table.concat(review.base, "\n") .. "\n", table.concat(review.proposed, "\n") .. "\n",
    { result_type = "indices", algorithm = "histogram" })
end

local function close(review)
  if active ~= review then return end
  active = nil
  if review.group then api.nvim_del_augroup_by_id(review.group) end
  if review.cancel then review.cancel() end
  local return_window = api.nvim_get_current_win()
  if review.tab and api.nvim_tabpage_is_valid(review.tab) then
    if api.nvim_win_get_tabpage(return_window) == review.tab then return_window = review.origin end
    api.nvim_set_current_tabpage(review.tab)
    if #api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose()
    else
      -- The user may have closed the original tab while reviewing.
      local window = api.nvim_get_current_win()
      vim.cmd.diffoff()
      if api.nvim_buf_is_valid(review.source) then
        api.nvim_win_set_buf(window, review.source)
      else
        vim.cmd.enew()
      end
      for _, other in ipairs(api.nvim_tabpage_list_wins(review.tab)) do
        if other ~= window then api.nvim_win_close(other, true) end
      end
    end
  end
  for _, buffer in ipairs(review.buffers or {}) do
    if api.nvim_buf_is_valid(buffer) then api.nvim_buf_delete(buffer, { force = true }) end
  end
  if api.nvim_win_is_valid(return_window) then api.nvim_set_current_win(return_window) end
end

local function unchanged(review)
  if not api.nvim_buf_is_loaded(review.source) or api.nvim_buf_get_changedtick(review.source) ~= review.tick then
    close(review)
    notify("Buffer changed; discarded stale proposal. Request it again using the current text.", vim.log.levels.WARN)
    return false
  end
  return true
end

local function current_hunk(review)
  local buffer, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
  local side = buffer == review.buffers[1] and 1 or buffer == review.buffers[2] and 3
  if side then
    for _, hunk in ipairs(hunks(review)) do
      local first, count = hunk[side], hunk[side + 1]
      if row >= math.max(1, first) and row <= math.max(1, first + math.max(1, count) - 1) then return hunk end
    end
  end
  notify("Move to a changed hunk with ]c / [c, or use the all action.", vim.log.levels.WARN)
end

local function splice(text, first, count, replacement, other_first, other_count)
  local result = vim.list_slice(text, 1, count == 0 and first or first - 1)
  if other_count > 0 then
    vim.list_extend(result, vim.list_slice(replacement, other_first, other_first + other_count - 1))
  end
  vim.list_extend(result, vim.list_slice(text, (count == 0 and first or first - 1) + count + 1))
  return #result > 0 and result or { "" }
end

local function refresh(review)
  local remaining = hunks(review)
  if #remaining == 0 then close(review); notify("OMP review finished; accepted changes are unsaved."); return end
  vim.cmd.diffupdate()
  for index, window in ipairs(review.windows) do
    if api.nvim_win_is_valid(window) then
      local row = remaining[1][index == 1 and 1 or 3]
      api.nvim_win_set_cursor(window, { math.max(1, math.min(row, api.nvim_buf_line_count(review.buffers[index]))), 0 })
    end
  end
end

function M.accept(all)
  local review = active
  if not review or not review.tab then notify("No proposal to accept"); return false end
  if not unchanged(review) then return false end
  if not vim.bo[review.source].modifiable then notify("Source buffer is not modifiable", vim.log.levels.WARN); return false end
  local hunk = not all and current_hunk(review) or nil
  if not all and not hunk then return false end
  api.nvim_buf_call(review.source, function()
    if all then
      api.nvim_buf_set_lines(review.source, 0, -1, false, review.proposed)
    else
      local start = hunk[2] == 0 and hunk[1] or hunk[1] - 1
      api.nvim_buf_set_lines(review.source, start, start + hunk[2], false,
        hunk[4] > 0 and vim.list_slice(review.proposed, hunk[3], hunk[3] + hunk[4] - 1) or {})
    end
  end)
  review.tick = api.nvim_buf_get_changedtick(review.source)
  review.base = lines(review.source)
  replace(review.buffers[1], review.base)
  refresh(review)
  return true
end

function M.reject(all)
  local review = active
  if not review then return false end
  if all or not review.tab then close(review); return true end
  local hunk = current_hunk(review)
  if not hunk then return false end
  review.proposed = splice(review.proposed, hunk[3], hunk[4], review.base, hunk[1], hunk[2])
  replace(review.buffers[2], review.proposed)
  refresh(review)
  return true
end

local function show(review)
  vim.cmd.stopinsert()
  vim.cmd.tabnew()
  review.tab = api.nvim_get_current_tabpage()
  review.buffers = { api.nvim_get_current_buf(), api.nvim_create_buf(false, true) }
  review.windows = { api.nvim_get_current_win() }
  for index, buffer in ipairs(review.buffers) do
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].buflisted = false
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    api.nvim_buf_set_name(buffer, ("omp://review/%d/%s"):format(buffer, index == 1 and "current" or "proposed"))
    replace(buffer, index == 1 and review.base or review.proposed)
    vim.bo[buffer].filetype = review.filetype
    local opts = { buffer = buffer, nowait = true }
    for key, mapping in pairs({
      a = { function() M.accept(false) end, "Accept hunk" },
      r = { function() M.reject(false) end, "Reject hunk" },
      A = { function() M.accept(true) end, "Accept all" },
      R = { function() M.reject(true) end, "Reject all remaining" },
      q = { function() M.reject(true) end, "Close review" },
      ["<Esc>"] = { function() M.reject(true) end, "Close review" },
      ["]c"] = { "]c", "Next hunk" },
      ["[c"] = { "[c", "Previous hunk" },
    }) do
      vim.keymap.set("n", key, mapping[1], vim.tbl_extend("force", opts, { desc = "OMP: " .. mapping[2] }))
    end
  end
  vim.cmd.diffthis()
  vim.wo.foldenable = false
  vim.wo.winbar = "OMP: current (unsaved)"
  vim.cmd("rightbelow vsplit")
  review.windows[2] = api.nvim_get_current_win()
  api.nvim_win_set_buf(0, review.buffers[2])
  vim.cmd.diffthis()
  vim.wo.foldenable = false
  vim.wo.winbar = "OMP: proposed | a/r hunk · A/R all · q close"
  review.group = api.nvim_create_augroup("OmpReview", { clear = true })
  api.nvim_create_autocmd({ "TabClosed", "BufWipeout" }, {
    group = review.group,
    callback = function()
      vim.schedule(function()
        if active == review and (not api.nvim_tabpage_is_valid(review.tab)
            or not api.nvim_buf_is_valid(review.buffers[1]) or not api.nvim_buf_is_valid(review.buffers[2])) then
          close(review)
        end
      end)
    end,
  })
  refresh(review)
end

function M.request(action, instruction, first, last)
  if active then notify("Finish or discard the current OMP proposal first", vim.log.levels.WARN); return false end
  local source = api.nvim_get_current_buf()
  if vim.bo[source].buftype ~= "" or not vim.bo[source].modifiable then
    notify("OMP suggestions need an editable text buffer", vim.log.levels.WARN)
    return false
  end
  local base = lines(source)
  local text = table.concat(base, "\n")
  local before, selected, after
  if action == "complete" then
    local cursor = api.nvim_win_get_cursor(0)
    local offset = math.min(cursor[2], #base[cursor[1]])
    for row = 1, cursor[1] - 1 do offset = offset + #base[row] + 1 end
    before, selected, after = text:sub(1, offset), "", text:sub(offset + 1)
  elseif action == "edit" then
    first, last = first or 1, last or #base
    if first < 1 or last < first or last > #base then notify("Invalid edit range", vim.log.levels.ERROR); return false end
    before = first > 1 and table.concat(base, "\n", 1, first - 1) .. "\n" or ""
    selected = table.concat(base, "\n", first, last)
    after = last < #base and "\n" .. table.concat(base, "\n", last + 1) or ""
  else
    error("Unknown OMP suggestion action")
  end
  local review = {
    source = source, origin = api.nvim_get_current_win(), tick = api.nvim_buf_get_changedtick(source),
    base = base, filetype = vim.bo[source].filetype,
  }
  active = review
  notify("OMP: requesting " .. (action == "complete" and "completion" or "edits") .. "… (:OmpReject all to cancel)")
  review.cancel = require("omp").suggest({
    action = action, instruction = instruction or "", file = api.nvim_buf_get_name(source), filetype = review.filetype,
    before = before, selected = selected, after = after,
  }, function(error, response)
    if active ~= review then return end
    review.cancel = nil
    if error then active = nil; notify(error, vim.log.levels.ERROR); return end
    if not response or type(response.text) ~= "string" or response.text:find("\0", 1, true) then
      active = nil; notify("OMP returned an invalid proposal", vim.log.levels.ERROR); return
    end
    if not unchanged(review) then return end
    if action == "edit" and response.text == "" then
      review.proposed = splice(base, first, last - first + 1, {}, 1, 0)
    else
      review.proposed = vim.split(before .. response.text .. after, "\n", { plain = true })
    end
    if #hunks(review) == 0 then active = nil; notify("OMP suggested no changes"); return end
    show(review)
  end)
  return true
end

return M
