local document = require("wire.document")
local env = require("wire.env")
local project = require("wire.project")
local template = require("wire.template")

local M = {}

local LINKS = {
  WireSeparator = "@markup.heading",
  WireComment = "@comment",
  WireVariable = "@variable",
  WireOperator = "@operator",
  WireValue = "@string",
  WireMethod = "@function.method",
  WireUrl = "@string.special.url",
  WireVersion = "@string.special",
  WireHeader = "@constant",
  WireHeaderValue = "@string",
  WirePlaceholder = "@variable",
  WireExpression = "Special",
  WireScriptMarker = "@punctuation.special",
  WirePath = "@string.special.path",
  WireError = "DiagnosticUnderlineError",
}

local BASE, INLINE, ERROR = 100, 110, 120

local ns = vim.api.nvim_create_namespace("wire.highlight")

local function first_nonblank(l, from)
  local c = l:find("%S", from)
  return c and c - 1
end

local function trimmed_end(l)
  return #(l:gsub("%s+$", ""))
end

function M.classify(lines, defaults)
  local doc = document.parse(lines)
  local spans, regions, taken = {}, {}, {}

  local function add(n, col, end_col, group, priority)
    if end_col > col then
      spans[#spans + 1] =
        { row = n - 1, col = col, end_row = n - 1, end_col = end_col, group = group, priority = priority }
    end
  end

  local function inline(n, from)
    local l = lines[n]
    local exprs, pos = {}, from + 1
    while true do
      local s = l:find("{%=", pos, true)
      if not s then
        break
      end
      local e = l:find("%}", s + 3, true)
      local stop = e and e + 1 or #l
      exprs[#exprs + 1] = { s, stop }
      add(n, s - 1, stop, "WireExpression", INLINE)
      pos = stop + 1
    end
    pos = from + 1
    while true do
      local s, e = l:find(template.PLACEHOLDER, pos)
      if not s then
        break
      end
      local inside = false
      for _, r in ipairs(exprs) do
        inside = inside or (s >= r[1] and s <= r[2])
      end
      if not inside then
        add(n, s - 1, e, "WirePlaceholder", INLINE)
      end
      pos = e + 1
    end
  end

  local function var(v)
    local l = lines[v.line]
    local eq = l:find("=", 1, true)
    add(v.line, 0, #l:match("^@[^%s=]*"), "WireVariable", BASE)
    add(v.line, eq - 1, eq, "WireOperator", BASE)
    local vs = first_nonblank(l, eq + 1)
    if vs then
      add(v.line, vs, trimmed_end(l), "WireValue", BASE)
    end
    inline(v.line, eq)
    taken[v.line] = true
  end

  local function script(s)
    for n = s.line, s.last do
      taken[n] = true
    end
    local l = lines[s.line]
    add(s.line, 0, 1, "WireScriptMarker", BASE)
    if s.kind == "file" then
      local ps = first_nonblank(l, 2)
      add(s.line, ps, trimmed_end(l), "WirePath", BASE)
      return
    end
    local open = l:find("{%", 1, true)
    add(s.line, open - 1, open + 1, "WireScriptMarker", BASE)
    local last = lines[s.last]
    local close = last:find("%%}%s*$")
    add(s.last, close - 1, close + 1, "WireScriptMarker", BASE)
    local text
    if s.line == s.last then
      text = l:sub(open + 2, close - 1)
    else
      local parts = { l:sub(open + 2) }
      for n = s.line + 1, s.last - 1 do
        parts[#parts + 1] = lines[n]
      end
      parts[#parts + 1] = last:sub(1, close - 1)
      text = table.concat(parts, "\n")
    end
    regions[#regions + 1] = { lang = "lua", row = s.line - 1, col = open + 1, text = text }
  end

  local function request(req)
    local l = lines[req.line]
    local m = #req.method
    add(req.line, 0, m, "WireMethod", BASE)
    local us, ue = first_nonblank(l, m + 1), trimmed_end(l)
    local vs = l:find("%s+HTTP/[%d.]+%s*$")
    if vs and req.last == req.line then
      add(req.line, first_nonblank(l, vs), ue, "WireVersion", BASE)
      ue = vs - 1
    end
    add(req.line, us, ue, "WireUrl", BASE)
    inline(req.line, m)
    for n = req.line, req.last do
      taken[n] = true
      if n > req.line then
        add(n, first_nonblank(lines[n], 1), trimmed_end(lines[n]), "WireUrl", BASE)
        inline(n, 0)
      end
    end
    for _, h in ipairs(req.headers) do
      local hl = lines[h.line]
      local colon = hl:find(":", #h.name + 1, true)
      add(h.line, 0, #h.name, "WireHeader", BASE)
      add(h.line, colon - 1, colon, "WireOperator", BASE)
      local hs = first_nonblank(hl, colon + 1)
      if hs then
        add(h.line, hs, trimmed_end(hl), "WireHeaderValue", BASE)
      end
      inline(h.line, colon)
      taken[h.line] = true
    end
    if req.body then
      local content_type
      for _, h in ipairs(template.merge_headers(defaults or {}, req.headers)) do
        if h.name:lower() == "content-type" then
          content_type = h.value
        end
      end
      local count = select(2, req.body:gsub("\n", "")) + 1
      for n = req.body_line, req.body_line + count - 1 do
        inline(n, 0)
        taken[n] = true
      end
      if content_type and (content_type:find("{{", 1, true) or content_type:find("{%=", 1, true)) then
        content_type = nil
      end
      if template.is_json(content_type, req.body) then
        regions[#regions + 1] = { lang = "json", row = req.body_line - 1, col = 0, text = req.body }
      end
    end
  end

  local function errors(owner)
    for _, e in ipairs(owner.errors) do
      add(e.line, 0, math.max(#lines[e.line], 1), "WireError", ERROR)
      taken[e.line] = true
    end
  end

  for _, v in ipairs(doc.preamble.vars) do
    var(v)
  end
  for _, s in ipairs(doc.preamble.imports) do
    script(s)
  end
  errors(doc.preamble)
  for _, sec in ipairs(doc.sections) do
    add(sec.line, 0, #lines[sec.line], "WireSeparator", BASE)
    taken[sec.line] = true
    for _, v in ipairs(sec.vars) do
      var(v)
    end
    for _, s in ipairs(sec.pre) do
      script(s)
    end
    for _, s in ipairs(sec.post) do
      script(s)
    end
    if sec.request then
      request(sec.request)
    end
    errors(sec)
  end
  for n, l in ipairs(lines) do
    if not taken[n] and document.is_comment(l) then
      add(n, 0, #l, "WireComment", BASE)
    end
  end
  return spans, regions
end

local function captures(lang, text)
  local out = {}
  local ok, added = pcall(vim.treesitter.language.add, lang)
  local query = ok and added and vim.treesitter.query.get(lang, "highlights")
  if query then
    local tree = vim.treesitter.get_string_parser(text, lang):parse()[1]
    for id, node, metadata in query:iter_captures(tree:root(), text) do
      local name = query.captures[id]
      if not (name:sub(1, 1) == "_" or name == "spell" or name == "nospell" or name == "conceal") then
        local sr, sc, er, ec = node:range()
        local priority = tonumber(metadata.priority or (metadata[id] and metadata[id].priority)) or BASE
        out[#out + 1] = { sr, sc, er, ec, "@" .. name .. "." .. lang, priority }
      end
    end
  end
  return out
end

function M.spans(lines, defaults, prev)
  prev = prev or {}
  local spans, regions = M.classify(lines, defaults)
  local used = {}
  for _, r in ipairs(regions) do
    local key = r.lang .. "\0" .. r.text
    used[key] = used[key] or prev[key] or captures(r.lang, r.text)
    for _, c in ipairs(used[key]) do
      spans[#spans + 1] = {
        row = r.row + c[1],
        col = c[2] + (c[1] == 0 and r.col or 0),
        end_row = r.row + c[3],
        end_col = c[4] + (c[3] == 0 and r.col or 0),
        group = c[5],
        priority = c[6],
      }
    end
  end
  return spans, used
end

local captured = {}

local function refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if vim.bo[buf].filetype ~= "http" then
    captured[buf] = nil
    return
  end
  local root = project.cached_project(buf)
  local defaults = root and env.cached_defaults(root)
  local spans
  spans, captured[buf] = M.spans(vim.api.nvim_buf_get_lines(buf, 0, -1, false), defaults, captured[buf])
  for _, s in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.row, s.col, {
      end_row = s.end_row,
      end_col = s.end_col,
      hl_group = s.group,
      priority = s.priority,
    })
  end
end

local attached = {}

function M.enable(buf)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.treesitter.highlighter.active[buf] then
      vim.treesitter.stop(buf)
    end
  end)
  if attached[buf] then
    return refresh(buf)
  end
  attached[buf] = true
  local pending = false
  local function schedule()
    if not pending then
      pending = true
      vim.schedule(function()
        pending = false
        refresh(buf)
      end)
    end
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = schedule,
    on_reload = schedule,
    on_detach = function()
      attached[buf], captured[buf] = nil, nil
    end,
  })
  refresh(buf)
end

function M.setup()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("wire.highlight", { clear = true }),
    pattern = "WireEnvChanged",
    callback = function(ev)
      for buf in pairs(attached) do
        if project.cached_project(buf) == ev.data.root then
          refresh(buf)
        end
      end
    end,
  })
end

return M
