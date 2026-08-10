-- Graph tests for the compiled-script graph contract: deterministic edge
-- collection and reachability. Every node shape with at least one successor
-- must return a dense edge array (no leading holes), so traversal always
-- reaches later successors even when an earlier edge is absent.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Compiler = require("libs.engine.src.script.Compiler")
local Graph = require("libs.engine.src.script.Graph")

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

return T
