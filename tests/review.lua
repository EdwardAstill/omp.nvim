-- nvim --headless -u NONE -l tests/review.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns = 160
local api = vim.api
local review = require("omp.review")
local response, cancelled
require("omp").suggest = function(_, callback)
  response = callback
  return function() cancelled = true end
end
vim.cmd.runtime("plugin/omp.lua")
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function source(text)
  review.reject(true)
  local buffer = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buffer)
  api.nvim_buf_set_lines(buffer, 0, -1, false, text)
  return buffer
end
local function same(buffer, expected)
  assert(vim.deep_equal(api.nvim_buf_get_lines(buffer, 0, -1, false), expected), vim.inspect(api.nvim_buf_get_lines(buffer, 0, -1, false)))
end
local function proposal(text)
  response(nil, { text = text })
  assert(#api.nvim_list_tabpages() == 2, "proposal did not open a review")
  assert(vim.wo.diff and not vim.bo.modifiable, "review is not a read-only native diff")
end

-- Review against unsaved text, not disk/Git; accept one hunk and reject another.
local original = { "local a = 1", "", "-- unsaved context", "", "local b = 2" }
local buffer = source({ "local a = 1", "", "-- saved context", "", "local b = 2" })
local path = vim.fn.tempname() .. ".lua"
api.nvim_buf_set_name(buffer, path)
vim.cmd.write()
api.nvim_win_set_cursor(0, { 3, 0 })
feed("cc-- unsaved context<Esc>")
same(buffer, original)
vim.cmd.OmpEdit()
proposal("local a = 10\n\n-- unsaved context\n\nlocal b = 20")
same(buffer, original)
feed("a")
same(buffer, { "local a = 10", "", "-- unsaved context", "", "local b = 2" })
feed("r")
assert(#api.nvim_list_tabpages() == 1 and api.nvim_get_current_buf() == buffer)
assert(vim.bo[buffer].modified, "accepted changes were saved")
assert(vim.fn.readfile(path)[3] == "-- saved context", "review modified the file on disk")
feed("u")
same(buffer, original)
vim.fn.delete(path)

-- Insertions and deletions at either boundary and in a selected range.
for _, case in ipairs({
  { original = { "keep", "last" }, first = 1, last = 1, text = "first\nkeep", expected = { "first", "keep", "last" } },
  { original = { "first", "keep" }, first = 2, last = 2, text = "keep\nlast", expected = { "first", "keep", "last" } },
  { original = { "remove", "keep" }, first = 1, last = 1, text = "", expected = { "keep" } },
  { original = { "keep", "remove" }, first = 2, last = 2, text = "", expected = { "keep" } },
  { original = { "first", "remove", "last" }, first = 2, last = 2, text = "", expected = { "first", "last" } },
  { original = { "remove" }, first = 1, last = 1, text = "", expected = { "" } },
}) do
  buffer = source(case.original)
  assert(review.request("edit", "", case.first, case.last))
  proposal(case.text)
  feed("a")
  same(buffer, case.expected)
  assert(#api.nvim_list_tabpages() == 1, "single hunk did not finish")
  buffer = source(case.original)
  assert(review.request("edit", "", case.first, case.last))
  proposal(case.text)
  feed("r")
  same(buffer, case.original)
  assert(#api.nvim_list_tabpages() == 1, "rejected hunk did not finish")
end

-- Cursor completion respects byte columns, existing suffix and unsaved unnamed buffers.
buffer = source({ "local greeting = 'λ'", "print()" })
api.nvim_win_set_cursor(0, { 1, #"local greeting = 'λ" })
vim.cmd.OmpComplete()
proposal(" world")
vim.cmd("OmpAccept all")
same(buffer, { "local greeting = 'λ world'", "print()" })

-- Typing during inference or after preview must never overwrite newer text.
buffer = source({ "old" })
review.request("edit")
api.nvim_buf_set_lines(buffer, 0, -1, false, { "typed while waiting" })
response(nil, { text = "model result" })
same(buffer, { "typed while waiting" })
assert(#api.nvim_list_tabpages() == 1, "stale response opened a review")
review.request("edit")
proposal("replacement")
api.nvim_buf_set_lines(buffer, 0, -1, false, { "typed during review" })
assert(not review.accept(true))
same(buffer, { "typed during review" })
assert(#api.nvim_list_tabpages() == 1, "stale review stayed actionable")

-- Cancellation ignores late results and error responses leave the source intact.
buffer = source({ "original" })
cancelled = false
review.request("edit")
local late = response
assert(not review.request("complete"), "allowed overlapping proposals")
vim.cmd("OmpReject all")
assert(cancelled, "discard did not cancel inference")
review.request("edit")
late(nil, { text = "stale cancelled result" })
assert(#api.nvim_list_tabpages() == 1)
response("provider unavailable")
same(buffer, { "original" })
review.request("edit")
response(nil, { text = { "invalid" } })
same(buffer, { "original" })
review.request("edit")
proposal("proposed")
feed("q")
same(buffer, { "original" })
review.request("edit")
proposal("proposed")
vim.cmd.tabclose()
vim.wait(20)
assert(review.request("edit"), "closing review tab left a stuck proposal")
review.reject(true)

-- Closing the source while waiting discards the reply.
buffer = source({ "closing" })
review.request("edit")
api.nvim_buf_delete(buffer, { force = true })
response(nil, { text = "must not resurrect" })
assert(#api.nvim_list_tabpages() == 1)
print("PASS: unsaved review, hunk accept/reject, undo, boundary edits, cursor insertion, stale guards, cancellation and cleanup")
vim.cmd("qa!")
