-- Default visual constants for field choice menus. The renderer owns how these
-- values are applied; keeping the theme data-only makes it safe to replace for
-- a project without changing menu semantics or layout geometry.

---@class FieldMenuTheme
---@field schema string
---@field colors { fill: number[], border: number[], text: number[], selected: number[], cursor: number[], cancel: number[] }
---@field textInsetX number
---@field textInsetY number
local FieldMenuTheme = {}

FieldMenuTheme.schema = "g4-field-menu-theme-v1"
FieldMenuTheme.colors = {
  fill = { 0.93, 0.93, 0.97, 1 },
  border = { 0.16, 0.20, 0.42, 1 },
  text = { 0.08, 0.10, 0.20, 1 },
  selected = { 0.48, 0.62, 0.88, 1 },
  cursor = { 0.10, 0.12, 0.30, 1 },
  cancel = { 0.42, 0.12, 0.16, 1 },
}
FieldMenuTheme.textInsetX = 12
FieldMenuTheme.textInsetY = 3

return FieldMenuTheme
