-- plugin/notepad.lua
-- Registers :Notepad and :NotepadTree user commands on plugin load so they
-- are available without an explicit require("notepad").setup() call.
-- Full configuration (highlights, keymaps, options) still requires setup().

if vim.g.loaded_notepad then return end
vim.g.loaded_notepad = true

vim.api.nvim_create_user_command("Notepad", function(input)
  local path = input.args ~= "" and input.args or nil
  require("notepad").open(path)
end, {
  nargs = "?",
  complete = "dir",
  desc = "Open notepad for a directory",
})

vim.api.nvim_create_user_command("NotepadTree", function(input)
  local path = input.args ~= "" and input.args or nil
  require("notepad").show_tree(path)
end, {
  nargs = "?",
  complete = "dir",
  desc = "Show link tree for a directory",
})
