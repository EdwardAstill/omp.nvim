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
local completed = {}
api.nvim_create_autocmd("User", {
  pattern = "OmpAgentEnd",
  callback = function(event) completed[#completed + 1] = event.data end,
})
omp.setup({ command = { "bun", original_cwd .. "/tests/agent-fixture.ts" } })
vim.cmd("lcd " .. vim.fn.fnameescape(root))
local editor = api.nvim_get_current_win()
local function wait(check, message) assert(vim.wait(5000, check, 10), message) end
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function log(pid)
  local result = {}
  if vim.fn.filereadable(root .. "/" .. pid .. ".jsonl") == 0 then return result end
  for _, line in ipairs(vim.fn.readfile(root .. "/" .. pid .. ".jsonl")) do result[#result + 1] = vim.json.decode(line) end
  return result
end
local function ready(id)
  wait(function()
    for _, session in ipairs(omp.list()) do if session.id == id then return session.status == "idle" end end
  end, "session did not connect")
end

local function events(pid, kind)
  local result = {}
  for _, event in ipairs(log(pid)) do
    if event.type == kind then result[#result + 1] = event end
  end
  return result
end
local function staged(pid, count, text)
  wait(function() return #events(pid, "draft") >= count end, "draft never arrived")
  local drafts = events(pid, "draft")
  assert(#drafts == count and drafts[count].text == text, "lost, duplicated, or altered draft")
  return drafts[count]
end
local function enter(job, pid, count, text)
  local ended = #completed
  vim.fn.chansend(job, "\r")
  wait(function() return #events(pid, "prompt") >= count end, "manual Enter did not submit")
  local prompts = events(pid, "prompt")
  assert(#prompts == count and prompts[count].text == text and prompts[count].source == "enter")
  if text:match("^%s*(.-)%s*$") ~= "wait" then
    wait(function() return #completed > ended end, "manual submission did not emit OmpAgentEnd")
  end
end

-- Startup stays hidden and repeated startup reuses the same fresh conversation.
local first = omp.start()
local first_id = omp.list()[1].id
local first_job = vim.bo[first].channel
local first_pid = vim.fn.jobpid(first_job)
assert(api.nvim_get_current_win() == editor and #api.nvim_list_wins() == 1, "start stole focus")
assert(omp.start() == first and #omp.list() == 1, "start created another conversation")
assert(not omp.send(" \n\t"), "empty draft was accepted")
assert(api.nvim_get_current_win() == editor, "empty draft opened the terminal")

-- Sends before the socket handshake are delivered exactly once, in order.
local selection = "/tmp/file with spaces.lua:2-4\n\n> first\n> \n> last"
assert(omp.send(selection))
assert(omp.send("second\nmultiline instruction"))
assert(api.nvim_get_current_buf() == first and api.nvim_get_current_win() ~= editor, "send did not focus OMP")
local expected = "unsent draft\n\n" .. selection .. "\n\n\n\nsecond\nmultiline instruction\n\n"
local delivered = staged(first_pid, 2, expected)
assert(events(first_pid, "draft")[1].text == "unsent draft\n\n" .. selection .. "\n\n")
assert(#events(first_pid, "prompt") == 0, "staging submitted a prompt")
assert(vim.fn.jobpid(first_job) == first_pid and #omp.list() == 1, "send launched a fresh agent")
ready(first_id)
-- The user can edit the staged draft before explicitly submitting it.
vim.fn.chansend(first_job, "!")
staged(first_pid, 3, expected .. "!")
enter(first_job, first_pid, 1, expected .. "!")
ready(first_id)
assert(events(first_pid, "prompt")[1].file == delivered.file)
omp.hide()
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
local before = #events(first_pid, "draft")
assert(omp.send("same conversation"))
staged(first_pid, before + 1, "same conversation\n\n")
assert(#log(second_pid) == 1, "another session received the draft")
assert(events(first_pid, "draft")[before + 1].file == delivered.file, "conversation changed between sends")
assert(api.nvim_get_current_buf() == first, "selected session was not focused")
assert(#events(first_pid, "prompt") == 1, "selected-target staging submitted")

-- Busy sessions keep an editable draft, never an automatically queued follow-up.
vim.fn.chansend(first_job, "\x15")
staged(first_pid, before + 2, "")
assert(omp.send("wait"))
staged(first_pid, before + 3, "wait\n\n")
enter(first_job, first_pid, 2, "wait\n\n")
wait(function() return omp.list()[1].status == "working" end, "busy state missing")
assert(omp.send("follow-up"))
assert(staged(first_pid, before + 4, "follow-up\n\n").busy, "draft was not staged while busy")
assert(#events(first_pid, "prompt") == 2, "busy staging submitted or queued a prompt")
omp.interrupt()
ready(first_id)
assert(#events(first_pid, "prompt") == 2, "draft auto-submitted after cancellation")
assert(vim.fn.jobwait({ first_job }, 0)[1] == -1, "interrupt killed the process")
enter(first_job, first_pid, 3, "follow-up\n\n")
ready(first_id)
omp.hide()

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
before = #events(first_pid, "draft")
assert(omp.send("target across projects"))
staged(first_pid, before + 1, "target across projects\n\n")
assert(#vim.fn.readfile(other .. "/" .. other_pid .. ".jsonl") == 1, "send used the most recently opened project")
assert(api.nvim_get_current_buf() == first and vim.fn.getcwd() == root, "send focused the wrong project")
assert(#events(first_pid, "prompt") == 3, "cross-project staging submitted")
omp.close(other_id)

-- Sending to an exited target resumes its saved conversation and stages once.
vim.fn.jobstop(first_job)
wait(function() return omp.list()[1].status == "stopped" end, "exit status missing")
assert(omp.send("restart draft"))
local restarted = omp.list()[1].buffer
local restarted_pid = vim.fn.jobpid(vim.bo[restarted].channel)
ready(first_id)
assert(log(restarted_pid)[1].file == delivered.file, "restart forgot the saved conversation")
staged(restarted_pid, 1, "unsent draft\n\nrestart draft\n\n")
assert(#events(restarted_pid, "prompt") == 0, "restart submitted a prompt")
assert(api.nvim_get_current_buf() == restarted and #omp.list() == 1, "restart changed the selected target")
omp.hide()

-- Sending with no sessions creates one and preserves its startup draft.
omp.close(first_id)
assert(omp.send("implicit startup"))
local implicit = omp.list()[1]
local implicit_pid = vim.fn.jobpid(vim.bo[implicit.buffer].channel)
ready(implicit.id)
staged(implicit_pid, 1, "unsent draft\n\nimplicit startup\n\n")
assert(#events(implicit_pid, "prompt") == 0 and api.nvim_get_current_buf() == implicit.buffer)
omp.close(implicit.id)

-- The picker can create a session even when the list is empty.
assert(#omp.list() == 0)
picker.open()
feed("n")
assert(#omp.list() == 1 and api.nvim_get_current_buf() == omp.list()[1].buffer)
omp.close()
picker.hide()
vim.cmd("lcd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
print("PASS: hidden startup, ordered editable drafts, manual submission, busy staging, picker actions, and restart")
vim.cmd("qa!")
