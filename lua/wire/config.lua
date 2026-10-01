local M = {}

M.defaults = {
  helpers = {},
  timeout = nil,
  trusted_dirs = {},
  mask = {
    headers = {
      authorization = true,
      ["proxy-authorization"] = true,
      cookie = true,
      ["x-api-key"] = true,
      ["api-key"] = true,
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  vim.validate("mask", opts.mask, { "boolean", "table" }, true)
  if opts.mask == true then
    opts.mask = nil
  end
  if type(opts.mask) == "table" then
    local headers = opts.mask.headers
    vim.validate("mask.headers", headers, "table", true)
    if headers then
      opts.mask.headers = {}
      for name, on in pairs(headers) do
        if type(name) ~= "string" or type(on) ~= "boolean" then
          error("wire: mask.headers must map header names to true or false", 0)
        end
        opts.mask.headers[name:lower()] = on
      end
    end
  end
  vim.validate("trusted_dirs", opts.trusted_dirs, "table", true)
  if opts.trusted_dirs then
    opts.trusted_dirs = vim.tbl_map(function(dir)
      local norm = vim.fs.normalize(dir)
      if norm:sub(1, 1) ~= "/" then
        error(("wire: trusted_dirs: %q is not an absolute path"):format(dir), 0)
      end
      return norm
    end, opts.trusted_dirs)
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

return M
