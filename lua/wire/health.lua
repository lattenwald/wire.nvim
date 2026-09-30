local project = require("wire.project")
local tools = require("wire.tools")

local M = {}

function M.check()
  local h = vim.health
  h.start("wire")
  local curl = tools.version("curl")
  curl = curl and tostring(curl)
  if not curl then
    h.error("curl not found")
  elseif tools.usable("curl") then
    h.ok("curl " .. curl)
  else
    h.error(("curl %s is older than %s: every send fails"):format(curl, tools.min.curl))
  end
  local jq = tools.version("jq")
  jq = jq and tostring(jq)
  if not jq then
    h.warn("jq not found: JSON bodies are shown as received")
  elseif tools.usable("jq") then
    h.ok("jq " .. jq)
  else
    h.warn(
      ("jq %s is older than %s, which rounds large integers: JSON bodies are shown as received"):format(
        jq,
        tools.min.jq
      )
    )
  end
  if vim.treesitter.language.add("json") then
    h.ok("json tree-sitter parser found")
  else
    h.warn("json tree-sitter parser not found: JSON bodies are not highlighted")
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "http" then
    return
  end
  local base, root = project.refresh(buf)
  h.info("base directory: " .. base)
  if not root then
    return h.info("no project directory")
  end
  local found = vim.tbl_filter(function(f)
    return vim.uv.fs_stat(root .. "/" .. f) ~= nil
  end, project.markers)
  h.info(("project directory: %s (%s)"):format(root, table.concat(found, ", ")))
end

return M
