local M = {}
local uv = vim.uv
local extension = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/extensions/neovim.ts"

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

function M.start(session, changed)
  local bridge = { root = vim.fn.tempname(), pending = {}, sequence = 0 }
  session.bridge = bridge
  vim.fn.mkdir(bridge.root, "p", 448)
  bridge.path = bridge.root .. "/omp.sock"
  bridge.server = assert(uv.new_pipe(false))
  assert(bridge.server:bind(bridge.path))
  assert(bridge.server:listen(1, function(error)
    if error or session.bridge ~= bridge then return end
    local client = assert(uv.new_pipe(false))
    bridge.server:accept(client)
    if bridge.client then close(client); return end
    bridge.client = client
    local pending = ""
    client:read_start(function(read_error, data)
      if read_error or not data then
        close(client)
        vim.schedule(function()
          if session.bridge ~= bridge then return end
          bridge.client, bridge.ready = nil, false
          session.status = session.job and "disconnected" or "stopped"
          changed()
        end)
        return
      end
      pending = pending .. data
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then break end
        local line = pending:sub(1, newline - 1)
        pending = pending:sub(newline + 1)
        vim.schedule(function()
          if session.bridge ~= bridge then return end
          local ok, event = pcall(vim.json.decode, line)
          if not ok or type(event) ~= "table" then return end
          if event.type == "state" then
            bridge.ready = true
            session.name = event.name or session.name
            session.project, session.file = event.cwd, event.file
            session.status = event.status
            changed()
          elseif event.type == "response" then
            local request = bridge.pending[event.id]
            if request then
              bridge.pending[event.id] = nil
              close(request.timer)
              request.callback(event.error, event)
            end
          elseif event.type == "end" and session.sent then
            session.sent = false
            vim.notify("OMP: " .. (session.name or ("Session " .. session.id)) .. " finished")
            vim.api.nvim_exec_autocmds("User", {
              pattern = "OmpAgentEnd", data = { buffer = session.buffer, id = session.id },
            })
          end
        end)
      end
    end)
  end))
  return { "--extension", extension }, { OMP_NVIM_SOCKET = bridge.path }
end

function M.request(session, request, callback)
  local bridge = session.bridge
  if not bridge or not bridge.ready or not bridge.client then
    callback("Session is not ready; open it to finish startup")
    return false
  end
  bridge.sequence = bridge.sequence + 1
  request.id = bridge.sequence
  local entry = { callback = callback }
  bridge.pending[request.id] = entry
  entry.timer = vim.defer_fn(function()
    if bridge.pending[request.id] ~= entry then return end
    bridge.pending[request.id] = nil
    callback("No acknowledgement from OMP; check the session before sending again")
  end, 5000)
  bridge.client:write(vim.json.encode(request) .. "\n", function(error)
    if not error then return end
    vim.schedule(function()
      if bridge.pending[request.id] ~= entry then return end
      bridge.pending[request.id] = nil
      close(entry.timer)
      callback("OMP connection closed: " .. error)
    end)
  end)
  return true
end

function M.stop(session)
  local bridge = session.bridge
  if not bridge then return end
  session.bridge = nil
  close(bridge.client)
  close(bridge.server)
  for _, entry in pairs(bridge.pending) do
    close(entry.timer)
    entry.callback("OMP session closed")
  end
  vim.fn.delete(bridge.root, "rf")
end

return M
