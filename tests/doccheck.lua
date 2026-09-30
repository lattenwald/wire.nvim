local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile(vim.fn.readfile("doc/wire.txt"), tmp .. "/wire.txt")
vim.cmd.helptags(tmp)
local problems = {}
if not vim.deep_equal(vim.fn.readfile(tmp .. "/tags"), vim.fn.readfile("doc/tags")) then
  problems[#problems + 1] = "doc/tags is stale: run make doc"
end
for n, line in ipairs(vim.fn.readfile("doc/wire.txt")) do
  for tag in line:gmatch("|([^|%s]+)|") do
    if not pcall(vim.cmd.help, tag) then
      problems[#problems + 1] = ("doc/wire.txt:%d: unknown tag |%s|"):format(n, tag)
    end
  end
end
if #problems > 0 then
  io.write(table.concat(problems, "\n") .. "\n")
  os.exit(1)
end
