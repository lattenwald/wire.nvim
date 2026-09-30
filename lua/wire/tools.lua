local M = {}

-- curl: `-w %{header_json}`; jq: keeps the precision of large integers
M.min = { curl = "7.83", jq = "1.7" }

local versions = {}

function M.version(name)
  local path = vim.fn.exepath(name)
  if path == "" then
    return nil
  end
  if versions[path] == nil then
    local ok, r = pcall(function()
      return vim.system({ path, "--version" }, { text = true }):wait()
    end)
    versions[path] = ok and vim.version.parse(r.stdout or "", { strict = false }) or false
  end
  return versions[path] or nil
end

function M.usable(name)
  local v = M.version(name)
  return v ~= nil and vim.version.ge(v, M.min[name])
end

return M
