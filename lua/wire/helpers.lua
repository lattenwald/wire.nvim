local context = require("wire.context")
local project = require("wire.project")

local M = {}

local cache = {}

function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local s = f:read("*a")
  f:close()
  return s
end

function M.load(content, chunk)
  local key = chunk .. "\0" .. vim.fn.sha256(content)
  if cache[key] then
    return cache[key]
  end
  local fn, err = load(content, chunk, "t", context.env)
  if not fn then
    error(err, 0)
  end
  local ok, t = xpcall(fn, debug.traceback)
  if not ok then
    error(t, 0)
  end
  if type(t) ~= "table" then
    error(chunk:gsub("^[@=]", "") .. ": a helper file must return a table", 0)
  end
  cache[key] = t
  return t
end

function M.load_all(opts)
  local merged, untrusted = {}, {}
  local function add(t)
    for k, v in pairs(t) do
      merged[k] = v
    end
  end
  for _, p in ipairs(opts.global or {}) do
    p = vim.fs.normalize(p)
    local content, err = M.read_file(p)
    if not content then
      error(("helper %s: %s"):format(p, err), 0)
    end
    add(M.load(content, "@" .. p))
  end
  if opts.root then
    local p = opts.root .. "/http-client.lua"
    local content, why = project.read_trusted(p)
    if content then
      add(M.load(content, "@" .. p))
    elseif why == "untrusted" then
      table.insert(untrusted, p)
    end
  end
  for _, s in ipairs(opts.imports or {}) do
    if s.kind == "file" then
      local p = project.resolve(opts.base_dir, s.path)
      local content, why = opts.read_import(p)
      if why == "untrusted" then
        table.insert(untrusted, p)
      elseif not content then
        error(("%s:%d: cannot read %s: %s"):format(opts.file, s.line, p, why), 0)
      else
        add(M.load(content, "@" .. p))
      end
    else
      add(M.load(s.code, ("=%s:%d"):format(opts.file, s.line)))
    end
  end
  return merged, untrusted
end

return M
