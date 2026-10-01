local config = require("wire.config")
local mask = require("wire.mask")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.setup({})
    end,
  },
})

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

T["a header set to false in mask.headers is shown; other auto headers stay masked"] = function()
  config.setup({ mask = { headers = { Cookie = false } } })
  mask.register_header("Cookie", "sid=ck-shown-1")
  mask.register_header("X-Api-Key", "ak-hidden-1")
  eq(mask.apply("sid=ck-shown-1 ak-hidden-1"), "sid=ck-shown-1 ••••")
end

T["a header added to mask.headers is masked"] = function()
  config.setup({ mask = { headers = { ["X-Auth-Token"] = true } } })
  mask.register_header("x-auth-token", "xa-hidden-1")
  eq(mask.apply("xa-hidden-1"), "••••")
end

T["mask = true keeps the default masking"] = function()
  config.setup({ mask = true })
  mask.register_header("Cookie", "sid=mt-hidden-1")
  eq(mask.apply("sid=mt-hidden-1"), "••••")
end

T["a mask option of the wrong shape fails setup"] = function()
  for _, m in ipairs({ "yes", { headers = false }, { headers = { cookie = "no" } } }) do
    MiniTest.expect.error(function()
      config.setup({ mask = m })
    end)
  end
end

T["mask = false masks nothing, registered secrets included"] = function()
  config.setup({ mask = false })
  mask.register("sv-shown-1")
  mask.register_header("Authorization", "Bearer au-shown-1")
  eq(mask.apply("sv-shown-1 Bearer au-shown-1"), "sv-shown-1 Bearer au-shown-1")
end

return T
