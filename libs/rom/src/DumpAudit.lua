-- Headless verification of a completed ROM dump, using ONLY the runtime RomFs
-- API plus cheap cache metadata. It never touches the original ROM,
-- so a passing audit in a fresh process is proof the dump boots without the
-- cartridge. Backs the --check-dump CLI mode and is exercised by unit tests
-- against a synthetic dump.
--
-- Checks: readiness/open, every FAT fileId has an output file whose size matches
-- the recorded size, required NARC aliases resolve and open, and map-matrix
-- member 0 decodes. Returns a machine-readable report; report.ok is the verdict.

local CacheFs = require("libs.rom.src.CacheFs")
local RomFs = require("libs.rom.src.RomFs")
local Hgss = require("data.manifests.hgss")
local MapMatrix = require("romdump.src.digest.MapMatrix")
local Errors = require("libs.rom.src.Errors")

local DumpAudit = {}

-- Confirm every FAT-backed output exists with the size the index recorded. Reads
-- no payloads; compares cache getInfo sizes against the index.
local function checkFiles(romFs, cache)
  local total = romFs:fileCount()
  local mismatches = {}
  for fileId = 0, total - 1 do
    local entry = romFs:info(fileId)
    if not entry then
      mismatches[#mismatches + 1] = "fileId " .. fileId .. " missing from index"
    else
      local info = cache:getInfo(entry.path)
      if not info then
        mismatches[#mismatches + 1] = "fileId " .. fileId .. " has no output at " .. entry.path
      elseif info.size ~= entry.size then
        mismatches[#mismatches + 1] = "fileId " .. fileId .. " size " .. tostring(info.size)
          .. " != recorded " .. entry.size
      end
    end
    if #mismatches >= 8 then break end -- cap noise; one failure is enough to fail
  end
  return { total = total, mismatches = mismatches, ok = #mismatches == 0 }
end

-- Every required alias must resolve through the FNT and open as a NARC.
local function checkRequiredNarcs(romFs)
  local entries, allOk = {}, true
  for _, alias in ipairs(Hgss.aliasList()) do
    if alias.required then
      local narc, err = romFs:openNarc(alias.symbol)
      local ok = narc ~= nil
      allOk = allOk and ok
      entries[#entries + 1] = {
        alias = alias.alias,
        symbol = alias.symbol,
        ok = ok,
        memberCount = narc and narc:memberCount() or nil,
        detail = not ok and Errors.format(err) or nil,
      }
    end
  end
  table.sort(entries, function(a, b) return a.symbol < b.symbol end)
  return { entries = entries, ok = allOk }
end

local function decodeMatrix(romFs)
  local narc, err = romFs:openNarc("map_matrices")
  if not narc then return nil, "map_matrices did not open: " .. Errors.format(err) end
  local member, mErr = narc:readMember(0)
  if not member then return nil, "member 0 unreadable: " .. Errors.format(mErr) end
  local matrix, dErr = MapMatrix.decode(member, 0)
  if not matrix then return nil, "member 0 did not decode: " .. Errors.format(dErr) end
  return {
    name = matrix.name,
    width = matrix.width,
    height = matrix.height,
    memberCount = narc:memberCount(),
    modelCells = matrix.width * matrix.height,
  }
end

-- versionId: which dump to audit. cache: optional injected CacheFs (tests). The
-- returned report is safe to print line by line via DumpAudit.lines(report).
function DumpAudit.run(versionId, cache)
  cache = cache or CacheFs.forVersion(versionId)
  local report = { version = versionId, checks = {}, ok = false }

  local romFs, err = RomFs.open(versionId, cache)
  if not romFs then
    report.checks[#report.checks + 1] = { name = "readiness", ok = false, detail = Errors.format(err) }
    return report
  end
  report.checks[#report.checks + 1] = { name = "readiness", ok = true }

  local meta = romFs:metadata()
  report.sha1 = meta.sha1
  report.gameCode = meta.gameCode
  report.stats = romFs:stats()

  report.fileCheck = checkFiles(romFs, cache)
  report.checks[#report.checks + 1] = {
    name = "file_outputs",
    ok = report.fileCheck.ok,
    detail = report.fileCheck.ok
      and (report.fileCheck.total .. " files present with matching sizes")
      or table.concat(report.fileCheck.mismatches, "; "),
  }

  report.requiredNarcs = checkRequiredNarcs(romFs)
  report.checks[#report.checks + 1] = {
    name = "required_narcs",
    ok = report.requiredNarcs.ok,
    detail = #report.requiredNarcs.entries .. " required aliases",
  }

  local matrix, matrixErr = decodeMatrix(romFs)
  report.matrix = matrix
  report.checks[#report.checks + 1] = {
    name = "map_matrix_decode",
    ok = matrix ~= nil,
    detail = matrix
      and string.format("member 0 %q %dx%d", matrix.name, matrix.width, matrix.height)
      or matrixErr,
  }

  romFs:close()

  report.ok = true
  for _, c in ipairs(report.checks) do
    if not c.ok then report.ok = false end
  end
  return report
end

-- Flatten a report into printable lines for the CLI (deterministic order).
function DumpAudit.lines(report)
  local out = { "dump audit: " .. report.version .. " -> " .. (report.ok and "PASS" or "FAIL") }
  if report.sha1 then
    out[#out + 1] = "  sha1:      " .. report.sha1
    out[#out + 1] = "  gameCode:  " .. report.gameCode
    local s = report.stats
    out[#out + 1] = string.format(
      "  files:     %d (named %d, overlay %d, unmapped %d), %d bytes",
      s.fileCount, s.namedFileCount, s.overlayFileCount, s.unmappedFileCount, s.totalFileBytes)
    out[#out + 1] = "  narcs:     " .. s.resolvedNarcCount .. " resolved"
  end
  for _, c in ipairs(report.checks) do
    out[#out + 1] = string.format("  [%s] %s%s",
      c.ok and "ok" or "FAIL", c.name, c.detail and (" - " .. c.detail) or "")
  end
  return out
end

return DumpAudit
