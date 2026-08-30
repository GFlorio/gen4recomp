---@meta

---@class love.physics
love.physics = {}

---@param fixture1 love.Fixture
---@param fixture2 love.Fixture
---@return number distance
---@return number x1
---@return number y1
---@return number x2
---@return number y2
function love.physics.getDistance(fixture1, fixture2) end

---@return number scale
function love.physics.getMeter() end

---@param world love.World
---@param x? number
---@param y? number
---@param type? love.BodyType
---@return love.Body body
function love.physics.newBody(world, x, y, type) end

---@overload fun(loop: boolean, points: table):love.ChainShape
---@param loop boolean
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@vararg number
---@return love.ChainShape shape
function love.physics.newChainShape(loop, x1, y1, x2, y2, ...) end

---@overload fun(x: number, y: number, radius: number):love.CircleShape
---@param radius number
---@return love.CircleShape shape
function love.physics.newCircleShape(radius) end

---@param body1 love.Body
---@param body2 love.Body
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param collideConnected? boolean
---@return love.DistanceJoint joint
function love.physics.newDistanceJoint(body1, body2, x1, y1, x2, y2, collideConnected) end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@return love.EdgeShape shape
function love.physics.newEdgeShape(x1, y1, x2, y2) end

---@param body love.Body
---@param shape love.Shape
---@param density? number
---@return love.Fixture fixture
function love.physics.newFixture(body, shape, density) end

---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, collideConnected?: boolean):love.FrictionJoint
---@param body1 love.Body
---@param body2 love.Body
---@param x number
---@param y number
---@param collideConnected? boolean
---@return love.FrictionJoint joint
function love.physics.newFrictionJoint(body1, body2, x, y, collideConnected) end

---@param joint1 love.Joint
---@param joint2 love.Joint
---@param ratio? number
---@param collideConnected? boolean
---@return love.GearJoint joint
function love.physics.newGearJoint(joint1, joint2, ratio, collideConnected) end

---@overload fun(body1: love.Body, body2: love.Body, correctionFactor?: number, collideConnected?: boolean):love.MotorJoint
---@param body1 love.Body
---@param body2 love.Body
---@param correctionFactor? number
---@return love.MotorJoint joint
function love.physics.newMotorJoint(body1, body2, correctionFactor) end

---@param body love.Body
---@param x number
---@param y number
---@return love.MouseJoint joint
function love.physics.newMouseJoint(body, x, y) end

---@overload fun(vertices: table):love.PolygonShape
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@vararg number
---@return love.PolygonShape shape
function love.physics.newPolygonShape(x1, y1, x2, y2, x3, y3, ...) end

---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, ax: number, ay: number, collideConnected?: boolean):love.PrismaticJoint
---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, ax: number, ay: number, collideConnected?: boolean, referenceAngle?: number):love.PrismaticJoint
---@param body1 love.Body
---@param body2 love.Body
---@param x number
---@param y number
---@param ax number
---@param ay number
---@param collideConnected? boolean
---@return love.PrismaticJoint joint
function love.physics.newPrismaticJoint(body1, body2, x, y, ax, ay, collideConnected) end

---@param body1 love.Body
---@param body2 love.Body
---@param gx1 number
---@param gy1 number
---@param gx2 number
---@param gy2 number
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param ratio? number
---@param collideConnected? boolean
---@return love.PulleyJoint joint
function love.physics.newPulleyJoint(body1, body2, gx1, gy1, gx2, gy2, x1, y1, x2, y2, ratio, collideConnected) end

---@overload fun(x: number, y: number, width: number, height: number, angle?: number):love.PolygonShape
---@param width number
---@param height number
---@return love.PolygonShape shape
function love.physics.newRectangleShape(width, height) end

---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, collideConnected?: boolean, referenceAngle?: number):love.RevoluteJoint
---@param body1 love.Body
---@param body2 love.Body
---@param x number
---@param y number
---@param collideConnected? boolean
---@return love.RevoluteJoint joint
function love.physics.newRevoluteJoint(body1, body2, x, y, collideConnected) end

---@param body1 love.Body
---@param body2 love.Body
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param maxLength number
---@param collideConnected? boolean
---@return love.RopeJoint joint
function love.physics.newRopeJoint(body1, body2, x1, y1, x2, y2, maxLength, collideConnected) end

---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, collideConnected?: boolean):love.WeldJoint
---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, collideConnected?: boolean, referenceAngle?: number):love.WeldJoint
---@param body1 love.Body
---@param body2 love.Body
---@param x number
---@param y number
---@param collideConnected? boolean
---@return love.WeldJoint joint
function love.physics.newWeldJoint(body1, body2, x, y, collideConnected) end

---@overload fun(body1: love.Body, body2: love.Body, x1: number, y1: number, x2: number, y2: number, ax: number, ay: number, collideConnected?: boolean):love.WheelJoint
---@param body1 love.Body
---@param body2 love.Body
---@param x number
---@param y number
---@param ax number
---@param ay number
---@param collideConnected? boolean
---@return love.WheelJoint joint
function love.physics.newWheelJoint(body1, body2, x, y, ax, ay, collideConnected) end

---@param xg? number
---@param yg? number
---@param sleep? boolean
---@return love.World world
function love.physics.newWorld(xg, yg, sleep) end

---@param scale number
function love.physics.setMeter(scale) end

---@class love.Body: love.Object
local Body = {}

---@param impulse number
function Body:applyAngularImpulse(impulse) end

---@overload fun(self: love.Body, fx: number, fy: number, x: number, y: number)
---@param fx number
---@param fy number
function Body:applyForce(fx, fy) end

---@overload fun(self: love.Body, ix: number, iy: number, x: number, y: number)
---@param ix number
---@param iy number
function Body:applyLinearImpulse(ix, iy) end

---@param torque number
function Body:applyTorque(torque) end

function Body:destroy() end

---@return number angle
function Body:getAngle() end

---@return number damping
function Body:getAngularDamping() end

---@return number w
function Body:getAngularVelocity() end

---@return love.Contact[] contacts
function Body:getContacts() end

---@return love.Fixture[] fixtures
function Body:getFixtures() end

---@return number scale
function Body:getGravityScale() end

---@return number inertia
function Body:getInertia() end

---@return love.Joint[] joints
function Body:getJoints() end

---@return number damping
function Body:getLinearDamping() end

---@return number x
---@return number y
function Body:getLinearVelocity() end

---@param x number
---@param y number
---@return number vx
---@return number vy
function Body:getLinearVelocityFromLocalPoint(x, y) end

---@param x number
---@param y number
---@return number vx
---@return number vy
function Body:getLinearVelocityFromWorldPoint(x, y) end

---@return number x
---@return number y
function Body:getLocalCenter() end

---@param worldX number
---@param worldY number
---@return number localX
---@return number localY
function Body:getLocalPoint(worldX, worldY) end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@vararg number
---@return number x1
---@return number y1
---@return number x2
---@return number y2
function Body:getLocalPoints(x1, y1, x2, y2, ...) end

---@param worldX number
---@param worldY number
---@return number localX
---@return number localY
function Body:getLocalVector(worldX, worldY) end

---@return number mass
function Body:getMass() end

---@return number x
---@return number y
---@return number mass
---@return number inertia
function Body:getMassData() end

---@return number x
---@return number y
function Body:getPosition() end

---@return number x
---@return number y
---@return number angle
function Body:getTransform() end

---@return love.BodyType type
function Body:getType() end

---@return any value
function Body:getUserData() end

---@return love.World world
function Body:getWorld() end

---@return number x
---@return number y
function Body:getWorldCenter() end

---@param localX number
---@param localY number
---@return number worldX
---@return number worldY
function Body:getWorldPoint(localX, localY) end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@return number x1
---@return number y1
---@return number x2
---@return number y2
function Body:getWorldPoints(x1, y1, x2, y2) end

---@param localX number
---@param localY number
---@return number worldX
---@return number worldY
function Body:getWorldVector(localX, localY) end

---@return number x
function Body:getX() end

---@return number y
function Body:getY() end

---@return boolean status
function Body:isActive() end

---@return boolean status
function Body:isAwake() end

---@return boolean status
function Body:isBullet() end

---@return boolean destroyed
function Body:isDestroyed() end

---@return boolean fixed
function Body:isFixedRotation() end

---@return boolean allowed
function Body:isSleepingAllowed() end

---@param otherbody love.Body
---@return boolean touching
function Body:isTouching(otherbody) end

function Body:resetMassData() end

---@param active boolean
function Body:setActive(active) end

---@param angle number
function Body:setAngle(angle) end

---@param damping number
function Body:setAngularDamping(damping) end

---@param w number
function Body:setAngularVelocity(w) end

---@param awake boolean
function Body:setAwake(awake) end

---@param status boolean
function Body:setBullet(status) end

---@param isFixed boolean
function Body:setFixedRotation(isFixed) end

---@param scale number
function Body:setGravityScale(scale) end

---@param inertia number
function Body:setInertia(inertia) end

---@param ld number
function Body:setLinearDamping(ld) end

---@param x number
---@param y number
function Body:setLinearVelocity(x, y) end

---@param mass number
function Body:setMass(mass) end

---@param x number
---@param y number
---@param mass number
---@param inertia number
function Body:setMassData(x, y, mass, inertia) end

---@param x number
---@param y number
function Body:setPosition(x, y) end

---@param allowed boolean
function Body:setSleepingAllowed(allowed) end

---@param x number
---@param y number
---@param angle number
function Body:setTransform(x, y, angle) end

---@param type love.BodyType
function Body:setType(type) end

---@param value any
function Body:setUserData(value) end

---@param x number
function Body:setX(x) end

---@param y number
function Body:setY(y) end

---@class love.ChainShape: love.Shape, love.Object
local ChainShape = {}

---@param index number
---@return love.EdgeShape shape
function ChainShape:getChildEdge(index) end

---@return number x
---@return number y
function ChainShape:getNextVertex() end

---@param index number
---@return number x
---@return number y
function ChainShape:getPoint(index) end

---@return number x1
---@return number y1
---@return number x2
---@return number y2
function ChainShape:getPoints() end

---@return number x
---@return number y
function ChainShape:getPreviousVertex() end

---@return number count
function ChainShape:getVertexCount() end

---@param x number
---@param y number
function ChainShape:setNextVertex(x, y) end

---@param x number
---@param y number
function ChainShape:setPreviousVertex(x, y) end

---@class love.CircleShape: love.Shape, love.Object
local CircleShape = {}

---@return number x
---@return number y
function CircleShape:getPoint() end

---@return number radius
function CircleShape:getRadius() end

---@param x number
---@param y number
function CircleShape:setPoint(x, y) end

---@param radius number
function CircleShape:setRadius(radius) end

---@class love.Contact: love.Object
local Contact = {}

---@return number indexA
---@return number indexB
function Contact:getChildren() end

---@return love.Fixture fixtureA
---@return love.Fixture fixtureB
function Contact:getFixtures() end

---@return number friction
function Contact:getFriction() end

---@return number nx
---@return number ny
function Contact:getNormal() end

---@return number x1
---@return number y1
---@return number x2
---@return number y2
function Contact:getPositions() end

---@return number restitution
function Contact:getRestitution() end

---@return boolean enabled
function Contact:isEnabled() end

---@return boolean touching
function Contact:isTouching() end

function Contact:resetFriction() end

function Contact:resetRestitution() end

---@param enabled boolean
function Contact:setEnabled(enabled) end

---@param friction number
function Contact:setFriction(friction) end

---@param restitution number
function Contact:setRestitution(restitution) end

---@class love.DistanceJoint: love.Joint, love.Object
local DistanceJoint = {}

---@return number ratio
function DistanceJoint:getDampingRatio() end

---@return number Hz
function DistanceJoint:getFrequency() end

---@return number l
function DistanceJoint:getLength() end

---@param ratio number
function DistanceJoint:setDampingRatio(ratio) end

---@param Hz number
function DistanceJoint:setFrequency(Hz) end

---@param l number
function DistanceJoint:setLength(l) end

---@class love.EdgeShape: love.Shape, love.Object
local EdgeShape = {}

---@return number x
---@return number y
function EdgeShape:getNextVertex() end

---@return number x1
---@return number y1
---@return number x2
---@return number y2
function EdgeShape:getPoints() end

---@return number x
---@return number y
function EdgeShape:getPreviousVertex() end

---@param x number
---@param y number
function EdgeShape:setNextVertex(x, y) end

---@param x number
---@param y number
function EdgeShape:setPreviousVertex(x, y) end

---@class love.Fixture: love.Object
local Fixture = {}

function Fixture:destroy() end

---@return love.Body body
function Fixture:getBody() end

---@param index? number
---@return number topLeftX
---@return number topLeftY
---@return number bottomRightX
---@return number bottomRightY
function Fixture:getBoundingBox(index) end

function Fixture:getCategory() end

---@return number density
function Fixture:getDensity() end

---@return number categories
---@return number mask
---@return number group
function Fixture:getFilterData() end

---@return number friction
function Fixture:getFriction() end

---@return number group
function Fixture:getGroupIndex() end

function Fixture:getMask() end

---@return number x
---@return number y
---@return number mass
---@return number inertia
function Fixture:getMassData() end

---@return number restitution
function Fixture:getRestitution() end

---@return love.Shape shape
function Fixture:getShape() end

---@return any value
function Fixture:getUserData() end

---@return boolean destroyed
function Fixture:isDestroyed() end

---@return boolean sensor
function Fixture:isSensor() end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param maxFraction number
---@param childIndex? number
---@return number xn
---@return number yn
---@return number fraction
function Fixture:rayCast(x1, y1, x2, y2, maxFraction, childIndex) end

---@vararg number
function Fixture:setCategory(...) end

---@param density number
function Fixture:setDensity(density) end

---@param categories number
---@param mask number
---@param group number
function Fixture:setFilterData(categories, mask, group) end

---@param friction number
function Fixture:setFriction(friction) end

---@param group number
function Fixture:setGroupIndex(group) end

---@vararg number
function Fixture:setMask(...) end

---@param restitution number
function Fixture:setRestitution(restitution) end

---@param sensor boolean
function Fixture:setSensor(sensor) end

---@param value any
function Fixture:setUserData(value) end

---@param x number
---@param y number
---@return boolean isInside
function Fixture:testPoint(x, y) end

---@class love.FrictionJoint: love.Joint, love.Object
local FrictionJoint = {}

---@return number force
function FrictionJoint:getMaxForce() end

---@return number torque
function FrictionJoint:getMaxTorque() end

---@param maxForce number
function FrictionJoint:setMaxForce(maxForce) end

---@param torque number
function FrictionJoint:setMaxTorque(torque) end

---@class love.GearJoint: love.Joint, love.Object
local GearJoint = {}

---@return love.Joint joint1
---@return love.Joint joint2
function GearJoint:getJoints() end

---@return number ratio
function GearJoint:getRatio() end

---@param ratio number
function GearJoint:setRatio(ratio) end

---@class love.Joint: love.Object
local Joint = {}

function Joint:destroy() end

---@return number x1
---@return number y1
---@return number x2
---@return number y2
function Joint:getAnchors() end

---@return love.Body bodyA
---@return love.Body bodyB
function Joint:getBodies() end

---@return boolean c
function Joint:getCollideConnected() end

---@param x number
---@return number x
---@return number y
function Joint:getReactionForce(x) end

---@param invdt number
---@return number torque
function Joint:getReactionTorque(invdt) end

---@return love.JointType type
function Joint:getType() end

---@return any value
function Joint:getUserData() end

---@return boolean destroyed
function Joint:isDestroyed() end

---@param value any
function Joint:setUserData(value) end

---@class love.MotorJoint: love.Joint, love.Object
local MotorJoint = {}

---@return number angleoffset
function MotorJoint:getAngularOffset() end

---@return number x
---@return number y
function MotorJoint:getLinearOffset() end

---@param angleoffset number
function MotorJoint:setAngularOffset(angleoffset) end

---@param x number
---@param y number
function MotorJoint:setLinearOffset(x, y) end

---@class love.MouseJoint: love.Joint, love.Object
local MouseJoint = {}

---@return number ratio
function MouseJoint:getDampingRatio() end

---@return number freq
function MouseJoint:getFrequency() end

---@return number f
function MouseJoint:getMaxForce() end

---@return number x
---@return number y
function MouseJoint:getTarget() end

---@param ratio number
function MouseJoint:setDampingRatio(ratio) end

---@param freq number
function MouseJoint:setFrequency(freq) end

---@param f number
function MouseJoint:setMaxForce(f) end

---@param x number
---@param y number
function MouseJoint:setTarget(x, y) end

---@class love.PolygonShape: love.Shape, love.Object
local PolygonShape = {}

---@return number x1
---@return number y1
---@return number x2
---@return number y2
function PolygonShape:getPoints() end

---@class love.PrismaticJoint: love.Joint, love.Object
local PrismaticJoint = {}

---@return boolean enabled
function PrismaticJoint:areLimitsEnabled() end

---@return number x
---@return number y
function PrismaticJoint:getAxis() end

---@return number s
function PrismaticJoint:getJointSpeed() end

---@return number t
function PrismaticJoint:getJointTranslation() end

---@return number lower
---@return number upper
function PrismaticJoint:getLimits() end

---@return number lower
function PrismaticJoint:getLowerLimit() end

---@return number f
function PrismaticJoint:getMaxMotorForce() end

---@param invdt number
---@return number force
function PrismaticJoint:getMotorForce(invdt) end

---@return number s
function PrismaticJoint:getMotorSpeed() end

---@return number angle
function PrismaticJoint:getReferenceAngle() end

---@return number upper
function PrismaticJoint:getUpperLimit() end

---@return boolean enabled
function PrismaticJoint:isMotorEnabled() end

---@param lower number
---@param upper number
function PrismaticJoint:setLimits(lower, upper) end

---@return boolean enable
function PrismaticJoint:setLimitsEnabled() end

---@param lower number
function PrismaticJoint:setLowerLimit(lower) end

---@param f number
function PrismaticJoint:setMaxMotorForce(f) end

---@param enable boolean
function PrismaticJoint:setMotorEnabled(enable) end

---@param s number
function PrismaticJoint:setMotorSpeed(s) end

---@param upper number
function PrismaticJoint:setUpperLimit(upper) end

---@class love.PulleyJoint: love.Joint, love.Object
local PulleyJoint = {}

---@return number length
function PulleyJoint:getConstant() end

---@return number a1x
---@return number a1y
---@return number a2x
---@return number a2y
function PulleyJoint:getGroundAnchors() end

---@return number length
function PulleyJoint:getLengthA() end

---@return number length
function PulleyJoint:getLengthB() end

---@return number len1
---@return number len2
function PulleyJoint:getMaxLengths() end

---@return number ratio
function PulleyJoint:getRatio() end

---@param length number
function PulleyJoint:setConstant(length) end

---@param max1 number
---@param max2 number
function PulleyJoint:setMaxLengths(max1, max2) end

---@param ratio number
function PulleyJoint:setRatio(ratio) end

---@class love.RevoluteJoint: love.Joint, love.Object
local RevoluteJoint = {}

---@return boolean enabled
function RevoluteJoint:areLimitsEnabled() end

---@return number angle
function RevoluteJoint:getJointAngle() end

---@return number s
function RevoluteJoint:getJointSpeed() end

---@return number lower
---@return number upper
function RevoluteJoint:getLimits() end

---@return number lower
function RevoluteJoint:getLowerLimit() end

---@return number f
function RevoluteJoint:getMaxMotorTorque() end

---@return number s
function RevoluteJoint:getMotorSpeed() end

---@return number f
function RevoluteJoint:getMotorTorque() end

---@return number angle
function RevoluteJoint:getReferenceAngle() end

---@return number upper
function RevoluteJoint:getUpperLimit() end

---@return boolean enabled
function RevoluteJoint:hasLimitsEnabled() end

---@return boolean enabled
function RevoluteJoint:isMotorEnabled() end

---@param lower number
---@param upper number
function RevoluteJoint:setLimits(lower, upper) end

---@param enable boolean
function RevoluteJoint:setLimitsEnabled(enable) end

---@param lower number
function RevoluteJoint:setLowerLimit(lower) end

---@param f number
function RevoluteJoint:setMaxMotorTorque(f) end

---@param enable boolean
function RevoluteJoint:setMotorEnabled(enable) end

---@param s number
function RevoluteJoint:setMotorSpeed(s) end

---@param upper number
function RevoluteJoint:setUpperLimit(upper) end

---@class love.RopeJoint: love.Joint, love.Object
local RopeJoint = {}

---@return number maxLength
function RopeJoint:getMaxLength() end

---@param maxLength number
function RopeJoint:setMaxLength(maxLength) end

---@class love.Shape: love.Object
local Shape = {}

---@param tx number
---@param ty number
---@param tr number
---@param childIndex? number
---@return number topLeftX
---@return number topLeftY
---@return number bottomRightX
---@return number bottomRightY
function Shape:computeAABB(tx, ty, tr, childIndex) end

---@param density number
---@return number x
---@return number y
---@return number mass
---@return number inertia
function Shape:computeMass(density) end

---@return number count
function Shape:getChildCount() end

---@return number radius
function Shape:getRadius() end

---@return love.ShapeType type
function Shape:getType() end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param maxFraction number
---@param tx number
---@param ty number
---@param tr number
---@param childIndex? number
---@return number xn
---@return number yn
---@return number fraction
function Shape:rayCast(x1, y1, x2, y2, maxFraction, tx, ty, tr, childIndex) end

---@param tx number
---@param ty number
---@param tr number
---@param x number
---@param y number
---@return boolean hit
function Shape:testPoint(tx, ty, tr, x, y) end

---@class love.WeldJoint: love.Joint, love.Object
local WeldJoint = {}

---@return number ratio
function WeldJoint:getDampingRatio() end

---@return number freq
function WeldJoint:getFrequency() end

---@return number angle
function WeldJoint:getReferenceAngle() end

---@param ratio number
function WeldJoint:setDampingRatio(ratio) end

---@param freq number
function WeldJoint:setFrequency(freq) end

---@class love.WheelJoint: love.Joint, love.Object
local WheelJoint = {}

---@return number x
---@return number y
function WheelJoint:getAxis() end

---@return number speed
function WheelJoint:getJointSpeed() end

---@return number position
function WheelJoint:getJointTranslation() end

---@return number maxTorque
function WheelJoint:getMaxMotorTorque() end

---@return number speed
function WheelJoint:getMotorSpeed() end

---@param invdt number
---@return number torque
function WheelJoint:getMotorTorque(invdt) end

---@return number ratio
function WheelJoint:getSpringDampingRatio() end

---@return number freq
function WheelJoint:getSpringFrequency() end

---@return boolean on
function WheelJoint:isMotorEnabled() end

---@param maxTorque number
function WheelJoint:setMaxMotorTorque(maxTorque) end

---@param enable boolean
function WheelJoint:setMotorEnabled(enable) end

---@param speed number
function WheelJoint:setMotorSpeed(speed) end

---@param ratio number
function WheelJoint:setSpringDampingRatio(ratio) end

---@param freq number
function WheelJoint:setSpringFrequency(freq) end

---@class love.World: love.Object
local World = {}

function World:destroy() end

---@return love.Body[] bodies
function World:getBodies() end

---@return number n
function World:getBodyCount() end

---@return function beginContact
---@return function endContact
---@return function preSolve
---@return function postSolve
function World:getCallbacks() end

---@return number n
function World:getContactCount() end

---@return function contactFilter
function World:getContactFilter() end

---@return love.Contact[] contacts
function World:getContacts() end

---@return number x
---@return number y
function World:getGravity() end

---@return number n
function World:getJointCount() end

---@return love.Joint[] joints
function World:getJoints() end

---@return boolean destroyed
function World:isDestroyed() end

---@return boolean locked
function World:isLocked() end

---@return boolean allow
function World:isSleepingAllowed() end

---@param topLeftX number
---@param topLeftY number
---@param bottomRightX number
---@param bottomRightY number
---@param callback function
function World:queryBoundingBox(topLeftX, topLeftY, bottomRightX, bottomRightY, callback) end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param callback function
function World:rayCast(x1, y1, x2, y2, callback) end

---@param beginContact function
---@param endContact function
---@param preSolve? function
---@param postSolve? function
function World:setCallbacks(beginContact, endContact, preSolve, postSolve) end

---@param filter function
function World:setContactFilter(filter) end

---@param x number
---@param y number
function World:setGravity(x, y) end

---@param allow boolean
function World:setSleepingAllowed(allow) end

---@param x number
---@param y number
function World:translateOrigin(x, y) end

---@param dt number
---@param velocityiterations? number
---@param positioniterations? number
function World:update(dt, velocityiterations, positioniterations) end

---@alias love.BodyType
---| "static"
---| "dynamic"
---| "kinematic"

---@alias love.JointType
---| "distance"
---| "friction"
---| "gear"
---| "mouse"
---| "prismatic"
---| "pulley"
---| "revolute"
---| "rope"
---| "weld"

---@alias love.ShapeType
---| "circle"
---| "polygon"
---| "edge"
---| "chain"
