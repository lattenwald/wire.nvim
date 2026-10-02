local M = {}

local function notify(msg, level)
  vim.notify("wire: " .. msg, level or vim.log.levels.INFO)
end

local function busy()
  if require("wire.run").active then
    notify("a run is active", vim.log.levels.WARN)
    return true
  end
end

function M.setup(opts)
  require("wire.config").setup(opts)
  local project = require("wire.project")
  local highlight = require("wire.highlight")
  highlight.setup()
  local group = vim.api.nvim_create_augroup("wire", { clear = true })
  local env = require("wire.env")
  project.setup_auto_trust(group, function(path)
    local root = vim.fs.dirname(path)
    if path:match("%.env%.json$") and env.loaded(root) then
      local ok, envs, untrusted = pcall(env.load, root)
      if ok and #untrusted == 0 then
        env.remember(root, envs)
      end
    end
  end)
  local function attach(buf)
    if vim.bo[buf].filetype == "http" and vim.bo[buf].buftype == "" then
      project.refresh(buf)
      highlight.enable(buf)
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "http",
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      attach(buf)
    end
  end
  env.load_state()
end

local function hooks()
  local icons = require("wire.ui.icons")
  local response = require("wire.ui.response")
  return {
    started = function(res)
      res.icon = icons.running(res.buf, require("wire.run").mark_row(res))
    end,
    result = function(res)
      icons.done(res.buf, res.icon, res)
      response.push(res)
      response.show_result(res)
    end,
    finished = function() end,
  }
end

function M.send()
  local buf = vim.api.nvim_get_current_buf()
  require("wire.run").start(buf, "cursor", vim.api.nvim_win_get_cursor(0)[1], hooks())
end

function M.send_all()
  require("wire.run").start(vim.api.nvim_get_current_buf(), "all", nil, hooks())
end

function M.cancel()
  require("wire.run").cancel()
end

function M.open()
  require("wire.ui.response").open()
end

function M.yank()
  local buf = vim.api.nvim_get_current_buf()
  local ok, text = pcall(function()
    local req = require("wire.run").request_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    return require("wire.transport").yank_text(req)
  end)
  if not ok then
    return notify(require("wire.mask").apply(text), vim.log.levels.ERROR)
  end
  vim.fn.setreg(vim.v.register, text)
  notify("curl command yanked (unmasked)")
end

function M.reset()
  if busy() then
    return
  end
  require("wire.context").clear_script_vars(vim.api.nvim_get_current_buf())
  notify("script variables cleared")
end

function M.select_env()
  if busy() then
    return
  end
  local env = require("wire.env")
  local _, root = require("wire.project").refresh(vim.api.nvim_get_current_buf())
  if not root then
    return notify("no project directory (http-client.lua or http-client*.env.json)", vim.log.levels.WARN)
  end
  local ok, envs, untrusted = pcall(env.load, root)
  if not ok then
    return notify(envs, vim.log.levels.ERROR)
  end
  if #untrusted > 0 then
    return notify("not trusted: " .. table.concat(untrusted, ", "), vim.log.levels.ERROR)
  end
  if #envs.names == 0 then
    return notify("no environments", vim.log.levels.WARN)
  end
  local current = env.current(root, envs.names)
  vim.ui.select(envs.names, {
    prompt = "wire environment",
    format_item = function(name)
      return name == current and (name .. "  ●") or name
    end,
  }, function(choice)
    if choice and choice ~= current then
      env.select(root, choice)
      env.remember(root, envs)
      require("wire.context").clear_project_vars(root)
    end
  end)
end

function M.scratchpad()
  local cwd = vim.fn.getcwd()
  local path = vim.fn.stdpath("data") .. "/wire/scratchpad.http"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].wire_scratch = true
  vim.b[buf].wire_base_dir = cwd
  require("wire.project").refresh(buf)
end

function M.env()
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].wire_response then
    return vim.b[buf].wire_env
  end
  local root = require("wire.project").cached_project(buf)
  return root and require("wire.env").cached_name(root) or nil
end

function M.ctx()
  return require("wire.context").api()
end

M.subcommands = {
  send = M.send,
  all = M.send_all,
  cancel = M.cancel,
  open = M.open,
  env = M.select_env,
  scratch = M.scratchpad,
  reset = M.reset,
  yank = M.yank,
}

function M.command(args)
  local name = args.fargs[1] or "send"
  local fn = M.subcommands[name]
  if not fn then
    return notify("unknown subcommand: " .. name, vim.log.levels.ERROR)
  end
  fn()
end

return M
