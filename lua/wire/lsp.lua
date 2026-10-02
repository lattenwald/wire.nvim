local context = require("wire.context")
local document = require("wire.document")
local env = require("wire.env")
local mask = require("wire.mask")
local project = require("wire.project")
local template = require("wire.template")

local M = {}

local SymbolKind = vim.lsp.protocol.SymbolKind
local ACTIONS = { { "send", "Send request" }, { "send_all", "Send all requests" }, { "yank", "Yank request as curl" } }
local WHERE = {
  section = "section variable",
  doc = "file variable",
  script = "script variable from an earlier send (`:Wire reset` clears it)",
  process = "process environment variable",
}

local function range(line, col, end_line, end_col)
  return { start = { line = line, character = col }, ["end"] = { line = end_line, character = end_col } }
end

local function line_range(lines, n)
  return range(n - 1, 0, n - 1, #lines[n])
end

local function location(path, r)
  return { uri = vim.uri_from_fname(path), range = r }
end

-- in-process: read the buffer itself, no document sync
local function open(params)
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return buf, lines, document.parse(lines)
end

local function script_at(doc, row)
  local sec = document.section_at(doc, row)
  for _, list in ipairs({ doc.preamble.imports, sec and sec.pre or {}, sec and sec.post or {} }) do
    for _, s in ipairs(list) do
      if row >= s.line and row <= s.last then
        return s
      end
    end
  end
end

-- scripts are Lua, never rendered
local function var_at(lines, doc, row, col)
  if script_at(doc, row) then
    return
  end
  local _, vars = template.inline(lines[row] or "", 1)
  for _, v in ipairs(vars) do
    if v[1] <= col + 1 and col < v[2] then
      return v[3]
    end
  end
end

local function find_var(vars, name)
  for i = #vars, 1, -1 do
    if vars[i].name == name then
      return vars[i]
    end
  end
end

-- { env = { key = { line, col, len } } }, 0-based; len is the quoted key as written
local function env_keys(text)
  local out, depth, top, line, line_start, i = {}, 0, nil, 0, 1, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\n" then
      line, line_start = line + 1, i + 1
    elseif c == "{" or c == "[" then
      depth = depth + 1
    elseif c == "}" or c == "]" then
      depth = depth - 1
    elseif c == '"' then
      local j = i + 1
      while j <= #text and text:sub(j, j) ~= '"' do
        j = j + (text:sub(j, j) == "\\" and 2 or 1)
      end
      local ok, key = pcall(vim.json.decode, text:sub(i, j))
      if ok and text:find("^%s*:", j + 1) then
        if depth == 1 then
          top = key
          out[top] = out[top] or {}
        elseif depth == 2 and top then
          out[top][key] = { line = line, col = i - line_start, len = j - i + 1 }
        end
      end
      i = j
    end
    i = i + 1
  end
  return out
end

-- variable layers as a send from `row` builds them, but env files are read without :trust (only shown)
local function scope(buf, doc, row, script_vars)
  local _, root = project.refresh(buf)
  local ok, envs = pcall(env.load, root, { read = project.read_file, origin = true })
  local err
  if not ok then
    envs, err = { names = {}, envs = {} }, envs
  end
  local current = root and env.current(root, envs.names)
  local e = current and envs.envs[current] or {}
  local sec = document.section_at(doc, row)
  local ctx = context.new({
    doc_vars = document.vars_map(doc.preamble.vars),
    env_vars = e.vars,
    env_private = e.private,
    script_vars = script_vars,
  })
  ctx:begin_section(document.vars_map(sec and sec.vars or {}))
  return ctx, sec, envs, current, err
end

local function env_location(origin, name, keys)
  if keys[origin.path] == nil then
    local text = project.read_file(origin.path)
    keys[origin.path] = text and env_keys(text) or false
  end
  local pos = keys[origin.path] and (keys[origin.path][origin.env] or {})[name]
  return pos and location(origin.path, range(pos.line, pos.col, pos.line, pos.col + pos.len))
end

local function definition(params)
  local buf, lines, doc = open(params)
  local row = params.position.line + 1
  local script = script_at(doc, row)
  if script and script.kind == "file" then
    local path = project.resolve((project.refresh(buf)), script.path)
    return vim.uv.fs_stat(path) and { location(path, range(0, 0, 0, 0)) } or nil
  end
  local name = var_at(lines, doc, row, params.position.character)
  if not name then
    return nil
  end
  local ctx, sec, envs, current = scope(buf, doc, row, {})
  local kind = ctx:source(name)
  if kind == "section" or kind == "doc" then
    local v = find_var(kind == "section" and sec.vars or doc.preamble.vars, name)
    return { location(vim.api.nvim_buf_get_name(buf), line_range(lines, v.line)) }
  end
  -- with no environment selected and nothing else defining it, every environment's definition
  local out, seen, keys = {}, {}, {}
  for _, e in ipairs(kind == "env" and { current } or not (kind or current) and envs.names or {}) do
    local origin = envs.envs[e].origin[name]
    local id = origin and origin.path .. "\0" .. origin.env
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = env_location(origin, name, keys)
    end
  end
  return out
end

local function hover(params)
  local buf, lines, doc = open(params)
  local row = params.position.line + 1
  local name = var_at(lines, doc, row, params.position.character)
  if not name then
    return nil
  end
  local ctx, _, envs, current, err = scope(buf, doc, row, context.script_vars(buf))
  local kind, value = ctx:source(name)
  local where = WHERE[kind]
  if kind == "env" then
    local origin = envs.envs[current].origin[name]
    local shared = origin.env == "$shared" and " (`$shared`)" or ""
    where = ("environment `%s`%s, %s"):format(current, shared, vim.fs.basename(origin.path))
    if ctx.env_private[name] then
      value = mask.hide(value)
    end
  elseif kind == "process" then
    value = nil
  elseif not kind then
    local defined = vim.tbl_filter(function(e)
      return envs.envs[e].vars[name] ~= nil
    end, envs.names)
    where = (not current and #defined > 0)
        and ("no environment selected (`:Wire env`); defined in `%s`"):format(table.concat(defined, "`, `"))
      or "undefined"
  end
  local text = ("`{{%s}}`: %s"):format(name, where)
  if value then
    value = mask.apply(value)
    local fence = "```"
    for run in value:gmatch("`+") do
      if #run >= #fence then
        fence = ("`"):rep(#run + 1)
      end
    end
    text = ("%s\n%s\n%s\n%s"):format(text, fence, value, fence)
  end
  if err then
    text = text .. "\n\nenv files not read: " .. mask.apply(err)
  end
  return { contents = { kind = "markdown", value = text } }
end

local function document_symbol(params)
  local _, lines, doc = open(params)
  local function vars(list)
    return vim.tbl_map(function(v)
      local r = line_range(lines, v.line)
      return { name = "@" .. v.name, kind = SymbolKind.Variable, range = r, selectionRange = r }
    end, list)
  end
  local out = vars(doc.preamble.vars)
  for _, sec in ipairs(doc.sections) do
    local req = sec.request
    local label = req and (req.method .. " " .. req.url)
    out[#out + 1] = {
      name = sec.name ~= "" and sec.name or ("### line %d"):format(sec.line),
      detail = label ~= sec.name and label or nil,
      kind = SymbolKind.Method,
      range = range(sec.line - 1, 0, sec.last - 1, #lines[sec.last]),
      selectionRange = line_range(lines, sec.line),
      children = vars(sec.vars),
    }
  end
  return out
end

local function code_action(params)
  -- the actions send requests and have no kind; a kind filter gets none
  if params.context and params.context.only then
    return {}
  end
  local buf, _, doc = open(params)
  local row = params.range.start.line + 1
  local sec = document.section_at(doc, row)
  if not (sec and sec.request) then
    return {}
  end
  local args = { params.textDocument.uri, row, vim.b[buf].changedtick }
  return vim.tbl_map(function(a)
    return { title = a[2], command = "wire." .. a[1], arguments = args }
  end, ACTIONS)
end

local function execute_command(params)
  local action = require("wire").actions[params.command:match("^wire%.(.+)") or ""]
  if not action then
    error("unknown command: " .. params.command, 0)
  end
  local uri, row, tick = unpack(params.arguments or {})
  local buf = uri and vim.uri_to_bufnr(uri)
  -- a cached action's row is stale once the buffer changes
  if not (buf and vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].changedtick == tick) then
    error("the buffer changed since the action was offered; ask for actions again", 0)
  end
  action(buf, row)
end

local handlers = {
  initialize = function()
    return {
      capabilities = {
        positionEncoding = "utf-8",
        documentSymbolProvider = true,
        definitionProvider = true,
        hoverProvider = true,
        codeActionProvider = true,
        executeCommandProvider = {
          commands = vim.tbl_map(function(a)
            return "wire." .. a[1]
          end, ACTIONS),
        },
      },
      serverInfo = { name = "wire" },
    }
  end,
  shutdown = function() end,
  ["textDocument/documentSymbol"] = document_symbol,
  ["textDocument/definition"] = definition,
  ["textDocument/hover"] = hover,
  ["textDocument/codeAction"] = code_action,
  ["workspace/executeCommand"] = execute_command,
}

function M.server(dispatchers)
  local closing, id = false, 0
  local function exit()
    if not closing then
      closing = true
      dispatchers.on_exit(0, 0)
    end
  end
  return {
    request = function(method, params, callback, notify_reply)
      if closing then
        return false
      end
      id = id + 1
      local handler = handlers[method]
      local ok, result = pcall(handler or function()
        error("unsupported method: " .. method, 0)
      end, params)
      if notify_reply then
        notify_reply(id)
      end
      if ok then
        callback(nil, result, id)
      else
        local code = handler and "InternalError" or "MethodNotFound"
        callback(vim.lsp.rpc.rpc_response_error(vim.lsp.protocol.ErrorCodes[code], tostring(result)), nil, id)
      end
      return true, id
    end,
    notify = function(method)
      if method == "exit" then
        exit()
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = exit,
  }
end

return M
