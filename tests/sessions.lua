-- nvim --headless -u NONE -l tests/sessions.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local omp = require("omp")
local picker = require("omp.picker")
local root = vim.fn.tempname() .. " omp sessions"
vim.fn.mkdir(root, "p")
local original_cwd = vim.fn.getcwd()
local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end
omp.setup({ command = { "bun", original_cwd .. "/tests/agent-fixture.ts" } })
vim.cmd("lcd " .. vim.fn.fnameescape(root))
local editor = api.nvim_get_current_win()
local function wait(check, message) assert(vim.wait(5000, check, 10), message) end
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function log(pid)
  local result = {}
  for _, line in ipairs(vim.fn.readfile(root .. "/" .. pid .. ".jsonl")) do result[#result + 1] = vim.json.decode(line) end
  return result
end
local function ready(id)
  wait(function()
    for _, session in ipairs(omp.list()) do if session.id == id then return session.status == "idle" end end
  end, "session did not connect")
end

-- Sending requires an existing process; no implicit agent or window is created.
assert(not omp.send("hello"))
assert(#omp.list() == 0 and #api.nvim_list_wins() == 1)
local first = omp.new()
local first_id = omp.list()[1].id
local first_job = vim.bo[first].channel
local first_pid = vim.fn.jobpid(first_job)
ready(first_id)
omp.hide()
local before = #log(first_pid)
assert(omp.send("first\nmultiline instruction"))
wait(function() return #log(first_pid) > before end, "prompt never arrived")
local delivered = log(first_pid)[before + 1]
assert(delivered.text == "first\nmultiline instruction" and delivered.draft == "unsent draft")
assert(api.nvim_get_current_win() == editor and #api.nvim_list_wins() == 1, "send opened the terminal")
assert(vim.fn.jobpid(first_job) == first_pid and #omp.list() == 1, "send launched a fresh agent")
ready(first_id)

-- Multiple processes keep their own conversation and can be targeted while hidden.
local second = omp.new()
local second_id = omp.list()[2].id
local second_job = vim.bo[second].channel
local second_pid = vim.fn.jobpid(second_job)
ready(second_id)
omp.hide()
picker.open()
api.nvim_win_set_cursor(0, { 1, 0 })
feed("s")
assert(api.nvim_get_current_win() == editor, "selecting a target opened its terminal")
assert(omp.list()[1].selected and not omp.list()[2].selected)
before = #log(first_pid)
omp.send("same conversation")
wait(function() return #log(first_pid) > before end, "selected process did not receive the prompt")
assert(#log(second_pid) == 1, "another session received the prompt")
assert(log(first_pid)[before + 1].file == delivered.file, "conversation changed between sends")
ready(first_id)

-- Busy sessions receive follow-ups; cancellation interrupts without closing them.
omp.send("wait")
wait(function() return omp.list()[1].status == "working" end, "busy state missing")
before = #log(first_pid)
omp.send("follow-up")
wait(function() return #log(first_pid) > before end, "follow-up did not arrive")
assert(log(first_pid)[before + 1].options.deliverAs == "followUp", "busy session was interrupted instead of queued")
omp.interrupt()
ready(first_id)
assert(vim.fn.jobwait({ first_job }, 0)[1] == -1, "interrupt killed the process")

-- Naming and opening act on the highlighted session, and the picker updates live.
picker.open()
api.nvim_win_set_cursor(0, { 2, 0 })
local input = vim.ui.input
vim.ui.input = function(_, callback) callback("Refactor API") end
feed("r")
wait(function() return omp.list()[2].name == "Refactor API" end, "rename did not reach OMP")
assert(api.nvim_get_current_line():find("Refactor API", 1, true), "picker did not refresh the name")
vim.ui.input = input
feed("<CR>")
assert(api.nvim_get_current_buf() == second and omp.list()[2].selected, "picker opened the wrong session")
assert(vim.fn.jobpid(second_job) == second_pid, "opening replaced the process")

-- Closing a picker row stops only that process and preserves its saved conversation.
picker.open()
api.nvim_win_set_cursor(0, { 2, 0 })
local saved = log(second_pid)[1].file
feed("d")
assert(#omp.list() == 1 and omp.list()[1].selected)
assert(vim.fn.jobwait({ second_job }, 3000)[1] ~= -1, "close left process running")
assert(vim.fn.filereadable(saved) == 1, "close deleted saved history")
assert(vim.fn.jobwait({ first_job }, 0)[1] == -1, "close stopped another session")
feed("q")
assert(api.nvim_get_current_win() == editor and #api.nvim_list_wins() == 1)

-- A picker target can belong to another project without moving the editor cwd.
local other = root .. "/another project"
vim.fn.mkdir(other, "p")
local other_buffer = omp.new(other)
local other_id = omp.list()[2].id
local other_pid = vim.fn.jobpid(vim.bo[other_buffer].channel)
ready(other_id)
omp.hide()
assert(vim.fn.getcwd() == root and omp.list()[2].cwd == other, "project scope changed the editor cwd")
omp.select(first_id)
before = #log(first_pid)
omp.send("target across projects")
wait(function() return #log(first_pid) > before end, "cross-project target did not receive the prompt")
assert(#vim.fn.readfile(other .. "/" .. other_pid .. ".jsonl") == 1, "send used the most recently opened project")
ready(first_id)
omp.close(other_id)

-- Explicitly reopening an exited terminal resumes its known saved conversation.
vim.fn.jobstop(first_job)
wait(function() return omp.list()[1].status == "stopped" end, "exit status missing")
assert(not omp.send("must not start a new session"))
local restarted = omp.open_selected()
local restarted_pid = vim.fn.jobpid(vim.bo[restarted].channel)
ready(first_id)
assert(log(restarted_pid)[1].file == delivered.file, "restart forgot the saved conversation")
omp.hide()

-- The picker can create a session even when the list is empty.
omp.close(first_id)
picker.open()
feed("n")
assert(#omp.list() == 1 and api.nvim_get_current_buf() == omp.list()[1].buffer)
omp.close()
picker.hide()
vim.cmd("lcd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
print("PASS: live session targeting, preserved drafts/history, queueing, picker actions, status, and restart")
vim.cmd("qa!")
