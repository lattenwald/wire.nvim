local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/deps/mini.test")
vim.opt.swapfile = false
vim.notify = function() end

require("mini.test").setup()

function _G.wire_test_run(file)
  local opts = { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }) } }
  local ok, err = pcall(function()
    if file ~= "" then
      MiniTest.run_file(file, opts)
    else
      MiniTest.run(opts)
    end
  end)
  if not ok then
    io.write(tostring(err) .. "\n")
    vim.cmd("cquit! 1")
  end
end
