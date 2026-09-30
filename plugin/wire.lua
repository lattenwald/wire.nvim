if vim.g.loaded_wire then
  return
end
vim.g.loaded_wire = true

vim.api.nvim_create_user_command("Wire", function(args)
  require("wire").command(args)
end, {
  nargs = "?",
  complete = function(lead)
    local names = vim.tbl_keys(require("wire").subcommands)
    table.sort(names)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, names)
  end,
})
