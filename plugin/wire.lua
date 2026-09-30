if vim.g.loaded_wire then
  return
end
vim.g.loaded_wire = true

vim.api.nvim_create_user_command("Wire", function(args)
  require("wire").command(args)
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(name)
      return name:sub(1, #lead) == lead
    end, vim.tbl_keys(require("wire").subcommands))
  end,
})
