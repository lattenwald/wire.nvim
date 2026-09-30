local transport = require("wire.transport")
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local server

local function send(req, opts)
  local res
  local handle = transport.send(req, opts or {}, function(r)
    res = r
  end)
  vim.wait(5000, function()
    return res ~= nil
  end)
  return res, handle
end

local function header(entry, name)
  for _, kv in ipairs(entry.headers) do
    if kv[1]:lower() == name:lower() then
      return kv[2]
    end
  end
end

local T = MiniTest.new_set({
  hooks = H.server_hooks(function(s)
    server = s
  end),
})

T["the server receives the body bytes exactly"] = function()
  local body = "a\r\nb\n\255\254end\n"
  send({ method = "POST", url = server.url .. "/x", headers = {}, body = body })
  eq(vim.base64.decode(server.requests()[1].body), body)
end

T["argv holds no URL and no header value"] = function()
  local argv = transport.build({
    method = "GET",
    url = "http://127.0.0.1:1/secret-path",
    headers = { { name = "X-Secret", value = "hv-123" } },
  }, { body_file = "/b", out_file = "/o" })
  for _, a in ipairs(argv) do
    eq(a:find("secret-path", 1, true) or a:find("hv-123", 1, true), nil)
  end
end

T["brackets and braces in the URL are sent once, verbatim"] = function()
  send({ method = "POST", url = server.url .. "/g/{a,b}?f[0]=1", headers = {} })
  local reqs = server.requests()
  eq(#reqs, 1)
  eq(reqs[1].path, "/g/{a,b}?f[0]=1")
end

T["quotes, backslashes and # in a header value arrive exactly"] = function()
  send({ method = "GET", url = server.url .. "/x", headers = { { name = "X-A", value = 'q"u\\o #h' } } })
  eq(header(server.requests()[1], "X-A"), 'q"u\\o #h')
end

T["a line break in a header name, header value or URL sends nothing"] = function()
  local cases = {
    { url = server.url .. "/x", headers = { { name = "X-A\nB", value = "v" } } },
    { url = server.url .. "/x", headers = { { name = "X-A", value = "v\r\nX-B: 1" } } },
    { url = server.url .. "/x\n", headers = {} },
  }
  for _, c in ipairs(cases) do
    MiniTest.expect.error(function()
      transport.send({ method = "GET", url = c.url, headers = c.headers }, {}, function() end)
    end)
  end
  eq(server.requests(), {})
end

T["no implicit form Content-Type; an empty value removes curl's header"] = function()
  send({ method = "POST", url = server.url .. "/x", headers = { { name = "Accept", value = "" } }, body = "a=1" })
  local entry = server.requests()[1]
  eq(header(entry, "Content-Type"), nil)
  eq(header(entry, "Accept"), nil)
end

T["a 4xx body is kept"] = function()
  local res = send({ method = "GET", url = server.url .. "/status/404", headers = {} })
  eq(res.status, 404)
  eq(vim.json.decode(res.body).path, "/status/404")
end

T["HEAD completes although the server announces a body"] = function()
  local res = send({ method = "HEAD", url = server.url .. "/head10", headers = {} })
  eq(res and res.outcome, "ok")
end

T["cancel kills curl and yields cancelled"] = function()
  local res
  local handle = transport.send({ method = "GET", url = server.url .. "/hang", headers = {} }, {}, function(r)
    res = r
  end)
  vim.wait(5000, function()
    return #server.requests() == 1
  end)
  handle.cancel()
  vim.wait(5000, function()
    return res ~= nil
  end)
  eq(res and res.outcome, "cancelled")
  eq(vim.uv.kill(handle.pid, 0) == 0, false)
end

T["timeout gives a transport failure"] = function()
  local res = send({ method = "GET", url = server.url .. "/hang", headers = {} }, { timeout = 1 })
  eq(res and res.outcome, "transport_error")
end

return T
