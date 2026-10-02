local config = require("wire.config")
local context = require("wire.context")
local document = require("wire.document")
local env = require("wire.env")
local helpers = require("wire.helpers")
local mask = require("wire.mask")
local project = require("wire.project")
local script = require("wire.script")
local template = require("wire.template")
local transport = require("wire.transport")

local M = {}

M.ns = vim.api.nvim_create_namespace("wire.marks")
M.active = nil

local run_seq = 0

local function vars_map(list)
  local m = {}
  for _, v in ipairs(list) do
    m[v.name] = v.value
  end
  return m
end

function M.mark_row(res)
  if vim.api.nvim_buf_is_valid(res.buf) then
    return vim.api.nvim_buf_get_extmark_by_id(res.buf, M.ns, res.mark, {})[1]
  end
end

function M.forget(buf, mark)
  if mark and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_del_extmark(buf, M.ns, mark)
  end
end

function M.response_head(r)
  local names = vim.tbl_keys(r.headers)
  table.sort(names)
  local out = { "HTTP " .. r.status }
  for _, n in ipairs(names) do
    out[#out + 1] = n .. ": " .. r.headers[n]
  end
  return out
end

local function hook(run, name, arg)
  local ok, err = pcall(run.hooks[name], arg)
  if not ok then
    vim.notify(("wire: %s hook: %s"):format(name, err), vim.log.levels.ERROR)
  end
end

local function first_line(s)
  return (s:match("^[^\n]*"))
end

local function snapshot(buf, which, row)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  local doc = document.parse(lines)
  local checked
  if which == "all" then
    checked = doc.sections
  else
    local sec = document.section_at(doc, row)
    if not sec then
      error("no request at the cursor", 0)
    end
    checked = { sec }
  end
  local errs = {}
  for _, owner in ipairs(vim.list_extend({ doc.preamble }, checked)) do
    for _, e in ipairs(owner.errors) do
      errs[#errs + 1] = ("%s:%d: %s"):format(file, e.line, e.msg)
    end
  end
  if #errs > 0 then
    error(table.concat(errs, "\n"), 0)
  end
  local sections = vim.tbl_filter(function(s)
    return s.request ~= nil
  end, checked)
  if #sections == 0 then
    error("nothing to send", 0)
  end

  local base, root = project.refresh(buf)
  local read_import = vim.b[buf].wire_scratch and project.read_trusted or project.read_file
  local envs, untrusted = env.load(root)
  local env_name = root and env.current(root, envs.names)
  if root and #untrusted == 0 then
    env.remember(root, envs)
  end
  local hs, untrusted_helpers = helpers.load_all({
    global = config.options.helpers,
    root = root,
    imports = doc.preamble.imports,
    base_dir = base,
    file = file,
    read_import = read_import,
  })
  vim.list_extend(untrusted, untrusted_helpers)
  if #untrusted > 0 then
    error(
      "not trusted: :trust each file in the window Neovim opened"
        .. " (or :trust ++remove <file> if denied), then send again\n  "
        .. table.concat(untrusted, "\n  "),
      0
    )
  end
  local compiled = {}
  for _, sec in ipairs(sections) do
    compiled[sec] = { pre = {}, post = {} }
    for _, kind in ipairs({ "pre", "post" }) do
      for _, sc in ipairs(sec[kind]) do
        table.insert(compiled[sec][kind], { fn = script.compile(sc, base, file, read_import), name = script.name(sc) })
      end
    end
  end
  local e = env_name and envs.envs[env_name] or {}
  return {
    buf = buf,
    file = file,
    sections = sections,
    base_dir = base,
    env_unselected = env_name == nil and #envs.names > 0,
    env_warnings = envs.warnings,
    env_name = env_name,
    env_label = env_name or (root and "none" or "no project"),
    env_vars = e.vars or {},
    env_private = e.private or {},
    default_headers = e.default_headers or {},
    private_headers = e.private_headers or {},
    doc_vars = vars_map(doc.preamble.vars),
    helpers = hs,
    compiled = compiled,
  }
end

local function prepare(ctx, snap, sec)
  local req = sec.request
  local where = ("%s:%d"):format(snap.file, req.line)
  local url = ctx:render(req.url, { where = where })
  local headers, content_type = {}, nil
  for _, h in ipairs(template.merge_headers(snap.default_headers, req.headers)) do
    local value = ctx:render(h.value, { where = where })
    headers[#headers + 1] = { name = h.name, value = value }
    mask.register_header(h.name, value)
    if h.default and snap.private_headers[h.name] then
      mask.register(value)
    end
    if h.name:lower() == "content-type" then
      content_type = value
    end
  end
  local body
  if req.body then
    body = ctx:render(req.body, { json = template.is_json(content_type, req.body), where = where })
  end
  return { name = sec.name, method = req.method, url = url, headers = headers, body = body }
end

local function ms(s)
  return ("%8.1f ms"):format(s * 1000)
end

local function server_lines(server, waiting)
  local l = { ("%-20s %11s"):format("Server-Timing", "duration") }
  local longest
  for _, e in ipairs(server) do
    local row = ("  %-18s %s"):format(e.name, e.duration and ms(e.duration) or (" "):rep(11))
    l[#l + 1] = (row .. "  " .. (e.desc or "")):gsub("%s+$", "")
    if e.duration and (not longest or e.duration > longest.duration) then
      longest = e
    end
  end
  if longest and waiting then
    l[#l + 1] = ("  %-18s %s"):format("Waiting - " .. longest.name, ms(waiting - longest.duration))
  end
  return l
end

local function timing_lines(t)
  -- curl counts a 100 Continue as the first byte; with Expect the real reply follows the upload
  local early = t.request_sent and t.first_byte > 0 and t.first_byte < t.request_sent
  local exchange = early
      and {
        { "First byte", t.first_byte },
        { "Send request", t.request_sent },
        { "Waiting, download", t.total, "waiting" },
      }
    or {
      { "Send request", t.request_sent },
      { "Waiting (TTFB)", t.first_byte, "waiting" },
      { t.first_byte > 0 and "Download" or "Until error", t.total },
    }
  local marks = { { "DNS lookup", t.dns }, { "TCP connect", t.connect }, { "TLS handshake", t.tls } }
  vim.list_extend(marks, exchange)
  vim.list_extend(marks, { { "curl start, exit", t.exited }, { "Neovim loop", t.wall } })
  local l = { ("%-20s %11s %11s"):format("Timing", "phase", "elapsed") }
  local prev, waiting = 0, nil
  for _, m in ipairs(marks) do
    if m[2] and m[2] > 0 then
      local at = math.max(prev, m[2])
      l[#l + 1] = ("  %-18s %s %s"):format(m[1], ms(at - prev), ms(at))
      if m[3] == "waiting" then
        waiting = at - prev
      end
      prev = at
    end
  end
  if early then
    l[#l + 1] = "  (the first byte came before the upload ended: a 100 Continue or an early reply)"
  end
  if #t.server > 0 then
    vim.list_extend(l, server_lines(t.server, waiting))
  end
  if t.remote then
    local http = t.http_version ~= "0" and ("  HTTP/" .. t.http_version) or ""
    l[#l + 1] = ("Connection: %s%s"):format(t.remote, http)
  end
  l[#l + 1] = ("Bytes: %d sent, %d received"):format(t.bytes_sent, t.bytes_received)
  return l
end

local function verbose_text(res)
  local l = {}
  local q = res.request
  if q then
    l[#l + 1] = q.method .. " " .. q.url
    for _, h in ipairs(q.headers) do
      l[#l + 1] = h.name .. ": " .. h.value
    end
    if q.body then
      l[#l + 1] = ""
      l[#l + 1] = q.body
    end
  end
  local r = res.response
  if r then
    l[#l + 1] = ""
    vim.list_extend(l, M.response_head(r))
  end
  if res.error then
    l[#l + 1] = ""
    l[#l + 1] = "Error: " .. res.error
  end
  if res.timing then
    l[#l + 1] = ""
    vim.list_extend(l, timing_lines(res.timing))
  end
  return table.concat(l, "\n")
end

local function summary_lines(res, line)
  local status
  if res.outcome == "ok" then
    status = ("Code: %d  Duration: %.2f s"):format(res.response.status, res.response.time)
  else
    status = "Error: " .. first_line(res.error or res.outcome)
  end
  local asserts = "none"
  if #res.tests > 0 then
    asserts = vim.iter(res.tests):all(function(t)
      return t.ok
    end) and "passed" or "failed"
  end
  local url = res.request and (res.request.method .. " " .. res.request.url) or ""
  local position = res.total > 1 and ("Request: %d/%d  "):format(res.index, res.total) or ""
  return {
    mask.apply(("%s%s  Time: %s"):format(position, status, os.date("%b %d %H:%M:%S", res.time))),
    mask.apply(("URL: %s  Env: %s  Assert: %s"):format(url, res.env, asserts)),
    mask.apply(("Buffer: %s::%d  Name: %s"):format(res.file, line, res.section_name)),
  }
end

local function mark_line(res)
  return (M.mark_row(res) or 0) + 1
end

local qf_id

local function set_quickfix(run)
  local items = {}
  for _, r in ipairs(run.results) do
    if r.failed then
      local why = r.error
      if not why then
        local names = {}
        for _, t in ipairs(r.tests) do
          if not t.ok then
            names[#names + 1] = t.name
          end
        end
        why = "failed: " .. table.concat(names, ", ")
      end
      items[#items + 1] = { bufnr = r.buf, lnum = mark_line(r), text = r.section_name .. ": " .. first_line(why) }
    end
  end
  if qf_id and vim.fn.getqflist({ id = qf_id }).id == qf_id then
    vim.fn.setqflist({}, "r", { id = qf_id, items = items, title = "wire" })
  else
    vim.fn.setqflist({}, " ", { items = items, title = "wire" })
    qf_id = vim.fn.getqflist({ id = 0 }).id
  end
end

local function finish(run)
  M.active = nil
  for i = #run.results + 1, #run.snap.sections do
    M.forget(run.snap.buf, run.marks[run.snap.sections[i]])
  end
  local passed, failed, aborted = 0, 0, 0
  for _, r in ipairs(run.results) do
    if r.outcome == "aborted" then
      aborted = aborted + 1
    elseif r.failed then
      failed = failed + 1
    else
      passed = passed + 1
    end
  end
  local parts = { (passed + failed) .. " sent", passed .. " ✓", failed .. " ✗" }
  if aborted > 0 then
    parts[#parts + 1] = aborted .. " aborted"
  end
  local not_run = #run.snap.sections - #run.results
  if not_run > 0 then
    parts[#parts + 1] = not_run .. " not run"
  end
  local bad = failed + aborted > 0
  vim.notify("wire: " .. table.concat(parts, " · "), bad and vim.log.levels.WARN or vim.log.levels.INFO)
  set_quickfix(run)
  hook(run, "finished", run)
end

local step

local function record(run, res, stop)
  local ctx = run.ctx
  res.logs = mask.apply(table.concat(ctx.logs, "\n"))
  if res.error then
    res.error = mask.apply(res.error)
  end
  for _, t in ipairs(res.tests) do
    for i, m in ipairs(t.messages) do
      t.messages[i] = mask.apply(m)
    end
  end
  res.failed = res.outcome ~= "ok" or vim.iter(res.tests):any(function(t)
    return not t.ok
  end)
  res.verbose = mask.apply(verbose_text(res))
  res.summary = summary_lines(res, mark_line(res))
  table.insert(run.results, res)
  hook(run, "result", res)
  if stop then
    run.stopped = true
  end
  step(run)
end

local function post(run, sec, res)
  local ctx, r = run.ctx, res.response
  local req_headers = {}
  for _, h in ipairs(res.request.headers) do
    req_headers[h.name:lower()] = h.value
  end
  ctx.api.request = vim.tbl_extend("force", res.request, { headers = req_headers })
  local decoded
  ctx.api.response = setmetatable({
    status = r.status,
    headers = r.headers,
    body = r.body,
    timing = vim.deepcopy(res.timing),
  }, {
    __index = function(_, k)
      if k == "json" then
        if not decoded then
          local ok, json = pcall(vim.json.decode, r.body, { luanil = { object = true, array = true } })
          decoded = { ok and json or nil }
        end
        return decoded[1]
      end
    end,
  })
  ctx.api.test = function(name, fn)
    script.run_test(res.tests, name, fn)
  end
  for _, s in ipairs(run.snap.compiled[sec].post) do
    local done, err = pcall(ctx.call, ctx, s.fn)
    if not done then
      table.insert(res.tests, { name = s.name, ok = false, messages = { err }, script_error = true })
    end
  end
  ctx.api.request, ctx.api.response, ctx.api.test = nil, nil, nil
end

step = function(run)
  run.index = run.index + 1
  local snap = run.snap
  local sec = snap.sections[run.index]
  if not sec or run.stopped then
    return finish(run)
  end
  local ctx = run.ctx
  local res = {
    run = run.id,
    index = run.index,
    total = #snap.sections,
    section_name = sec.name,
    buf = snap.buf,
    mark = run.marks[sec],
    file = snap.file,
    env = snap.env_label,
    env_name = snap.env_name,
    tests = {},
    time = os.time(),
  }
  hook(run, "started", res)
  ctx:begin_section(vars_map(sec.vars))
  local ok, req = pcall(function()
    for _, s in ipairs(snap.compiled[sec].pre) do
      ctx:call(s.fn)
    end
    return prepare(ctx, snap, sec)
  end)
  if not ok then
    res.outcome, res.error = "aborted", req
    return record(run, res, true)
  end
  res.request = req
  local sent, handle = pcall(transport.send, req, { timeout = config.options.timeout }, function(r)
    run.handle = nil
    res.timing = r.timing
    if r.outcome ~= "ok" then
      res.outcome, res.error = r.outcome, r.error or r.outcome
      return record(run, res, true)
    end
    res.outcome = "ok"
    res.response = { status = r.status, headers = r.headers, body = r.body, time = r.timing.total }
    post(run, sec, res)
    record(run, res, false)
  end)
  if not sent then
    res.outcome, res.error = "aborted", handle
    return record(run, res, true)
  end
  run.handle = handle
end

local function new_context(snap, script_vars)
  return context.new({
    doc_vars = snap.doc_vars,
    env_unselected = snap.env_unselected,
    env_vars = snap.env_vars,
    env_private = snap.env_private,
    script_vars = script_vars,
    helpers = snap.helpers,
    base_dir = snap.base_dir,
  })
end

function M.request_at(buf, row)
  local snap = snapshot(buf, "cursor", row)
  local sec = snap.sections[1]
  local ctx = new_context(snap, vim.deepcopy(context.script_vars(buf)))
  ctx:begin_section(vars_map(sec.vars))
  for _, s in ipairs(snap.compiled[sec].pre) do
    ctx:call(s.fn)
  end
  return prepare(ctx, snap, sec)
end

function M.start(buf, which, row, hooks)
  if M.active then
    vim.notify("wire: a run is already active", vim.log.levels.WARN)
    return
  end
  local ok, snap = pcall(snapshot, buf, which, row)
  if not ok then
    vim.notify("wire: " .. mask.apply(snap), vim.log.levels.ERROR)
    return
  end
  if #snap.env_warnings > 0 then
    local lines = vim.tbl_map(function(w)
      return "wire: " .. w .. " (ignored)"
    end, snap.env_warnings)
    lines[#lines + 1] = "see :help wire-environments"
    vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  end
  run_seq = run_seq + 1
  local run = { id = run_seq, snap = snap, results = {}, index = 0, hooks = hooks, marks = {} }
  for _, sec in ipairs(snap.sections) do
    run.marks[sec] = vim.api.nvim_buf_set_extmark(buf, M.ns, sec.line - 1, 0, {})
  end
  run.ctx = new_context(snap, context.script_vars(buf))
  M.active = run
  step(run)
  return run
end

function M.cancel()
  local run = M.active
  if not run then
    return
  end
  run.stopped = true
  if run.handle then
    run.handle.cancel()
  end
end

return M
