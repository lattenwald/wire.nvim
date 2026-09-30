local H = {}

function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

function H.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
  return path
end

function H.trust(path)
  assert(vim.secure.trust({ action = "allow", path = path }))
end

function H.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

return H
