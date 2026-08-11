-- PoseContract: the string vocabulary of the pose/draw contract, shared by
-- the digest compilers (romdump) and the runtime pose backends (engine).
--
-- These values cross module boundaries and serialize into compiled assets,
-- and Lua never checks string values -- so every production and comparison
-- site uses a named constant, and the LuaLS aliases below are the typo
-- guard: a misspelled constant name is an undefined-field diagnostic, and a
-- literal outside a union fails the annotated parameter or field it flows
-- into. The values themselves are the on-disk vocabulary and must not
-- change. Pure domain module.

-- The transform mode of a draw, mesh batch, or actor model:
--   "static"    geometry transformed by the ordinary joint/draw matrix
--   "billboard" camera-facing geometry, rebuilt each frame from the
--               captured base transform (see the PoseDrawMatrix contract)
---@alias TransformMode "static" | "billboard"

-- The transform source of a dynamic mesh segment: the SBC draw's matrix, or
-- a matrix-stack slot as of that draw.
---@alias DrawSource "draw" | { slot: integer }

---@class PoseContract
---@field STATIC TransformMode
---@field BILLBOARD TransformMode
---@field DRAW DrawSource
local PoseContract = {}

PoseContract.STATIC = "static"
PoseContract.BILLBOARD = "billboard"
PoseContract.DRAW = "draw"

-- The per-mesh draw record of a Nitro pose (PoseState.drawMatrices): the
-- tile-space matrix, its linear part, the transform mode, and the captured
-- billboard base. A straddling mesh additionally carries the pre-boundary
-- matrix its leading vertices were submitted under (`straddle`: the draw
-- path bends the first `leading` vertices per-vertex, exactly like the DS
-- geometry engine).
---@class PoseDrawMatrix
---@field position number[]
---@field direction number[]
---@field transformMode TransformMode
---@field baseTransform number[]|nil
---@field straddle { leading: integer, position: number[], direction: number[] }|nil

return PoseContract
