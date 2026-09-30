local project = require("wire.project")

local M = {}

local function is_object(v)
  if type(v) ~= "table" then
    return false
  end
  if next(v) == nil then
    return getmetatable(v) ~= nil -- `{}` decodes with a metatable, `[]` without
  end
  return not vim.islist(v)
end

local function merge(a, b)
  if not (is_object(a) and is_object(b)) then
    return b
  end
  local out = vim.empty_dict()
  for k, v in pairs(a) do
    out[k] = v
  end
  for k, v in pairs(b) do
    out[k] = merge(a[k], v)
  end
  return out
end

local function scalar(v)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
end

local function read(path, untrusted)
  local content, why = project.read_trusted(path)
  if why == "untrusted" then
    table.insert(untrusted, path)
  end
  if not content then
    return vim.empty_dict()
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or not is_object(data) then
    error(path .. " is not a JSON object", 0)
  end
  return data
end

function M.load(root)
  local res, untrusted = { names = {}, envs = {} }, {}
  if not root then
    return res, untrusted
  end
  local public = read(root .. "/http-client.env.json", untrusted)
  local private = read(root .. "/http-client.private.env.json", untrusted)
  local all = merge(public, private)
  for name, value in pairs(all) do
    if name:sub(1, 1) ~= "$" and is_object(value) then
      local merged = merge(all["$shared"] or vim.empty_dict(), value)
      local vars, headers, priv = {}, {}, {}
      for k, v in pairs(merged) do
        if k == "$defaultHeaders" and is_object(v) then
          for hk, hv in pairs(v) do
            headers[hk] = scalar(hv)
          end
        elseif k:sub(1, 1) ~= "$" then
          vars[k] = scalar(v)
        end
      end
      for _, key in ipairs({ "$shared", name }) do
        local src = private[key]
        if is_object(src) then
          for k in pairs(src) do
            priv[k] = true
          end
        end
      end
      res.envs[name] = { vars = vars, private = priv, default_headers = headers }
      table.insert(res.names, name)
    end
  end
  table.sort(res.names)
  return res, untrusted
end

local selected

local function state_path()
  return vim.fn.stdpath("state") .. "/wire/env.json"
end

function M.load_state()
  if selected then
    return selected
  end
  selected = {}
  local f = io.open(state_path(), "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      selected = data
    end
  end
  return selected
end

function M.current(root, names)
  local name = M.load_state()[root]
  if name and vim.tbl_contains(names, name) then
    return name
  end
  if #names == 1 then
    return names[1]
  end
end

function M.selected(root)
  return selected and selected[root]
end

function M.select(root, name)
  M.load_state()[root] = name
  vim.fn.mkdir(vim.fs.dirname(state_path()), "p")
  local f = assert(io.open(state_path(), "w"))
  f:write(vim.json.encode(selected))
  f:close()
end

return M
