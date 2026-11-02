local M = {}
local uv = vim.uv
local extension = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/extensions/neovim.ts"

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function transmit(bridge, id, entry)
  close(entry.timer)
  entry.timer = vim.defer_fn(function()
    if bridge.pending[id] ~= entry then return end
    bridge.pending[id] = nil
    entry.callback("No acknowledgement from OMP; check the draft before trying again")
  end, 5000)
  bridge.client:write(entry.message, function(error)
    if not error then return end
    vim.schedule(function()
      if bridge.pending[id] ~= entry then return end
      bridge.pending[id] = nil
      close(entry.timer)
      entry.callback("OMP connection closed: " .. error)
    end)
  end)
  entry.message = nil
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
            local connecting = not bridge.ready
            bridge.ready = true
            session.name = event.name or session.name
            session.project, session.file = event.cwd, event.file
            session.status = event.status
            if connecting then
              for id = 1, bridge.sequence do
                local entry = bridge.pending[id]
                if entry and entry.message then transmit(bridge, id, entry) end
              end
            end
            changed()
          elseif event.type == "response" then
            local request = bridge.pending[event.id]
            if request then
              bridge.pending[event.id] = nil
              close(request.timer)
              request.callback(event.error, event)
            end
          elseif event.type == "end" then
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
  if not bridge or not bridge.ready and session.status ~= "starting" then
    callback("OMP session is not connected")
    return false
  end
  bridge.sequence = bridge.sequence + 1
  request.id = bridge.sequence
  local entry = { callback = callback, message = vim.json.encode(request) .. "\n" }
  bridge.pending[request.id] = entry
  if bridge.ready then
    transmit(bridge, request.id, entry)
  else
    entry.timer = vim.defer_fn(function()
      if bridge.pending[request.id] ~= entry then return end
      bridge.pending[request.id] = nil
      callback("OMP did not finish startup; check its terminal before trying again")
    end, 30000)
  end
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
