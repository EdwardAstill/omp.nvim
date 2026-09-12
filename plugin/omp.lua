if vim.g.loaded_omp then return end
vim.g.loaded_omp = true
vim.api.nvim_create_user_command("Omp", function() require("omp").open() end, {})
vim.api.nvim_create_user_command("OmpToggle", function() require("omp").toggle() end, {})
vim.api.nvim_create_user_command("OmpHide", function() require("omp").hide() end, {})
vim.api.nvim_create_user_command("OmpNew", function() require("omp").new() end, {})
vim.api.nvim_create_user_command("OmpCycle", function() require("omp").cycle() end, {})
vim.api.nvim_create_user_command("OmpClose", function() require("omp").close() end, {})
