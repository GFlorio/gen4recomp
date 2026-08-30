-- Registry and composition tests. They pin the deterministic base model:
-- the generated and override base layers, the override-wins precedence, the
-- strict layer vocabulary, the effective chain, cache invalidation on
-- mutation, and the registry fingerprint. The exit criterion: the effective
-- graph for a script ID is deterministic and explainable.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")

local T = {}

local function signScript()
  return S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.lockAll(),
      S.say({ message = "msg.hgss.0543.00097" }),
      S.releaseAll(),
    },
  })
end

local function newRegistry()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  return registry, composition
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

-- 1. Base only: generated base compiles into a single base entry.
T["base only"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  local entry = effective.entries[1]
  Assert.equal(entry.operation, "base")
  Assert.equal(entry.owner.kind, "vanilla")
  Assert.equal(entry.owner.id, "base")
  Assert.equal(entry.graph.scriptId, "new_bark.lab_sign")
  Assert.isFalse(entry.graph.usesNext)
end

-- 2. The override layer wins over the generated transcript; both remain
-- inspectable through the registry.
T["override over generated"] = function()
  local registry, composition = newRegistry()
  local generated = signScript()
  local override = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "msg.hgss.0543.00097" }) },
  })
  registry:installBase("new_bark.lab_sign", generated, "generated")
  registry:installBase("new_bark.lab_sign", override, "override")
  Assert.equal(registry:base("new_bark.lab_sign"), override)
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].script, override)
  Assert.equal(effective.entries[1].graph.scriptId, "new_bark.lab_sign")
end

-- 3. The handwritten base layer no longer exists: installing it must be a
-- hard rejection, not a silent no-op or a documented-but-unused priority.
T["handwritten base layer is rejected"] = function()
  local registry = newRegistry()
  local ok = pcall(function()
    registry:installBase("new_bark.lab_sign", signScript(), "handwritten")
  end)
  Assert.isFalse(ok, "installBase must reject the handwritten base layer")
  local okDeferred = pcall(function()
    registry:installBaseDeferred("new_bark.lab_sign", "handwritten")
  end)
  Assert.isFalse(okDeferred, "installBaseDeferred must reject the handwritten base layer")
end

-- 4. Unknown id resolves to nil.
T["unknown id"] = function()
  local _, composition = newRegistry()
  Assert.isNil(composition:effective("new_bark.lab_sign"))
end

-- 5. The effective cache invalidates when a new base layer lands: the second
-- effective call reflects the override without sharing the first result.
T["cache invalidation"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local first = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#first.entries, 1)
  local override = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "mod.example.lab_sign" }) },
  })
  registry:installBase("new_bark.lab_sign", override, "override")
  local second = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(second.entries[1].script, override)
  Assert.isFalse(first == second)
end

-- 6. Deterministic effective revision: same inputs, same hash; a different
-- base layer changes it.
T["effective revision determinism"] = function()
  local registry1, composition1 = newRegistry()
  local registry2, composition2 = newRegistry()
  registry1:installBase("new_bark.lab_sign", signScript(), "generated")
  registry2:installBase("new_bark.lab_sign", signScript(), "generated")
  local a = assert(composition1:effective("new_bark.lab_sign"))
  local b = assert(composition2:effective("new_bark.lab_sign"))
  Assert.equal(a.revision, b.revision)
  registry2:installBase(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    "override"
  )
  local c = assert(composition2:effective("new_bark.lab_sign"))
  Assert.isFalse(a.revision == c.revision)
end

-- 7. Registry fingerprint: deterministic, changes on any mutation.
T["registry fingerprint"] = function()
  local registry1 = Registry.new()
  local registry2 = Registry.new()
  registry1:installBase("new_bark.lab_sign", signScript(), "generated")
  registry2:installBase("new_bark.lab_sign", signScript(), "generated")
  Assert.equal(registry1:fingerprint(), registry2:fingerprint())
  registry2:installBase(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    "override"
  )
  Assert.isFalse(registry1:fingerprint() == registry2:fingerprint())
end

-- 8. ids() is a set of installed bases.
T["ids list installed bases"] = function()
  local registry = newRegistry()
  registry:installBase("a", signScript(), "generated")
  registry:installBase("a", signScript(), "override")
  registry:installBase("b", signScript(), "generated")
  local ids = registry:ids()
  Assert.deepEqual(ids, { "a", "b" })
end

-- 9. The fingerprint changes when a script's content changes even though
-- its id stays the same.
T["fingerprint tracks script content"] = function()
  local registry = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local first = registry:fingerprint()
  local changed = signScript()
  changed.steps[1].sound = "SEQ_SE_DP_HEAL"
  registry:installBase("new_bark.lab_sign", changed, "override")
  Assert.isFalse(registry:fingerprint() == first, "a content change without an id change must change the fingerprint")
end

-- 10. Once sealed, every public install mutation is rejected: the seal is
-- the post-load mutation gate.
T["sealed registry rejects every install op"] = function()
  local registry = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:seal()
  local ops = {
    {
      "installBase",
      function()
        registry:installBase("new_bark.x", signScript(), "generated")
      end,
    },
    {
      "installBaseDeferred",
      function()
        registry:installBaseDeferred("new_bark.x", "generated")
      end,
    },
  }
  for _, op in ipairs(ops) do
    local err = throwsCode("SCRIPT_REGISTRY_SEALED", op[2])
    Assert.equal(err.context.scriptId, "new_bark.x")
  end
end

-- 11. A sealed registry's digest and composed chains are stable even when a
-- stored resource is mutated in place: the version is frozen, so the
-- memoized fingerprint and the composition cache never recompute and the
-- registry keeps reporting the state it was sealed with.
T["fingerprint and composition are immune to stored-resource mutation"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:seal()
  local fingerprint = registry:fingerprint()
  local effective = assert(composition:effective("new_bark.lab_sign"))
  local stored = assert(registry:base("new_bark.lab_sign"))
  stored.steps[1].sound = "SEQ_SE_DP_HEAL"
  Assert.equal(registry:fingerprint(), fingerprint, "the digest must stay stable")
  Assert.equal(assert(composition:effective("new_bark.lab_sign")), effective, "the composed chain must stay stable")
  Assert.equal(registry:version(), 1, "a sealed registry never bumps its version")
end

return { tests = T }
