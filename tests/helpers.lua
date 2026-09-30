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
  assert(
    vim.wait(5000, function()
      return port ~= nil
    end),
    "test server did not start"
  )
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

return H
