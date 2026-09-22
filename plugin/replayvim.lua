if vim.g.loaded_replayvim then
  return
end
vim.g.loaded_replayvim = true

if vim.fn.has("nvim-0.8") == 0 then
  vim.notify("ReplayVim requires Neovim >= 0.8", vim.log.levels.WARN)
  return
end

require("replayvim")
