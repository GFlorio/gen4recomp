-- Oak-specific message boundary. It keeps bank-219 templates immutable and
-- resolves the source player-name field only when a message is opened.

local FieldMessageProvider = require("libs.hgss.src.field.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

local OakIntroMessages = {}
OakIntroMessages.__index = OakIntroMessages

local PLAYER_NAME_MESSAGE_IDS = {
  [41] = true,
  [42] = true,
  [43] = true,
}

---@param options table<string, unknown>
---@return table<string, unknown>
function OakIntroMessages.new(options)
  assert(type(options) == "table", "Oak message formatter requires options")
  assert(type(options.templates) == "table", "Oak message formatter requires templates")
  assert(type(options.fontDef) == "table", "Oak message formatter requires a generated field font")
  return setmetatable({ templates = options.templates, fontDef = options.fontDef }, OakIntroMessages)
end

function OakIntroMessages:_format(key, context)
  local template = assert(self.templates[key], "generated Oak message is missing: " .. key)
  local function resolvePlayerName(control, args, resolverContext)
    local canonical = control == FieldMessageText.STRVAR_1 + 3 and #args == 2 and args[1] == 0 and args[2] == 0
    local sourceForm = control == FieldMessageText.STRVAR_1
      and #args == 3
      and args[1] == 3
      and args[2] == 0
      and args[3] == 0
    if not canonical and not sourceForm then
      return nil
    end
    assert(type(resolverContext.playerName) == "string", "Oak player name is required")
    return assert(FieldMessageProvider.asciiGlyphTokens(resolverContext.playerName, self.fontDef))
  end
  local resolvers
  if PLAYER_NAME_MESSAGE_IDS[template.messageId] then
    resolvers = { [FieldMessageText.STRVAR_1 + 3] = resolvePlayerName }
  end
  local formatted = FieldMessageProvider.format(FieldMessageProvider, template, context, resolvers)
  assert(not formatted.hadUnresolvedSubstitutions, "Oak message contains an unresolved substitution: " .. key)
  return formatted
end

function OakIntroMessages:format(key, context)
  return self:_format(key, context or {})
end

function OakIntroMessages:choiceLabels()
  local yes = self:_format("choice.yes", {})
  local no = self:_format("choice.no", {})
  return { [0] = yes.text, [1] = no.text }
end

return OakIntroMessages
