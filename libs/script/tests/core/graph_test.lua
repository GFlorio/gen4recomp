-- Graph tests for the compiled-script graph contract: deterministic edge
-- collection and reachability, plus deep-copy isolation from the authoring
-- input. Every node shape with at least one successor must return a dense
-- edge array (no leading holes), so traversal always reaches later successors
-- even when an earlier edge is absent. Compiled graphs are ordinary mutable
-- tables; the isolation guarantee comes from the compiler's deep copies, not
-- from any runtime freezing.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Compiler = require("libs.script.src.Compiler")
local Graph = require("libs.script.src.Graph")

local T = {}

local function compile(script, opts)
  local graph, err = Compiler.compile(script, opts)
  if not graph then
    error("compile failed: " .. tostring(err))
  end
  return graph
end

-- --- Edge collection: dense arrays without leading holes ---

function T.if_node_with_missing_yes_keeps_the_no_edge()
  Assert.deepEqual(Graph.collectEdges({ op = "if", no = "target" }), { "target" })
end

function T.if_node_with_missing_no_keeps_the_yes_edge()
  Assert.deepEqual(Graph.collectEdges({ op = "if", yes = "target" }), { "target" })
end

function T.if_node_edges_keep_yes_then_no_order()
  Assert.deepEqual(Graph.collectEdges({ op = "if", yes = "yes", no = "no" }), { "yes", "no" })
end

function T.conditional_goto_with_missing_target_keeps_the_next_edge()
  Assert.deepEqual(Graph.collectEdges({ op = "goto_if", next = "cont" }), { "cont" })
  Assert.deepEqual(Graph.collectEdges({ op = "goto_compared", next = "cont" }), { "cont" })
end

function T.conditional_goto_edges_keep_target_then_next_order()
  Assert.deepEqual(Graph.collectEdges({ op = "goto_if", targetNode = "target", next = "cont" }), { "target", "cont" })
  Assert.deepEqual(
    Graph.collectEdges({ op = "goto_compared", targetNode = "target", next = "cont" }),
    { "target", "cont" }
  )
end

function T.call_edges_append_in_target_then_return_order()
  Assert.deepEqual(Graph.collectEdges({ op = "call", targetNode = "target", returnNode = "ret" }), { "target", "ret" })
  Assert.deepEqual(Graph.collectEdges({ op = "call", targetNode = "target" }), { "target" })
  Assert.deepEqual(Graph.collectEdges({ op = "call", returnNode = "ret" }), { "ret" })
  Assert.deepEqual(
    Graph.collectEdges({ op = "call_compared", targetNode = "target", returnNode = "ret" }),
    { "target", "ret" }
  )
end

function T.switch_edges_are_sorted_cases_then_default()
  local node = { op = "switch", cases = { b = "b", a = "a", c = "c" }, default = "default" }
  Assert.deepEqual(Graph.collectEdges(node), { "a", "b", "c", "default" })
  Assert.deepEqual(Graph.collectEdges({ op = "switch", cases = { b = "b", a = "a" } }), { "a", "b" })
end

function T.unconditional_goto_returns_the_target()
  Assert.deepEqual(Graph.collectEdges({ op = "goto", targetNode = "target" }), { "target" })
end

function T.linear_nodes_return_next_when_present()
  Assert.deepEqual(Graph.collectEdges({ op = "say", next = "cont" }), { "cont" })
  Assert.deepEqual(Graph.collectEdges({ op = "say" }), {})
end

-- --- Reachability: an absent first successor must not stop traversal ---

function T.reachable_nodes_traverses_a_second_successor_after_an_absent_first()
  local graph = {
    nodes = {
      entry = { op = "if", no = "a" },
      a = { op = "say", next = "b" },
      b = { op = "say" },
    },
    entry = "entry",
  }
  Assert.deepEqual(Graph.reachableNodes(graph), { "entry", "a", "b" })
end

function T.compiled_trailing_if_with_empty_yes_branch_keeps_no_branch_reachable()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.if_({
        condition = S.flag("FLAG_F"),
        yes = {},
        no = { S.stop() },
      }),
    },
  }))
  local order = Graph.reachableNodes(graph)
  Assert.equal(#order, 2)
  Assert.equal(order[1], graph.entry)
  Assert.equal(order[2], "path:steps/0/no/0")
end

function T.compiled_cross_script_goto_compared_keeps_fallthrough_reachable()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.gotoCompared({ operator = "eq", script = "other" }),
      S.stop(),
    },
  }))
  local order = Graph.reachableNodes(graph)
  Assert.equal(#order, 2)
  Assert.equal(order[1], graph.entry)
  Assert.equal(order[2], "path:steps/1")
end

-- --- Deep-copy isolation from the authoring input ---

-- A script whose steps carry nested tables (condition, branch steps,
-- bindings, reference values) plus graph-level declarations, so sharing
-- anywhere would be observable.
local function isolatedScript()
  return S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { route = "string" },
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.if_({ condition = S.flag("FLAG_F"), yes = { S.noop() } }),
      S.say({ message = "msg.x", bindings = { [0] = S.playerName() } }),
      S.stop(),
    },
  })
end

function T.compiled_graph_does_not_share_nested_tables_with_input()
  local author = isolatedScript()
  local graph = compile(author)
  local ifNode = graph.nodes["path:steps/1"]
  local sayNode = graph.nodes["path:steps/2"]
  Assert.isFalse(rawequal(ifNode, author.steps[2]), "step node must be a copy")
  Assert.isFalse(rawequal(ifNode.condition, author.steps[2].condition), "condition table must be a copy")
  Assert.isFalse(rawequal(graph.nodes[ifNode.yes], author.steps[2].yes[1]), "nested branch step must be a copy")
  Assert.isFalse(rawequal(sayNode.bindings, author.steps[3].bindings), "bindings must be a copy")
  Assert.isFalse(rawequal(sayNode.bindings[0], author.steps[3].bindings[0]), "binding value must be a copy")
  Assert.isFalse(rawequal(graph.params, author.params), "params must be a copy")
  Assert.isFalse(rawequal(graph.locals, author.locals), "locals must be a copy")
end

function T.mutating_authoring_resource_after_compile_does_not_mutate_the_compiled_graph()
  local author = isolatedScript()
  local graph = compile(author)
  author.steps[1].sound = "SEQ_SE_DP_MUTATED"
  author.steps[2].condition.id = "FLAG_MUTATED"
  author.steps[2].yes[1].op = "wait_ticks"
  author.steps[3].message = "msg.mutated"
  author.steps[3].bindings[0] = S.rivalName()
  author.params.professor = "string"
  author.locals.route = "number"
  Assert.equal(graph.nodes["path:steps/0"].sound, "SEQ_SE_DP_SELECT")
  Assert.deepEqual(graph.nodes["path:steps/1"].condition, {
    condition = "flag",
    id = "FLAG_F",
    expected = true,
  })
  Assert.equal(graph.nodes[graph.nodes["path:steps/1"].yes].op, "noop")
  Assert.equal(graph.nodes["path:steps/2"].message, "msg.x")
  Assert.deepEqual(graph.nodes["path:steps/2"].bindings[0], { text = "player_name" })
  Assert.equal(graph.params.professor, "actor_ref")
  Assert.equal(graph.locals.route, "string")
end

-- Writes into a compiled graph succeed everywhere, including keys that were
-- never present; they are writes into the graph's own copies and must never
-- leak back into the authoring resource.
function T.writes_into_the_compiled_graph_do_not_touch_authoring_input()
  local author = isolatedScript()
  local graph = compile(author)
  graph.injected = true
  graph.nodes["injected"] = {}
  graph.nodes["path:steps/0"].injected = true
  graph.nodes["path:steps/1"].condition.injected = true
  graph.nodes["path:steps/2"].bindings.injected = true
  Assert.isNil(author.steps[1].injected)
  Assert.isNil(author.steps[2].condition.injected)
  Assert.isNil(author.steps[3].bindings.injected)
end

return { tests = T }
