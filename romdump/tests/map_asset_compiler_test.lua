-- MapAssetCompiler: constant surface and module load sanity.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")

local T = {}

function T.exports_compiler_version()
  Assert.equal(MapAssetCompiler.COMPILER_VERSION, "map-compiler-v8")
end

function T.compile_requires_romfs_shaped_object()
  local err = Assert.throws(function() MapAssetCompiler.compile({}, "x") end)
  Assert.isTrue(tostring(err):find("RomFs") ~= nil, "error mentions RomFs")
end

return T
