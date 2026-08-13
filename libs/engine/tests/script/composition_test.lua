-- Registry and composition tests. They pin
-- the deterministic contribution model: base layers (generated
-- vs override), register/override/before/after/wrap/remove, priority and
-- load-order ordering, tombstones, same-priority replacement conflicts,
-- owner attribution, the effective chain, and cache invalidation. The exit
-- criterion: the effective graph for a script ID is deterministic and
-- explainable.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")

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

-- 4. Unknown id resolves to nil; a tombstone alone also resolves to nil.
T["unknown id"] = function()
  local registry, composition = newRegistry()
  Assert.isNil(composition:effective("new_bark.lab_sign"))
  registry:remove("new_bark.lab_sign", { modId = "mod.a" })
  Assert.isNil(composition:effective("new_bark.lab_sign"))
end

-- 5. register collides with a base or a second registration.
T["register duplicate"] = function()
  local registry = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry:register("new_bark.lab_sign", signScript(), { modId = "mod.a" })
  end)
  local registry2 = newRegistry()
  registry2:register("new_bark.alone", signScript(), { modId = "mod.a" })
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry2:register("new_bark.alone", signScript(), { modId = "mod.b" })
  end)
end

-- 5. override replaces the base; the resource is the registry-level get.
T["override replaces base"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local replacement = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "mod.example.lab_sign" }) },
  })
  registry:override("new_bark.lab_sign", replacement, { modId = "mod.a" }, { priority = 1 })
  Assert.equal(registry:get("new_bark.lab_sign"), replacement)
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].operation, "override")
  Assert.equal(effective.entries[1].owner.id, "mod.a")
  Assert.equal(effective.entries[1].script, replacement)
end

-- 6. Highest-priority replacement wins; the lower one is suppressed.
T["priority replacement wins"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:override(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.say({ message = "mod.low" }) },
    }),
    { modId = "mod.low" },
    { priority = 1, loadOrder = 1 }
  )
  local high = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "mod.high" }) },
  })
  registry:override("new_bark.lab_sign", high, { modId = "mod.high" }, { priority = 5, loadOrder = 2 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].owner.id, "mod.high")
end

-- 7. Same-priority replacements from different owners are a hard load error
-- naming both owners.
T["replacement conflict"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:override(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    { modId = "mod.a" },
    { priority = 3 }
  )
  registry:override(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    { modId = "mod.b" },
    { priority = 3 }
  )
  local err = throwsCode("SCRIPT_REPLACE_CONFLICT", function()
    composition:effective("new_bark.lab_sign")
  end)
  Assert.equal(err.context.firstOwner.id, "mod.a")
  Assert.equal(err.context.secondOwner.id, "mod.b")
end

-- 8. A same-priority same-owner second replacement wins without error.
T["same owner last replacement wins"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:override(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    { modId = "mod.a" },
    { priority = 2 }
  )
  local second = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "mod.a.second" }) },
  })
  registry:override("new_bark.lab_sign", second, { modId = "mod.a" }, { priority = 2 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(effective.entries[1].script, second)
end

-- 9. Tombstone suppresses the base; a higher-priority
-- replacement still stands.
T["remove tombstones base"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:remove("new_bark.lab_sign", { modId = "mod.a" }, { priority = 1 })
  Assert.isNil(composition:effective("new_bark.lab_sign"))
  Assert.isNil(registry:get("new_bark.lab_sign"))
end

T["remove below replacement keeps replacement"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:override(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "new_bark.lab_sign",
      steps = { S.noop() },
    }),
    { modId = "mod.a" },
    { priority = 5 }
  )
  registry:remove("new_bark.lab_sign", { modId = "mod.b" }, { priority = 1 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].owner.id, "mod.a")
end

-- 10. before/after/wrap ordering: before high->low, wrap high outermost, base,
-- after low->high. Wrapper resources compile with the
-- wrapper permission (their `next` is legal).
T["before wrap base after order"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local function wrapper(name, op)
    return S.script({
      api = 1,
      id = name,
      steps = {
        op == "before" and S.setVar({ variable = "VAR_W", value = "before." .. name })
          or S.setVar({ variable = "VAR_W", value = "wrap." .. name }),
        S.next(),
      },
    })
  end
  registry:before("new_bark.lab_sign", wrapper("pre.a", "before"), { modId = "mod.a" }, { priority = 1 })
  registry:before("new_bark.lab_sign", wrapper("pre.b", "before"), { modId = "mod.b" }, { priority = 9 })
  registry:wrap("new_bark.lab_sign", wrapper("wrp.a", "wrap"), { modId = "mod.a" }, { priority = 1 })
  registry:wrap("new_bark.lab_sign", wrapper("wrp.b", "wrap"), { modId = "mod.b" }, { priority = 9 })
  registry:after("new_bark.lab_sign", wrapper("post.a", "after"), { modId = "mod.a" }, { priority = 1 })
  registry:after("new_bark.lab_sign", wrapper("post.b", "after"), { modId = "mod.b" }, { priority = 9 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  local operations = {}
  for _, entry in ipairs(effective.entries) do
    operations[#operations + 1] = entry.operation .. ":" .. entry.owner.id
  end
  Assert.deepEqual(
    operations,
    { "before:mod.b", "before:mod.a", "wrap:mod.b", "wrap:mod.a", "base:base", "after:mod.a", "after:mod.b" }
  )
end

-- 11. The example-mod preface  compiles as a before
-- wrapper with no explicit next: the base remains part of the chain.
T["example mod preface"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local preface = S.script({
    api = 1,
    id = "example.script_override.lab_sign_preface",
    steps = { S.say({ message = "mod.example.script_override.lab_sign_preface" }) },
  })
  registry:before("new_bark.lab_sign", preface, { modId = "example.script_override" }, { priority = 0 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 2)
  Assert.equal(effective.entries[1].operation, "before")
  Assert.equal(effective.entries[1].owner.id, "example.script_override")
  Assert.equal(effective.entries[2].operation, "base")
  Assert.isTrue(
    #effective.entries[1].graph.warnings == 0,
    "a before wrapper without label/goto compiles without warnings"
  )
end

-- 12. A wrapper containing `next` compiles only with the wrapper permission;
-- a `next` in the base script is rejected.
T["next requires wrapper registration"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local badBase = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.next() },
  })
  registry:override("new_bark.lab_sign", badBase, { modId = "mod.a" })
  local err = throwsCode("SCRIPT_WRAPPER_INVALID", function()
    composition:effective("new_bark.lab_sign")
  end)
  Assert.equal(err.context.scriptId, "new_bark.lab_sign")
end

-- 13. Owner attribution flows into every entry.
T["owner attribution"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "example.mod", api = 1 },
    { priority = 0, loadOrder = 4 }
  )
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.deepEqual(effective.entries[1].owner, { kind = "mod", id = "example.mod", api = 1 })
end

-- 14. The effective cache invalidates when a contribution lands.
T["cache invalidation"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local first = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#first.entries, 1)
  registry:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "mod.a" }
  )
  local second = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#second.entries, 2)
  Assert.isFalse(first == second)
end

-- 15. Deterministic effective revision: same inputs, same hash; a different
-- contribution changes it.
T["effective revision determinism"] = function()
  local registry1, composition1 = newRegistry()
  local registry2, composition2 = newRegistry()
  registry1:installBase("new_bark.lab_sign", signScript(), "generated")
  registry2:installBase("new_bark.lab_sign", signScript(), "generated")
  registry1:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "mod.a" }
  )
  registry2:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "mod.a" }
  )
  local a = assert(composition1:effective("new_bark.lab_sign"))
  local b = assert(composition2:effective("new_bark.lab_sign"))
  Assert.equal(a.revision, b.revision)
  registry2:after(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "post",
      steps = { S.next() },
    }),
    { modId = "mod.b" }
  )
  local c = assert(composition2:effective("new_bark.lab_sign"))
  Assert.isFalse(a.revision == c.revision)
end

-- 16. Registry fingerprint: deterministic, changes on any mutation.
T["registry fingerprint"] = function()
  local registry1 = Registry.new()
  local registry2 = Registry.new()
  registry1:installBase("new_bark.lab_sign", signScript(), "generated")
  registry2:installBase("new_bark.lab_sign", signScript(), "generated")
  Assert.equal(registry1:fingerprint(), registry2:fingerprint())
  registry2:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "mod.a" }
  )
  Assert.isFalse(registry1:fingerprint() == registry2:fingerprint())
end

-- 17. A register-only id composes as a single register entry.
T["register-only id"] = function()
  local registry, composition = newRegistry()
  local script = S.script({
    api = 1,
    id = "new_bark.custom",
    steps = { S.say({ message = "msg.custom" }) },
  })
  registry:register("new_bark.custom", script, { modId = "mod.a" })
  local effective = assert(composition:effective("new_bark.custom"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].operation, "register")
  Assert.equal(effective.entries[1].owner.id, "mod.a")
end

-- 18. Load order breaks priority ties: lower loadOrder first.
T["load order ordering"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  local function wrapper(name)
    return S.script({ api = 1, id = name, steps = { S.next() } })
  end
  registry:before("new_bark.lab_sign", wrapper("late"), { modId = "mod.late" }, { priority = 1, loadOrder = 5 })
  registry:before("new_bark.lab_sign", wrapper("early"), { modId = "mod.early" }, { priority = 1, loadOrder = 1 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(effective.entries[1].owner.id, "mod.early")
  Assert.equal(effective.entries[2].owner.id, "mod.late")
end

-- 19. The registry keeps every contribution inspectable, ordered.
T["contributions inspectable"] = function()
  local registry = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "pre",
      steps = { S.next() },
    }),
    { modId = "mod.a" },
    { priority = 2, loadOrder = 1 }
  )
  registry:after(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "post",
      steps = { S.next() },
    }),
    { modId = "mod.b" },
    { priority = 0, loadOrder = 1 }
  )
  local contributions = registry:contributions("new_bark.lab_sign")
  Assert.equal(#contributions, 2)
  Assert.equal(contributions[1].operation, "before")
  Assert.equal(contributions[1].owner.id, "mod.a")
  Assert.equal(contributions[2].operation, "after")
end

-- 20. Invalid owners are rejected.
T["invalid owner"] = function()
  local registry = newRegistry()
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    registry:before(
      "new_bark.lab_sign",
      S.script({
        api = 1,
        id = "pre",
        steps = { S.next() },
      }),
      nil
    )
  end)
end

-- 21. ids() is a set: an id with both a base and a contribution appears once.
T["ids deduplicate base and contribution"] = function()
  local registry = newRegistry()
  registry:installBase("a", signScript(), "generated")
  registry:override("a", signScript(), { modId = "mod.a" })
  registry:installBase("b", signScript(), "generated")
  local ids = registry:ids()
  Assert.deepEqual(ids, { "a", "b" })
end

-- 22. The fingerprint changes when a script's content changes even though
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

-- 23. A winning tombstone suppresses the base and every lower-priority
-- before/wrap/after contribution; equal-or-higher priority contributions
-- still apply.
T["tombstone suppresses lower priority wrappers"] = function()
  local registry, composition = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:before(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "low-before",
      steps = { S.next() },
    }),
    { modId = "mod.low" },
    { priority = 1 }
  )
  registry:wrap(
    "new_bark.lab_sign",
    S.script({
      api = 1,
      id = "high-wrap",
      steps = { S.next() },
    }),
    { modId = "mod.high" },
    { priority = 5 }
  )
  registry:remove("new_bark.lab_sign", { modId = "mod.tomb" }, { priority = 3 })
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(#effective.entries, 1)
  Assert.equal(effective.entries[1].operation, "wrap")
  Assert.equal(effective.entries[1].owner.id, "mod.high", "the lower-priority before is suppressed by the tombstone")
end

-- 24. Once sealed, every public install/contribution mutation is rejected:
-- the seal is the post-load mutation gate.
T["sealed registry rejects every install and contribution op"] = function()
  local registry = newRegistry()
  registry:installBase("new_bark.lab_sign", signScript(), "generated")
  registry:register("new_bark.custom", signScript(), { modId = "mod.a" })
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
    {
      "register",
      function()
        registry:register("new_bark.x", signScript(), { modId = "mod.a" })
      end,
    },
    {
      "override",
      function()
        registry:override("new_bark.x", signScript(), { modId = "mod.a" })
      end,
    },
    {
      "before",
      function()
        registry:before("new_bark.x", signScript(), { modId = "mod.a" })
      end,
    },
    {
      "after",
      function()
        registry:after("new_bark.x", signScript(), { modId = "mod.a" })
      end,
    },
    {
      "wrap",
      function()
        registry:wrap("new_bark.x", signScript(), { modId = "mod.a" })
      end,
    },
    {
      "remove",
      function()
        registry:remove("new_bark.x", { modId = "mod.a" })
      end,
    },
  }
  for _, op in ipairs(ops) do
    local err = throwsCode("SCRIPT_REGISTRY_SEALED", op[2])
    Assert.equal(err.context.scriptId, "new_bark.x")
  end
end

-- 25. A returned contribution record is a copy: mutating it cannot change
-- what the registry later reports.
T["a returned record cannot alter the registry"] = function()
  local registry = newRegistry()
  local script = signScript()
  registry:register("new_bark.custom", script, { modId = "mod.a" }, { priority = 2 })
  local record = assert(registry:contributions("new_bark.custom")[1])
  record.priority = 999
  record.operation = "remove"
  record.resource = nil
  local fresh = assert(registry:contributions("new_bark.custom")[1])
  Assert.equal(fresh.priority, 2, "a returned record must not carry mutations back in")
  Assert.equal(fresh.operation, "register")
  Assert.notNil(fresh.resource)
  Assert.equal(registry:get("new_bark.custom"), script, "the stored resource is untouched")
end

-- 26. A sealed registry's digest and composed chains are stable even when a
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
