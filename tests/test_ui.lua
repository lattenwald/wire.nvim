local H = require("tests.helpers")
local response = require("wire.ui.response")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T[":Wire completes subcommands in a stable order"] = function()
  vim.cmd("runtime plugin/wire.lua")
  eq(vim.fn.getcompletion("Wire ", "cmdline"), { "all", "cancel", "env", "open", "reset", "scratch", "send" })
end

T["a result leaving the history takes its ### mark with it"] = function()
  local run = require("wire.run")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### a" })
  for _ = 1, 60 do
    response.push({ buf = buf, mark = vim.api.nvim_buf_set_extmark(buf, run.ns, 0, 0, {}) })
  end
  eq(#vim.api.nvim_buf_get_extmarks(buf, run.ns, 0, -1, {}), 50)
end

T["JSON is pretty-printed only by jq 1.7 or later"] = function()
  local body = '{"id": 1234567890123456789}'
  for _, case in ipairs({ { "1.6", body }, { "1.7.1", "PRETTY" } }) do
    H.with_bin("jq", ('[ "$1" = --version ] && echo jq-%s || echo PRETTY'):format(case[1]), function()
      local res = {
        outcome = "ok",
        tests = {},
        summary = { "", "", "" },
        response = { status = 200, headers = { ["content-type"] = "application/json" }, body = body, time = 0 },
      }
      response.push(res)
      response.open()
      vim.wait(2000, function()
        return res.pretty ~= nil
      end)
      eq(vim.api.nvim_buf_get_lines(vim.fn.bufnr("wire://response"), 0, 1, false)[1], case[2])
    end)
  end
end

T["] on the newest result does not redraw"] = function()
  response.push({
    outcome = "ok",
    tests = {},
    summary = { "", "", "" },
    response = { status = 200, headers = {}, body = "x", time = 0 },
  })
  response.open()
  local buf = vim.fn.bufnr("wire://response")
  local tick = vim.b[buf].changedtick
  response.next()
  eq(vim.b[buf].changedtick, tick)
end

T["env() in the response window is the viewed result's environment"] = function()
  local root = H.tmpdir()
  H.trust(H.write(root .. "/http-client.env.json", [[{ "dev": {} }]]))
  -- port 9 (discard) refuses connections
  local a = H.http_buf(root .. "/r.http", { "### one", "GET http://127.0.0.1:9/one" })
  local b = H.http_buf(H.tmpdir() .. "/r.http", { "### two", "GET http://127.0.0.1:9/two" })
  for _, buf in ipairs({ a, b }) do
    response.push(H.run(buf, "all")[1])
  end
  response.open()
  vim.api.nvim_set_current_win(vim.fn.bufwinid("wire://response"))
  local seen = { require("wire").env() }
  response.prev()
  seen[2] = require("wire").env()
  response.next()
  seen[3] = require("wire").env()
  eq(seen, { nil, "dev", nil })
end

return T
