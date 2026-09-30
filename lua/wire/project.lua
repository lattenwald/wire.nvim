local M = {}

M.markers = { "http-client.lua", "http-client.env.json", "http-client.private.env.json" }

local function under(path, dir)
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

function M.find_root(base_dir)
  -- nested list = equal priority; a flat list prefers earlier markers over nearer dirs
  local root = vim.fs.root(base_dir, { M.markers })
  local home = vim.uv.os_homedir()
  if root and home and under(base_dir, home) and not under(root, home) then
    return nil
  end
  return root
end

local function buf_base_dir(buf)
  local base = vim.b[buf].wire_base_dir
  if base then
    return base
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name == "" and vim.fn.getcwd() or vim.fs.dirname(name)
end

function M.refresh(buf)
  local base = buf_base_dir(buf)
  local root = M.find_root(base)
  vim.b[buf].wire_project_dir = root or false
  return base, root
end

function M.cached_project(buf)
  return vim.b[buf].wire_project_dir or nil
end

function M.resolve(base_dir, path)
  local first = path:sub(1, 1)
  if first ~= "/" and first ~= "~" then
    path = base_dir .. "/" .. path
  end
  return vim.fs.normalize(path)
end

function M.read_trusted(path)
  if not vim.uv.fs_stat(path) then
    return nil, "missing"
  end
  local content = vim.secure.read(path)
  if type(content) ~= "string" then
    return nil, "untrusted"
  end
  return content
end

function M.setup_auto_trust(group, on_trusted)
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "http-client.lua", "http-client*.env.json" },
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      vim.secure.trust({ action = "allow", path = path })
      if on_trusted then
        on_trusted(path)
      end
    end,
  })
end

return M
