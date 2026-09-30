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

local function parse(req, r, out_file)
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or "")
    return { outcome = "transport_error", error = err ~= "" and err or ("curl exited with " .. r.code) }
  end
  local nl = r.stdout:find("\n", 1, true)
  local ok, info = pcall(vim.json.decode, r.stdout:sub(1, (nl or 0) - 1))
  local ok2, raw = pcall(vim.json.decode, nl and r.stdout:sub(nl + 1) or "")
  if not (ok and ok2) then
    return { outcome = "transport_error", error = "unexpected curl output: " .. r.stdout }
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
  return { outcome = "ok", status = info.response_code, headers = headers, body = body, time = info.time_total }
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
  local proc = vim.system(argv, { stdin = cfg, text = false }, function(r)
    vim.schedule(function()
      local res = cancelled and { outcome = "cancelled" } or parse(req, r, out_file)
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
