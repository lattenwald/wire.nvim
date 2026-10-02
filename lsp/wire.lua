return {
  cmd = function(dispatchers)
    return require("wire.lsp").server(dispatchers)
  end,
  filetypes = { "http" },
  root_dir = function(buf, on_dir)
    local name = vim.api.nvim_buf_get_name(buf)
    -- an unnamed buffer's URI is a bare file://, which maps back to no buffer
    if name ~= "" then
      local dir = vim.fs.dirname(name)
      on_dir(require("wire.project").find_root(dir) or dir)
    end
  end,
}
