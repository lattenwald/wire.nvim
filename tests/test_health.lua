local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["checkhealth reports a curl older than 7.83 as an error"] = function()
  local done = false
  -- :checkhealth sets it when done, asynchronously since Neovim 0.13
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "checkhealth",
    once = true,
    callback = function()
      done = true
    end,
  })
  H.with_bin("curl", "echo 'curl 7.81.0 (x86_64-pc-linux-gnu)'", function()
    vim.cmd("checkhealth wire")
    vim.wait(5000, function()
      return done
    end)
  end)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(text:find("ERROR curl 7.81.0 is older than 7.83", 1, true) ~= nil, true)
end

return T
