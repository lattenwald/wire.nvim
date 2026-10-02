local M = {}

local function quote(s)
  local escaped = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "\\r")
  return '"' .. escaped .. '"'
end

local function check(what, s)
  if s:find("[\r\n]") then
    error(what .. " contains a line break", 0)
  end
end

local function has_body(req)
  return req.body ~= nil and req.body ~= ""
end

local function config_lines(req)
  check("URL", req.url)
  local cfg = { "url = " .. quote(req.url), "globoff" }
  if req.method == "HEAD" then
    if has_body(req) then
      error("a HEAD request cannot have a body", 0)
    end
    cfg[#cfg + 1] = "head"
  else
    cfg[#cfg + 1] = "request = " .. quote(req.method)
  end
  local has_ct = false
  for _, h in ipairs(req.headers) do
    check("header name", h.name)
    check("header value", h.value)
    if h.name:lower() == "content-type" then
      has_ct = true
    end
    local line = h.value == "" and (h.name .. ":") or (h.name .. ": " .. h.value)
    cfg[#cfg + 1] = "header = " .. quote(line)
  end
  if has_body(req) and not has_ct then
    cfg[#cfg + 1] = 'header = "Content-Type:"' -- drop curl's implicit form content type
  end
  return cfg
end

function M.build(req, opts)
  local cfg = config_lines(req)
  if has_body(req) then
    cfg[#cfg + 1] = "data-binary = " .. quote("@" .. opts.body_file)
  end
  local argv = {
    "curl",
    "-q",
    "-sS",
    "-K",
    "-",
    "--connect-timeout",
    "10",
    "-o",
    opts.out_file,
    "-w",
    "%{json}\\n%{header_json}",
  }
  if opts.timeout then
    vim.list_extend(argv, { "--max-time", tostring(opts.timeout) })
  end
  return argv, table.concat(cfg, "\n") .. "\n"
end

function M.yank_text(req)
  local cfg = config_lines(req)
  if has_body(req) then
    if req.body:find("%z") then
      cfg[#cfg + 1] = "# binary body omitted"
    else
      cfg[#cfg + 1] = "data-raw = " .. quote(req.body)
    end
  end
  return "curl -q -sS -K - <<'WIRE'\n" .. table.concat(cfg, "\n") .. "\nWIRE\n"
end

local function split_unquoted(s, sep)
  local parts, start, i, quoted = {}, 1, 1, false
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and quoted then
      i = i + 1
    elseif c == '"' then
      quoted = not quoted
    elseif c == sep and not quoted then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
    i = i + 1
  end
  parts[#parts + 1] = s:sub(start)
  return parts
end

-- https://www.w3.org/TR/server-timing/: `name;dur=<ms>;desc="text"`, comma-separated
local function server_timing(values)
  local out = {}
  for _, entry in ipairs(split_unquoted(table.concat(values or {}, ","), ",")) do
    local params = split_unquoted(entry, ";")
    local item = { name = vim.trim(params[1]) }
    for i = 2, #params do
      local k, v = params[i]:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
      k = k and k:lower()
      if v and v:match('^".*"$') then
        v = v:sub(2, -2):gsub("\\(.)", "%1")
      end
      if k == "dur" and not item.duration then
        local n = tonumber(v)
        item.duration = n and n / 1000
      elseif k == "desc" and not item.desc then
        item.desc = v
      end
    end
    if item.name ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

-- curl's marks are seconds from the transfer start; a mark not reached is 0
local function timing(info, raw)
  return {
    dns = info.time_namelookup,
    connect = info.time_connect,
    tls = info.time_appconnect,
    request_sent = info.time_posttransfer, -- curl >= 8.10
    first_byte = info.time_starttransfer,
    total = info.time_total,
    remote = info.remote_ip ~= ""
        and (info.remote_ip:find(":", 1, true) and "[%s]:%s" or "%s:%s"):format(info.remote_ip, info.remote_port)
      or nil,
    http_version = info.http_version,
    bytes_sent = info.size_request,
    bytes_received = info.size_header + info.size_download,
    server = server_timing(raw and raw["server-timing"]),
  }
end

local function parse(req, r, out_file)
  local nl = r.stdout:find("\n", 1, true)
  local ok, info = pcall(vim.json.decode, r.stdout:sub(1, (nl or 0) - 1))
  local ok2, raw = pcall(vim.json.decode, nl and r.stdout:sub(nl + 1) or "")
  local built, tm = pcall(timing, info, ok2 and raw or nil)
  if not (ok and built) then
    tm = nil
  end
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or "")
    return {
      outcome = "transport_error",
      error = err ~= "" and err or ("curl exited with " .. r.code),
      timing = tm,
    }
  end
  if not (ok and ok2) then
    return {
      outcome = "transport_error",
      error = ("unexpected curl output (curl >= %s is required, see :checkhealth wire): %s"):format(
        require("wire.tools").min.curl,
        r.stdout
      ),
    }
  end
  local headers = {}
  for k, v in pairs(raw) do
    headers[k] = type(v) == "table" and v[#v] or v
  end
  local body = ""
  if req.method ~= "HEAD" then -- with `head`, the -o file holds the header block
    local f = io.open(out_file, "rb")
    if f then
      body = f:read("*a")
      f:close()
    end
  end
  return {
    outcome = "ok",
    status = info.response_code,
    headers = headers,
    body = body,
    timing = tm,
  }
end

function M.send(req, opts, on_done)
  local body_file, out_file = vim.fn.tempname(), vim.fn.tempname()
  local argv, cfg = M.build(req, { timeout = opts.timeout, body_file = body_file, out_file = out_file })
  if has_body(req) then
    local f = assert(io.open(body_file, "wb"))
    f:write(req.body)
    f:close()
  end
  local cancelled = false
  local started = vim.uv.hrtime()
  local proc = vim.system(argv, { stdin = cfg, text = false }, function(r)
    local exited = vim.uv.hrtime()
    vim.schedule(function()
      local handled = vim.uv.hrtime()
      local res = cancelled and { outcome = "cancelled" } or parse(req, r, out_file)
      if res.timing then
        res.timing.exited = (exited - started) / 1e9
        res.timing.wall = (handled - started) / 1e9
      end
      os.remove(body_file)
      os.remove(out_file)
      on_done(res)
    end)
  end)
  return {
    pid = proc.pid,
    cancel = function()
      cancelled = true
      proc:kill("sigterm")
    end,
  }
end

return M
