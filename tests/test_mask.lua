local mask = require("wire.mask")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["a secret inside a longer string is masked"] = function()
  mask.register("s3cr3t-token-a1")
  eq(mask.apply("Authorization: Bearer s3cr3t-token-a1\n"), "Authorization: Bearer ••••\n")
end

T["the JSON-escaped form is masked, matched as plain text"] = function()
  mask.register('p%a"s\\s\n-w+rd')
  eq(mask.apply('{"pw": "p%a\\"s\\\\s\\n-w+rd"}'), '{"pw": "••••"}')
end

T["longer values are replaced first"] = function()
  mask.register("abcd")
  mask.register("abcdefgh-longer")
  eq(mask.apply("x abcdefgh-longer y"), "x •••• y")
end

T["the credential after the auth scheme is masked on its own"] = function()
  mask.register_header("Authorization", "Bearer tk-abcdef-123")
  eq(mask.apply("token=tk-abcdef-123"), "token=••••")
end

return T
