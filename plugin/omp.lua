if vim.g.loaded_omp then return end
vim.g.loaded_omp = true
vim.api.nvim_create_user_command("Omp", function() require("omp").open() end, {})
vim.api.nvim_create_user_command("OmpToggle", function() require("omp").toggle() end, {})
vim.api.nvim_create_user_command("OmpHide", function() require("omp").hide() end, {})
