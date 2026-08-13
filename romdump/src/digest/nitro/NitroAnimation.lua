-- NitroAnimation: the shared entry point for the four NitroSystem 3D
-- animation formats used by Gen IV. NSBVA/BVA0 (VIS0 visibility animation)
-- is not a decoded format: the HGSS field archive has no VIS0 members and
-- no runtime consumer exists, so BVA0 bytes are an unknown file magic here.
--
-- Each animation resource file (BCA0/BTA0/BTP0/BMA0) contains one
-- section (JNT0/SRT0/PAT0/MAT0) whose dictionary maps animation names
-- to per-format records. This module decodes the file and dispatches to the
-- format decoder, returning one normalized shape:
--
--   { format = "NSBCA"|"NSBTA"|"NSBTP"|"NSBMA",
--     animations = { { name, recordOffset, resource } } }
--
-- where `resource` is the decoded record of the corresponding module
-- (Nsbca/Nsbta/Nsbtp/Nsbma) ready for sampling. The file magic and
-- section magic must agree; anything else is a structured error.
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local Nsbca = require("romdump.src.digest.nitro.Nsbca")
local Nsbta = require("romdump.src.digest.nitro.Nsbta")
local Nsbtp = require("romdump.src.digest.nitro.Nsbtp")
local Nsbma = require("romdump.src.digest.nitro.Nsbma")

local NitroAnimation = {}

-- file magic -> { format name, section magic, decoder module }
local FORMATS = {
  ["BCA0"] = { format = "NSBCA", section = "JNT0", decoder = Nsbca },
  ["BTA0"] = { format = "NSBTA", section = "SRT0", decoder = Nsbta },
  ["BTP0"] = { format = "NSBTP", section = "PAT0", decoder = Nsbtp },
  ["BMA0"] = { format = "NSBMA", section = "MAT0", decoder = Nsbma },
}

local function _decode(bytes, context)
  assert(type(bytes) == "string", "NitroAnimation.decode requires a string")
  local magic = bytes:sub(1, 4)
  local spec = FORMATS[magic]
  if not spec then
    error(
      Errors.new(
        "ANM_UNKNOWN_FILE_MAGIC",
        string.format("file magic %q is not a supported animation format", magic),
        { magic = magic, source = context }
      )
    )
  end
  local decoded, err = spec.decoder.decode(bytes, context)
  if not decoded then
    error(err)
  end
  if decoded.section ~= spec.section then
    error(
      Errors.new(
        "ANM_SECTION_MISMATCH",
        string.format("%s file has section %q, expected %q", magic, decoded.section, spec.section),
        { magic = magic, section = decoded.section, expected = spec.section, source = context }
      )
    )
  end
  return decoded
end

-- Decode one animation resource. Returns the normalized shape above, or
-- nil, err at the public boundary.
---@return table|nil, table|nil
function NitroAnimation.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

NitroAnimation.FORMATS = FORMATS

return NitroAnimation
