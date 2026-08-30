---@meta

---@class love.math
love.math = {}

---@param rb number
---@param gb number
---@param bb number
---@param ab? number
---@return number r
---@return number g
---@return number b
---@return number a
function love.math.colorFromBytes(rb, gb, bb, ab) end

---@param r number
---@param g number
---@param b number
---@param a? number
---@return number rb
---@return number gb
---@return number bb
---@return number ab
function love.math.colorToBytes(r, g, b, a) end

---@overload fun(color: table):number, number, number
---@overload fun(c: number):number
---@param r number
---@param g number
---@param b number
---@return number lr
---@return number lg
---@return number lb
function love.math.gammaToLinear(r, g, b) end

---@return number low
---@return number high
function love.math.getRandomSeed() end

---@return string state
function love.math.getRandomState() end

---@overload fun(x1: number, y1: number, x2: number, y2: number, ...):boolean
---@param vertices number[]
---@return boolean convex
function love.math.isConvex(vertices) end

---@overload fun(color: table):number, number, number
---@overload fun(lc: number):number
---@param lr number
---@param lg number
---@param lb number
---@return number cr
---@return number cg
---@return number cb
function love.math.linearToGamma(lr, lg, lb) end

---@overload fun(x1: number, y1: number, x2: number, y2: number, ...):love.BezierCurve
---@param vertices number[]
---@return love.BezierCurve curve
function love.math.newBezierCurve(vertices) end

---@overload fun(seed: number):love.RandomGenerator
---@overload fun(low: number, high: number):love.RandomGenerator
---@return love.RandomGenerator rng
function love.math.newRandomGenerator() end

---@overload fun(x: number, y: number, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number):love.Transform
---@return love.Transform transform
function love.math.newTransform() end

---@overload fun(x: number, y: number):number
---@overload fun(x: number, y: number, z: number):number
---@overload fun(x: number, y: number, z: number, w: number):number
---@param x number
---@return number value
function love.math.noise(x) end

---@overload fun(max: number):number
---@overload fun(min: number, max: number):number
---@return number number
function love.math.random() end

---@param stddev? number
---@param mean? number
---@return number number
function love.math.randomNormal(stddev, mean) end

---@overload fun(low: number, high: number)
---@param seed number
function love.math.setRandomSeed(seed) end

---@param state string
function love.math.setRandomState(state) end

---@overload fun(x1: number, y1: number, x2: number, y2: number, x3: number, y3: number):table
---@param polygon table
---@return table triangles
function love.math.triangulate(polygon) end

---@class love.BezierCurve: love.Object
local BezierCurve = {}

---@param t number
---@return number x
---@return number y
function BezierCurve:evaluate(t) end

---@param i number
---@return number x
---@return number y
function BezierCurve:getControlPoint(i) end

---@return number count
function BezierCurve:getControlPointCount() end

---@return number degree
function BezierCurve:getDegree() end

---@return love.BezierCurve derivative
function BezierCurve:getDerivative() end

---@param startpoint number
---@param endpoint number
---@return love.BezierCurve curve
function BezierCurve:getSegment(startpoint, endpoint) end

---@param x number
---@param y number
---@param i? number
function BezierCurve:insertControlPoint(x, y, i) end

---@param index number
function BezierCurve:removeControlPoint(index) end

---@param depth? number
---@return number[] coordinates
function BezierCurve:render(depth) end

---@param startpoint number
---@param endpoint number
---@param depth? number
---@return number[] coordinates
function BezierCurve:renderSegment(startpoint, endpoint, depth) end

---@param angle number
---@param ox? number
---@param oy? number
function BezierCurve:rotate(angle, ox, oy) end

---@param s number
---@param ox? number
---@param oy? number
function BezierCurve:scale(s, ox, oy) end

---@param i number
---@param x number
---@param y number
function BezierCurve:setControlPoint(i, x, y) end

---@param dx number
---@param dy number
function BezierCurve:translate(dx, dy) end

---@class love.RandomGenerator: love.Object
local RandomGenerator = {}

---@return number low
---@return number high
function RandomGenerator:getSeed() end

---@return string state
function RandomGenerator:getState() end

---@overload fun(self: love.RandomGenerator, max: number):number
---@overload fun(self: love.RandomGenerator, min: number, max: number):number
---@return number number
function RandomGenerator:random() end

---@param stddev? number
---@param mean? number
---@return number number
function RandomGenerator:randomNormal(stddev, mean) end

---@overload fun(self: love.RandomGenerator, low: number, high: number)
---@param seed number
function RandomGenerator:setSeed(seed) end

---@param state string
function RandomGenerator:setState(state) end

---@class love.Transform: love.Object
local Transform = {}

---@param other love.Transform
---@return love.Transform transform
function Transform:apply(other) end

---@return love.Transform clone
function Transform:clone() end

---@return number e1_1
---@return number e1_2
---@return number e1_3
---@return number e1_4
---@return number e2_1
---@return number e2_2
---@return number e2_3
---@return number e2_4
---@return number e3_1
---@return number e3_2
---@return number e3_3
---@return number e3_4
---@return number e4_1
---@return number e4_2
---@return number e4_3
---@return number e4_4
function Transform:getMatrix() end

---@return love.Transform inverse
function Transform:inverse() end

---@param localX number
---@param localY number
---@return number globalX
---@return number globalY
function Transform:inverseTransformPoint(localX, localY) end

---@return boolean affine
function Transform:isAffine2DTransform() end

---@return love.Transform transform
function Transform:reset() end

---@param angle number
---@return love.Transform transform
function Transform:rotate(angle) end

---@param sx number
---@param sy? number
---@return love.Transform transform
function Transform:scale(sx, sy) end

---@overload fun(self: love.Transform, layout: love.MatrixLayout, e1_1: number, e1_2: number, e1_3: number, e1_4: number, e2_1: number, e2_2: number, e2_3: number, e2_4: number, e3_1: number, e3_2: number, e3_3: number, e3_4: number, e4_1: number, e4_2: number, e4_3: number, e4_4: number):love.Transform
---@overload fun(self: love.Transform, layout: love.MatrixLayout, matrix: table):love.Transform
---@overload fun(self: love.Transform, layout: love.MatrixLayout, matrix: table):love.Transform
---@param e1_1 number
---@param e1_2 number
---@param e1_3 number
---@param e1_4 number
---@param e2_1 number
---@param e2_2 number
---@param e2_3 number
---@param e2_4 number
---@param e3_1 number
---@param e3_2 number
---@param e3_3 number
---@param e3_4 number
---@param e4_1 number
---@param e4_2 number
---@param e4_3 number
---@param e4_4 number
---@return love.Transform transform
function Transform:setMatrix(
	e1_1,
	e1_2,
	e1_3,
	e1_4,
	e2_1,
	e2_2,
	e2_3,
	e2_4,
	e3_1,
	e3_2,
	e3_3,
	e3_4,
	e4_1,
	e4_2,
	e4_3,
	e4_4
)
end

---@param x number
---@param y number
---@param angle? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
---@return love.Transform transform
function Transform:setTransformation(x, y, angle, sx, sy, ox, oy, kx, ky) end

---@param kx number
---@param ky number
---@return love.Transform transform
function Transform:shear(kx, ky) end

---@param globalX number
---@param globalY number
---@return number localX
---@return number localY
function Transform:transformPoint(globalX, globalY) end

---@param dx number
---@param dy number
---@return love.Transform transform
function Transform:translate(dx, dy) end

---@alias love.MatrixLayout
---| "row"
---| "column"
