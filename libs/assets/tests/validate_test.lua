-- Validate: the shared pure predicates the generated-cache readiness
-- validators use. isArray pins the LuaWriter array shape (contiguous 1-based
-- keys) that every current cache schema requires; isNonNegativeInteger pins
-- the sprite/bank id domain.

local Assert = require("tests.support.Assert")
local Validate = require("libs.assets.src.Validate")

local T = {}

function T.is_array_accepts_contiguous_sequences()
  Assert.isTrue(Validate.isArray({}))
  Assert.isTrue(Validate.isArray({ 1 }))
  Assert.isTrue(Validate.isArray({ "a", "b", "c" }))
end

function T.is_array_rejects_holey_sequences()
  Assert.isFalse(Validate.isArray({ 1, 2, nil, 4 }), "a missing interior index is not the LuaWriter shape")
  Assert.isFalse(Validate.isArray({ [1] = "a", [3] = "c" }))
end

function T.is_array_rejects_non_1_based_tables()
  Assert.isFalse(Validate.isArray({ [0] = "a", [1] = "b" }), "zero-based tables are not arrays")
  Assert.isFalse(Validate.isArray({ [1] = "a", [1.5] = "b" }), "fractional keys are not array indices")
end

function T.is_array_rejects_hash_tables_and_non_tables()
  Assert.isFalse(Validate.isArray({ named = 1 }))
  Assert.isFalse(Validate.isArray("str"))
  Assert.isFalse(Validate.isArray(5))
  Assert.isFalse(Validate.isArray(nil))
end

function T.is_non_negative_integer_pins_the_id_domain()
  Assert.isTrue(Validate.isNonNegativeInteger(0))
  Assert.isTrue(Validate.isNonNegativeInteger(29))
  Assert.isFalse(Validate.isNonNegativeInteger(-1))
  Assert.isFalse(Validate.isNonNegativeInteger(0.5))
  Assert.isFalse(Validate.isNonNegativeInteger("5"))
  Assert.isFalse(Validate.isNonNegativeInteger(0 / 0))
end

return { tests = T }
