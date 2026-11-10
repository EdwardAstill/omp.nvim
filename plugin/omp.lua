if vim.g.loaded_omp then return end
vim.g.loaded_omp = true
vim.api.nvim_create_user_command("Omp", function() require("omp").open_selected() end, {})
vim.api.nvim_create_user_command("OmpToggle", function() require("omp").toggle() end, {})
vim.api.nvim_create_user_command("OmpHide", function() require("omp").hide() end, {})
vim.api.nvim_create_user_command("OmpNew", function() require("omp").new() end, {})
vim.api.nvim_create_user_command("OmpCycle", function() require("omp").cycle() end, {})
vim.api.nvim_create_user_command("OmpClose", function() require("omp").close() end, {})
vim.api.nvim_create_user_command("OmpSessions", function() require("omp.picker").open() end, {})
vim.api.nvim_create_user_command("OmpComplete", function()
  require("omp.review").request("complete")
end, { desc = "Propose an insertion at the cursor" })
vim.api.nvim_create_user_command("OmpEdit", function(args)
  require("omp.review").request("edit", args.args, args.range > 0 and args.line1 or nil, args.range > 0 and args.line2 or nil)
end, { range = true, nargs = "*", desc = "Propose document or selected-line edits" })
for _, action in ipairs({ "Accept", "Reject" }) do
  vim.api.nvim_create_user_command("Omp" .. action, function(args)
    if args.args ~= "" and args.args ~= "all" then error("Expected 'all' or no argument") end
    require("omp.review")[action:lower()](args.args == "all")
  end, { nargs = "?", complete = function() return { "all" } end, desc = action .. " an OMP hunk or all changes" })
end
