-- Hashing: a known SHA-1 vector (validates hex encoding) and key-order
-- independence of hashLua (via LuaWriter's sorted-key serialization).

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}

function T.sha1_of_abc_is_known_vector()
  Assert.equal(Hashing.sha1hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
end

function T.sha1_of_empty_is_known_vector()
  Assert.equal(Hashing.sha1hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
end

function T.hashLua_is_order_independent_by_key()
  Assert.equal(Hashing.hashLua({ b = 2, a = 1 }), Hashing.hashLua({ a = 1, b = 2 }))
end

function T.hashLua_differs_on_different_content()
  Assert.isTrue(Hashing.hashLua({ a = 1 }) ~= Hashing.hashLua({ a = 2 }), "content-sensitive")
end

return T
