local H = {}

function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

function H.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
  return path
end

function H.trust(path)
  assert(vim.secure.trust({ action = "allow", path = path }))
end

function H.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

function H.server()
  local log = vim.fn.tempname()
  H.write(log, "")
  local port
  local proc = vim.system({ "python3", "tests/server.py", log }, {
    stdout = function(_, data)
      port = port or (data and tonumber(data:match("%d+")))
    end,
  })
  local started = vim.wait(5000, function()
    return port ~= nil
  end)
  if not started then
    proc:kill(9)
    error("test server did not start")
  end
  local s = { url = "http://127.0.0.1:" .. port }
  function s.requests()
    local out = {}
    for line in io.lines(log) do
      out[#out + 1] = vim.json.decode(line)
    end
    return out
  end
  function s.clear()
    H.write(log, "")
  end
  function s.stop()
    proc:kill(9)
  end
  return s
end

function H.server_hooks(on_start)
  local s
  return {
    pre_once = function()
      s = H.server()
      on_start(s)
    end,
    pre_case = function()
      s.clear()
    end,
    post_once = function()
      s.stop()
    end,
  }
end

function H.with_bin(name, script, fn)
  local dir, path = H.tmpdir(), vim.env.PATH
  H.write(dir .. "/" .. name, "#!/bin/sh\n" .. script .. "\n")
  vim.uv.fs_chmod(dir .. "/" .. name, 493)
  vim.env.PATH = dir .. ":" .. path
  local ok, err = pcall(fn)
  vim.env.PATH = path
  if not ok then
    error(err, 0)
  end
end

function H.ctx(opts)
  opts.script_vars = opts.script_vars or {}
  return require("wire.context").new(opts)
end

function H.http_buf(path, lines)
  H.write(path, table.concat(lines, "\n") .. "\n")
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

function H.run(buf, which, row, hooks)
  local results, done = {}, false
  local run = require("wire.run").start(
    buf,
    which,
    row,
    vim.tbl_extend("force", {
      started = function() end,
      result = function(r)
        table.insert(results, r)
      end,
      finished = function()
        done = true
      end,
    }, hooks or {})
  )
  if run then
    vim.wait(10000, function()
      return done
    end)
  end
  return results, done
end

return H
