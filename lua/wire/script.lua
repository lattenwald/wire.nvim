local context = require("wire.context")
local project = require("wire.project")

local M = {}

function M.name(script)
  if script.kind == "file" then
    return script.path
  end
  return ("post script (line %d)"):format(script.line)
end

function M.compile(script, base_dir, file, read)
  local code, chunk
  if script.kind == "file" then
    if not script.path:match("%.lua$") then
      error(("%s:%d: a script file must end in .lua: %s"):format(file, script.line, script.path), 0)
    end
    local path = project.resolve(base_dir, script.path)
    local content, why = read(path)
    if not content then
      error(("%s:%d: cannot read %s: %s"):format(file, script.line, path, why), 0)
    end
    code, chunk = content, "@" .. path
  else
    code, chunk = script.code, ("=%s:%d"):format(file, script.line)
  end
  local fn, err = load(code, chunk, "t", context.env)
  if not fn then
    error(err, 0)
  end
  return fn
end

local function describe(msg, default)
  return msg and (msg .. ": " .. default) or default
end

local function new_t(rec)
  local function fail(msg)
    rec.ok = false
    table.insert(rec.messages, msg)
  end
  local t = {}
  function t.ok(cond, msg)
    if not cond then
      fail(msg or "condition is false")
    end
  end
  function t.eq(got, want, msg)
    if not vim.deep_equal(got, want) then
      fail(describe(msg, ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want))))
    end
  end
  function t.contains(s, sub, msg)
    if type(s) ~= "string" or not s:find(sub, 1, true) then
      fail(describe(msg, ("%s does not contain %s"):format(vim.inspect(s), vim.inspect(sub))))
    end
  end
  function t.match(s, pattern, msg)
    if type(s) ~= "string" or not s:match(pattern) then
      fail(describe(msg, ("%s does not match %s"):format(vim.inspect(s), vim.inspect(pattern))))
    end
  end
  return t
end

function M.run_test(tests, name, fn)
  local rec = { name = name, ok = true, messages = {} }
  table.insert(tests, rec)
  local ok, err = xpcall(fn, debug.traceback, new_t(rec))
  if not ok then
    rec.ok = false
    table.insert(rec.messages, err)
  end
  return rec
end

return M
