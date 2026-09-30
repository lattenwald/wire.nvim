local mask = require("wire.mask")
local template = require("wire.template")

local M = {}

M.current = nil

local stores = {}

function M.script_vars(buf)
  for b in pairs(stores) do
    if not vim.api.nvim_buf_is_valid(b) then
      stores[b] = nil
    end
  end
  stores[buf] = stores[buf] or {}
  return stores[buf]
end

function M.clear_script_vars(buf)
  stores[buf] = nil
end

function M.clear_project_vars(root)
  for buf in pairs(stores) do
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].wire_project_dir == root then
      stores[buf] = nil
    end
  end
end

local API = { vars = true, dir = true, secret = true, render = true, log = true }
local POST_ONLY = { request = true, response = true, test = true }

M.env = setmetatable({}, {
  __index = function(_, k)
    local c = M.current
    if API[k] or POST_ONLY[k] then
      if not c then
        error(("'%s' is only available during a send"):format(k), 2)
      end
      if POST_ONLY[k] and c.api[k] == nil then
        error(("'%s' is only available in post scripts"):format(k), 2)
      end
      return c.api[k]
    end
    if c and c.helpers[k] ~= nil then
      return c.helpers[k]
    end
    local g = _G[k]
    if g ~= nil then
      return g
    end
    error(("unknown name '%s' (variables are vars.%s)"):format(k, k), 2)
  end,
  __newindex = function(_, k)
    error(("cannot assign global '%s': use local %s, or vars.%s to keep a value"):format(k, k, k), 2)
  end,
})

function M.api()
  if not M.current then
    error("wire.ctx(): no send in progress", 2)
  end
  return setmetatable({}, {
    __index = function(_, k)
      return M.env[k]
    end,
  })
end

local Ctx = {}
Ctx.__index = Ctx

function M.new(opts)
  local self = setmetatable(opts, Ctx)
  self.doc_vars = self.doc_vars or {}
  self.env_vars = self.env_vars or {}
  self.env_private = self.env_private or {}
  self.helpers = self.helpers or {}
  self:begin_section({})
  self.api = {
    vars = setmetatable({}, {
      __index = function(_, k)
        return self:lookup(k)
      end,
      __newindex = function(_, k, v)
        self:set_var(k, v)
      end,
    }),
    dir = self.base_dir,
    secret = function(s)
      if type(s) ~= "string" then
        error("secret() takes a string", 2)
      end
      mask.register(s)
      return s
    end,
    render = function(s)
      return self:render(s, { where = "render()" })
    end,
    log = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[i] = type(v) == "string" and v or vim.inspect(v)
      end
      table.insert(self.logs, table.concat(parts, " "))
    end,
  }
  return self
end

function Ctx:begin_section(section_vars)
  self.section_vars = section_vars
  self.memo, self.stack, self.logs = {}, {}, {}
end

function Ctx:render(text, opts)
  return template.render(self, text, opts)
end

function Ctx:_render_def(key, text, private)
  local hit = self.memo[key]
  if hit then
    return hit
  end
  for i, k in ipairs(self.stack) do
    if k == key then
      local chain = {}
      for j = i, #self.stack do
        chain[#chain + 1] = self.stack[j]:sub(3)
      end
      chain[#chain + 1] = key:sub(3)
      error("variable cycle: " .. table.concat(chain, " → "), 0)
    end
  end
  table.insert(self.stack, key)
  local ok, v = pcall(self.render, self, text, { where = key:sub(3) })
  table.remove(self.stack)
  if not ok then
    error(v, 0)
  end
  if private then
    mask.register(v)
  end
  self.memo[key] = v
  return v
end

function Ctx:lookup(name)
  local s = self.section_vars[name]
  if s then
    return self:_render_def("s:" .. name, s)
  end
  local v = self.script_vars[name]
  if v ~= nil then
    return v
  end
  local d = self.doc_vars[name]
  if d then
    return self:_render_def("d:" .. name, d)
  end
  local e = self.env_vars[name]
  if e then
    return self:_render_def("e:" .. name, e, self.env_private[name])
  end
  return os.getenv(name)
end

function Ctx:set_var(name, v)
  local t = type(v)
  if t == "number" or t == "boolean" then
    v = tostring(v)
  elseif t ~= "string" and t ~= "nil" then
    error(("vars.%s: cannot store a %s"):format(name, v == vim.NIL and "JSON null" or t), 2)
  end
  self.script_vars[name] = v
  self.memo = {}
end

local function traceback(err)
  if type(err) == "string" and err:find("\nstack traceback:", 1, true) then
    return err
  end
  return debug.traceback(tostring(err), 2)
end

function Ctx:call(fn, ...)
  local prev = M.current
  M.current = self
  local ok, v = xpcall(fn, traceback, ...)
  M.current = prev
  if not ok then
    error(v, 0)
  end
  return v
end

function Ctx:eval(expr, where)
  local fn, err = load("return " .. expr, "=" .. where, "t", M.env)
  if not fn then
    error(err, 0)
  end
  local v = self:call(fn)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  error(("%s: expression returned %s: %s"):format(where, v == nil and "nil" or t, expr), 0)
end

return M
