local Assert = require("tests.support.Assert")
local BuildModelAnimList = require("libs.assets.src.BuildModelAnimList")

local T = {}

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- 0x18-byte record: 8-byte header, then u32 ids padded with 0xFFFFFFFF.
local function record(header, ids)
  local parts = { header }
  for _, id in ipairs(ids) do parts[#parts + 1] = u32(id) end
  local body = table.concat(parts)
  return body .. string.rep("\xFF", 0x18 - #body)
end

function T.decodes_single_referenced_resource()
  -- Mirrors New Bark model 28 "wind": one referenced resource (id 6).
  local r = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", { 6 }))
  Assert.equal(#r.ids, 1)
  Assert.equal(r.ids[1], 6)
end

function T.decodes_multiple_referenced_resources()
  -- Mirrors model 24 "wk_door1": two joint animations (ids 1 and 2).
  local r = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", { 1, 2 }))
  Assert.equal(#r.ids, 2)
  Assert.equal(r.ids[1], 1)
  Assert.equal(r.ids[2], 2)
end

function T.no_animation_record_yields_no_ids()
  -- Non-animated models start with the 0xFFFF sentinel; the id region is all
  -- 0xFFFFFFFF, so no resources are referenced.
  local r = BuildModelAnimList.decode(record("\xFF\xFF\0\0\0\0\0\0", {}))
  Assert.equal(#r.ids, 0)
end

function T.rejects_wrong_record_size()
  Assert.throws(function() BuildModelAnimList.decode("\0\0\0\0") end)
end

return T
