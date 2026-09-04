-- Internal compiled-script graph : an ordinary flat node map with resolved
-- control edges that the runtime executes. Authoring tables are never
-- executed directly; the compiler deep-copies them, so compiled graphs share
-- no nested tables with the authoring input. The revision stamps the
-- serialized graph projection, keyed by node ID: generated `src:` and author
-- `key:` node IDs are revision input, while the node `source` payload,
-- warnings, and non-identity metadata are excluded. The graph itself is not
-- frozen and makes no immutability guarantee. This module owns the schema
-- name, deterministic inspection output, and the deterministic edge/reach
-- traversal used by the compiler.

local LuaWriter = require("libs.codec.src.LuaWriter")

local Graph = {}

Graph.SCHEMA_NAME = "g4-script-graph-v1"

-- Deterministic full-graph print for diagnostics and golden tests: the graph
-- serializes with sorted keys, so identical graphs produce identical output.
---@param graph table<string, unknown>
---@return string
function Graph.inspect(graph)
  assert(graph ~= nil and graph.graphSchema == Graph.SCHEMA_NAME, "expected a compiled script graph")
  return LuaWriter.encode(graph)
end

-- Deterministic successor order for one node. Branch nodes follow their
-- explicit edges; linear nodes follow `next`. Edges are always appended as
-- non-nil values, so an absent first successor can never leave a hole that
-- stops traversal of later successors. The compiler guarantees every
-- returned target exists in the graph's node map.
---@param node table<string, unknown>
---@return string[]
function Graph.collectEdges(node)
  local out = {}
  local op = node.op
  if op == "if" then
    if node.yes then
      out[#out + 1] = node.yes
    end
    if node.no then
      out[#out + 1] = node.no
    end
  elseif op == "switch" then
    local keys = {}
    for k in pairs(node.cases) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      out[#out + 1] = node.cases[k]
    end
    if node.default then
      out[#out + 1] = node.default
    end
  elseif op == "goto" then
    if node.targetNode then
      out[#out + 1] = node.targetNode
    end
  elseif op == "goto_if" or op == "goto_compared" then
    if node.targetNode then
      out[#out + 1] = node.targetNode
    end
    if node.next then
      out[#out + 1] = node.next
    end
  elseif op == "call" or op == "call_compared" then
    if node.targetNode then
      out[#out + 1] = node.targetNode
    end
    if node.returnNode then
      out[#out + 1] = node.returnNode
    end
  else
    if node.next then
      out[#out + 1] = node.next
    end
  end
  return out
end

-- Deterministic depth-first visit order from the entry node, following
-- Graph.collectEdges. `return` and `next` have no static edges: their
-- continuations live in instance frames and are resolved by the scheduler.
---@param graph table<string, unknown>
---@return string[]
function Graph.reachableNodes(graph)
  local visited = {}
  local order = {}
  local function visit(id)
    if id == nil or visited[id] then
      return
    end
    visited[id] = true
    order[#order + 1] = id
    local node = graph.nodes[id]
    assert(node, "graph edge references missing node: " .. id)
    for _, target in ipairs(Graph.collectEdges(node)) do
      visit(target)
    end
  end
  visit(graph.entry)
  return order
end

return Graph
