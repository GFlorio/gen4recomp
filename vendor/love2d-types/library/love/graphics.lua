---@meta

---@class love.graphics
love.graphics = {}

---@param transform love.Transform
function love.graphics.applyTransform(transform) end

---@overload fun(drawmode: love.DrawMode, arctype: love.ArcType, x: number, y: number, radius: number, angle1: number, angle2: number, segments?: number)
---@param drawmode love.DrawMode
---@param x number
---@param y number
---@param radius number
---@param angle1 number
---@param angle2 number
---@param segments? number
function love.graphics.arc(drawmode, x, y, radius, angle1, angle2, segments) end

---@overload fun(callback: function)
---@overload fun(channel: love.Channel)
---@param filename string
function love.graphics.captureScreenshot(filename) end

---@overload fun(mode: love.DrawMode, x: number, y: number, radius: number, segments: number)
---@param mode love.DrawMode
---@param x number
---@param y number
---@param radius number
function love.graphics.circle(mode, x, y, radius) end

---@overload fun(r: number, g: number, b: number, a?: number, clearstencil?: boolean, cleardepth?: boolean)
---@overload fun(color: table, ..., clearstencil?: boolean, cleardepth?: boolean)
---@overload fun(clearcolor: boolean, clearstencil: boolean, cleardepth: boolean)
function love.graphics.clear() end

---@overload fun(discardcolors: table, discardstencil?: boolean)
---@param discardcolor? boolean
---@param discardstencil? boolean
function love.graphics.discard(discardcolor, discardstencil) end

---@overload fun(texture: love.Texture, quad: love.Quad, x: number, y: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(drawable: love.Drawable, transform: love.Transform)
---@overload fun(texture: love.Texture, quad: love.Quad, transform: love.Transform)
---@param drawable love.Drawable
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(mesh: love.Mesh, instancecount: number, transform: love.Transform)
---@param mesh love.Mesh
---@param instancecount number
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function love.graphics.drawInstanced(mesh, instancecount, x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(texture: love.Texture, layerindex: number, quad: love.Quad, x?: number, y?: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(texture: love.Texture, layerindex: number, transform: love.Transform)
---@overload fun(texture: love.Texture, layerindex: number, quad: love.Quad, transform: love.Transform)
---@param texture love.Texture
---@param layerindex number
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function love.graphics.drawLayer(texture, layerindex, x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(mode: love.DrawMode, x: number, y: number, radiusx: number, radiusy: number, segments: number)
---@param mode love.DrawMode
---@param x number
---@param y number
---@param radiusx number
---@param radiusy number
function love.graphics.ellipse(mode, x, y, radiusx, radiusy) end

function love.graphics.flushBatch() end

---@return number r
---@return number g
---@return number b
---@return number a
function love.graphics.getBackgroundColor() end

---@return love.BlendMode mode
---@return love.BlendAlphaMode alphamode
function love.graphics.getBlendMode() end

---@return love.Canvas canvas
function love.graphics.getCanvas() end

---@overload fun(readable: boolean):table
---@return table formats
function love.graphics.getCanvasFormats() end

---@return number r
---@return number g
---@return number b
---@return number a
function love.graphics.getColor() end

---@return boolean r
---@return boolean g
---@return boolean b
---@return boolean a
function love.graphics.getColorMask() end

---@return number scale
function love.graphics.getDPIScale() end

---@return love.FilterMode min
---@return love.FilterMode mag
---@return number anisotropy
function love.graphics.getDefaultFilter() end

---@return love.CompareMode comparemode
---@return boolean write
function love.graphics.getDepthMode() end

---@return number width
---@return number height
function love.graphics.getDimensions() end

---@return love.Font font
function love.graphics.getFont() end

---@return love.VertexWinding winding
function love.graphics.getFrontFaceWinding() end

---@return number height
function love.graphics.getHeight() end

---@return table formats
function love.graphics.getImageFormats() end

---@return love.LineJoin join
function love.graphics.getLineJoin() end

---@return love.LineStyle style
function love.graphics.getLineStyle() end

---@return number width
function love.graphics.getLineWidth() end

---@return love.CullMode mode
function love.graphics.getMeshCullMode() end

---@return number pixelwidth
---@return number pixelheight
function love.graphics.getPixelDimensions() end

---@return number pixelheight
function love.graphics.getPixelHeight() end

---@return number pixelwidth
function love.graphics.getPixelWidth() end

---@return number size
function love.graphics.getPointSize() end

---@return string name
---@return string version
---@return string vendor
---@return string device
function love.graphics.getRendererInfo() end

---@return number x
---@return number y
---@return number width
---@return number height
function love.graphics.getScissor() end

---@return love.Shader shader
function love.graphics.getShader() end

---@return number depth
function love.graphics.getStackDepth() end

---@overload fun(stats: table):table
---@return {drawcalls: number, canvasswitches: number, texturememory: number, images: number, canvases: number, fonts: number, shaderswitches: number, drawcallsbatched: number} stats
function love.graphics.getStats() end

---@return love.CompareMode comparemode
---@return number comparevalue
function love.graphics.getStencilTest() end

---@return table features
function love.graphics.getSupported() end

---@return table limits
function love.graphics.getSystemLimits() end

---@return table texturetypes
function love.graphics.getTextureTypes() end

---@return number width
function love.graphics.getWidth() end

---@param x number
---@param y number
---@param width number
---@param height number
function love.graphics.intersectScissor(x, y, width, height) end

---@param screenX number
---@param screenY number
---@return number globalX
---@return number globalY
function love.graphics.inverseTransformPoint(screenX, screenY) end

---@return boolean active
function love.graphics.isActive() end

---@return boolean gammacorrect
function love.graphics.isGammaCorrect() end

---@return boolean wireframe
function love.graphics.isWireframe() end

---@overload fun(points: table)
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@vararg number
function love.graphics.line(x1, y1, x2, y2, ...) end

---@param slices table
---@param settings? {mipmaps: boolean, linear: boolean, dpiscale: number}
---@return love.Image image
function love.graphics.newArrayImage(slices, settings) end

---@overload fun(width: number, height: number):love.Canvas
---@overload fun(width: number, height: number, settings: table):love.Canvas
---@overload fun(width: number, height: number, layers: number, settings: table):love.Canvas
---@return love.Canvas canvas
function love.graphics.newCanvas() end

---@overload fun(faces: table, settings?: table):love.Image
---@param filename string
---@param settings? {mipmaps: boolean, linear: boolean}
---@return love.Image image
function love.graphics.newCubeImage(filename, settings) end

---@overload fun(filename: string, size: number, hinting?: love.HintingMode, dpiscale?: number):love.Font
---@overload fun(filename: string, imagefilename: string):love.Font
---@overload fun(size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Font
---@param filename string
---@return love.Font font
function love.graphics.newFont(filename) end

---@overload fun(fileData: love.FileData, settings?: table):love.Image
---@overload fun(imageData: love.ImageData, settings?: table):love.Image
---@overload fun(compressedImageData: love.CompressedImageData, settings?: table):love.Image
---@param filename string
---@param settings? {dpiscale: number, linear: boolean, mipmaps: boolean}
---@return love.Image image
function love.graphics.newImage(filename, settings) end

---@overload fun(imageData: love.ImageData, glyphs: string):love.Font
---@overload fun(filename: string, glyphs: string, extraspacing: number):love.Font
---@param filename string
---@param glyphs string
---@return love.Font font
function love.graphics.newImageFont(filename, glyphs) end

---@overload fun(vertexcount: number, mode?: love.MeshDrawMode, usage?: love.SpriteBatchUsage):love.Mesh
---@overload fun(vertexformat: table, vertices: table, mode?: love.MeshDrawMode, usage?: love.SpriteBatchUsage):love.Mesh
---@overload fun(vertexformat: table, vertexcount: number, mode?: love.MeshDrawMode, usage?: love.SpriteBatchUsage):love.Mesh
---@overload fun(vertexcount: number, texture?: love.Texture, mode?: love.MeshDrawMode):love.Mesh
---@param vertices {["1"]: number, ["2"]: number, ["3"]: number, ["4"]: number, ["5"]: number, ["6"]: number, ["7"]: number, ["8"]: number}
---@param mode? love.MeshDrawMode
---@param usage? love.SpriteBatchUsage
---@return love.Mesh mesh
function love.graphics.newMesh(vertices, mode, usage) end

---@overload fun(texture: love.Texture, buffer?: number):love.ParticleSystem
---@param image love.Image
---@param buffer? number
---@return love.ParticleSystem system
function love.graphics.newParticleSystem(image, buffer) end

---@overload fun(x: number, y: number, width: number, height: number, texture: love.Texture):love.Quad
---@param x number
---@param y number
---@param width number
---@param height number
---@param sw number
---@param sh number
---@return love.Quad quad
function love.graphics.newQuad(x, y, width, height, sw, sh) end

---@overload fun(pixelcode: string, vertexcode: string):love.Shader
---@param code string
---@return love.Shader shader
function love.graphics.newShader(code) end

---@overload fun(image: love.Image, maxsprites?: number, usage?: love.SpriteBatchUsage):love.SpriteBatch
---@overload fun(texture: love.Texture, maxsprites?: number, usage?: love.SpriteBatchUsage):love.SpriteBatch
---@param image love.Image
---@param maxsprites? number
---@return love.SpriteBatch spriteBatch
function love.graphics.newSpriteBatch(image, maxsprites) end

---@overload fun(font: love.Font, coloredtext: table):love.Text
---@param font love.Font
---@param textstring? string
---@return love.Text text
function love.graphics.newText(font, textstring) end

---@overload fun(videostream: love.VideoStream):love.Video
---@overload fun(filename: string, settings?: table):love.Video
---@overload fun(filename: string, loadaudio?: boolean):love.Video
---@overload fun(videostream: love.VideoStream, loadaudio?: boolean):love.Video
---@param filename string
---@return love.Video video
function love.graphics.newVideo(filename) end

---@param layers table
---@param settings? {mipmaps: boolean, linear: boolean}
---@return love.Image image
function love.graphics.newVolumeImage(layers, settings) end

function love.graphics.origin() end

---@overload fun(points: table)
---@overload fun(points: table)
---@param x number
---@param y number
---@vararg number
function love.graphics.points(x, y, ...) end

---@overload fun(mode: love.DrawMode, vertices: table)
---@param mode love.DrawMode
---@vararg number
function love.graphics.polygon(mode, ...) end

function love.graphics.pop() end

function love.graphics.present() end

---@overload fun(coloredtext: table, x?: number, y?: number, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(text: string, transform: love.Transform)
---@overload fun(coloredtext: table, transform: love.Transform)
---@overload fun(text: string, font: love.Font, transform: love.Transform)
---@overload fun(coloredtext: table, font: love.Font, transform: love.Transform)
---@param text string
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function love.graphics.print(text, x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(text: string, font: love.Font, x: number, y: number, limit: number, align?: love.AlignMode, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(text: string, transform: love.Transform, limit: number, align?: love.AlignMode)
---@overload fun(text: string, font: love.Font, transform: love.Transform, limit: number, align?: love.AlignMode)
---@overload fun(coloredtext: table, x: number, y: number, limit: number, align: love.AlignMode, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(coloredtext: table, font: love.Font, x: number, y: number, limit: number, align?: love.AlignMode, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(coloredtext: table, transform: love.Transform, limit: number, align?: love.AlignMode)
---@overload fun(coloredtext: table, font: love.Font, transform: love.Transform, limit: number, align?: love.AlignMode)
---@param text string
---@param x number
---@param y number
---@param limit number
---@param align? love.AlignMode
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function love.graphics.printf(text, x, y, limit, align, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(stack: love.StackType)
function love.graphics.push() end

---@overload fun(mode: love.DrawMode, x: number, y: number, width: number, height: number, rx: number, ry?: number, segments?: number)
---@param mode love.DrawMode
---@param x number
---@param y number
---@param width number
---@param height number
function love.graphics.rectangle(mode, x, y, width, height) end

---@param transform love.Transform
function love.graphics.replaceTransform(transform) end

function love.graphics.reset() end

---@param angle number
function love.graphics.rotate(angle) end

---@param sx number
---@param sy? number
function love.graphics.scale(sx, sy) end

---@overload fun(rgba: table)
---@param red number
---@param green number
---@param blue number
---@param alpha? number
function love.graphics.setBackgroundColor(red, green, blue, alpha) end

---@overload fun(mode: love.BlendMode, alphamode?: love.BlendAlphaMode)
---@param mode love.BlendMode
function love.graphics.setBlendMode(mode) end

---@overload fun()
---@overload fun(canvas1: love.Canvas, canvas2: love.Canvas, ...)
---@overload fun(canvas: love.Canvas, slice: number, mipmap?: number)
---@overload fun(setup: table)
---@param canvas love.Canvas
---@param mipmap? number
function love.graphics.setCanvas(canvas, mipmap) end

---@overload fun(rgba: table)
---@param red number
---@param green number
---@param blue number
---@param alpha? number
function love.graphics.setColor(red, green, blue, alpha) end

---@overload fun()
---@param red boolean
---@param green boolean
---@param blue boolean
---@param alpha boolean
function love.graphics.setColorMask(red, green, blue, alpha) end

---@param min love.FilterMode
---@param mag? love.FilterMode
---@param anisotropy? number
function love.graphics.setDefaultFilter(min, mag, anisotropy) end

---@overload fun()
---@param comparemode love.CompareMode
---@param write boolean
function love.graphics.setDepthMode(comparemode, write) end

---@param font love.Font
function love.graphics.setFont(font) end

---@param winding love.VertexWinding
function love.graphics.setFrontFaceWinding(winding) end

---@param join love.LineJoin
function love.graphics.setLineJoin(join) end

---@param style love.LineStyle
function love.graphics.setLineStyle(style) end

---@param width number
function love.graphics.setLineWidth(width) end

---@param mode love.CullMode
function love.graphics.setMeshCullMode(mode) end

---@overload fun(filename: string, size?: number):love.Font
---@overload fun(file: love.File, size?: number):love.Font
---@overload fun(data: love.Data, size?: number):love.Font
---@overload fun(rasterizer: love.Rasterizer):love.Font
---@param size? number
---@return love.Font font
function love.graphics.setNewFont(size) end

---@param size number
function love.graphics.setPointSize(size) end

---@overload fun()
---@param x number
---@param y number
---@param width number
---@param height number
function love.graphics.setScissor(x, y, width, height) end

---@overload fun()
---@param shader love.Shader
function love.graphics.setShader(shader) end

---@overload fun()
---@param comparemode love.CompareMode
---@param comparevalue number
function love.graphics.setStencilTest(comparemode, comparevalue) end

---@param enable boolean
function love.graphics.setWireframe(enable) end

---@param kx number
---@param ky number
function love.graphics.shear(kx, ky) end

---@param stencilfunction function
---@param action? love.StencilAction
---@param value? number
---@param keepvalues? boolean
function love.graphics.stencil(stencilfunction, action, value, keepvalues) end

---@param globalX number
---@param globalY number
---@return number screenX
---@return number screenY
function love.graphics.transformPoint(globalX, globalY) end

---@param dx number
---@param dy number
function love.graphics.translate(dx, dy) end

---@overload fun(gles: boolean, pixelcode: string, vertexcode: string):boolean, string
---@param gles boolean
---@param code string
---@return boolean status
---@return string message
function love.graphics.validateShader(gles, code) end

---@class love.Canvas: love.Texture, love.Drawable, love.Object
local Canvas = {}

function Canvas:generateMipmaps() end

---@return number samples
function Canvas:getMSAA() end

---@return love.MipmapMode mode
function Canvas:getMipmapMode() end

---@overload fun(self: love.Canvas, slice: number, mipmap?: number, x: number, y: number, width: number, height: number):love.ImageData
---@return love.ImageData data
function Canvas:newImageData() end

---@param func function
---@vararg any
function Canvas:renderTo(func, ...) end

---@class love.Drawable: love.Object
local Drawable = {}

---@class love.Font: love.Object
local Font = {}

---@return number ascent
function Font:getAscent() end

---@return number baseline
function Font:getBaseline() end

---@return number dpiscale
function Font:getDPIScale() end

---@return number descent
function Font:getDescent() end

---@return love.FilterMode min
---@return love.FilterMode mag
---@return number anisotropy
function Font:getFilter() end

---@return number height
function Font:getHeight() end

---@overload fun(self: love.Font, leftglyph: number, rightglyph: number):number
---@param leftchar string
---@param rightchar string
---@return number kerning
function Font:getKerning(leftchar, rightchar) end

---@return number height
function Font:getLineHeight() end

---@param text string
---@return number width
function Font:getWidth(text) end

---@param text string
---@param wraplimit number
---@return number width
---@return string[] wrappedtext
function Font:getWrap(text, wraplimit) end

---@overload fun(self: love.Font, character1: string, character2: string):boolean
---@overload fun(self: love.Font, codepoint1: number, codepoint2: number):boolean
---@param text string
---@return boolean hasglyph
function Font:hasGlyphs(text) end

---@param fallbackfont1 love.Font
---@vararg love.Font
function Font:setFallbacks(fallbackfont1, ...) end

---@param min love.FilterMode
---@param mag love.FilterMode
---@param anisotropy? number
function Font:setFilter(min, mag, anisotropy) end

---@param height number
function Font:setLineHeight(height) end

---@class love.Image: love.Texture, love.Drawable, love.Object
local Image = {}

---@return boolean compressed
function Image:isCompressed() end

---@return boolean linear
function Image:isFormatLinear() end

---@param data love.ImageData
---@param slice? number
---@param mipmap? number
---@param x? number
---@param y? number
---@param reloadmipmaps? boolean
function Image:replacePixels(data, slice, mipmap, x, y, reloadmipmaps) end

---@class love.Mesh: love.Drawable, love.Object
local Mesh = {}

---@overload fun(self: love.Mesh, name: string, mesh: love.Mesh, step?: love.VertexAttributeStep, attachname?: string)
---@param name string
---@param mesh love.Mesh
function Mesh:attachAttribute(name, mesh) end

---@param name string
---@return boolean success
function Mesh:detachAttribute(name) end

function Mesh:flush() end

---@return love.MeshDrawMode mode
function Mesh:getDrawMode() end

---@return number min
---@return number max
function Mesh:getDrawRange() end

---@return love.Texture texture
function Mesh:getTexture() end

---@overload fun(self: love.Mesh, index: number):number, number, number, number, number, number, number, number
---@param index number
---@return number attributecomponent
function Mesh:getVertex(index) end

---@param vertexindex number
---@param attributeindex number
---@return number value1
---@return number value2
function Mesh:getVertexAttribute(vertexindex, attributeindex) end

---@return number count
function Mesh:getVertexCount() end

---@return {attribute: table} format
function Mesh:getVertexFormat() end

---@return number[] map
function Mesh:getVertexMap() end

---@param name string
---@return boolean enabled
function Mesh:isAttributeEnabled(name) end

---@param name string
---@param enable boolean
function Mesh:setAttributeEnabled(name, enable) end

---@param mode love.MeshDrawMode
function Mesh:setDrawMode(mode) end

---@overload fun(self: love.Mesh)
---@param start number
---@param count number
function Mesh:setDrawRange(start, count) end

---@overload fun(self: love.Mesh)
---@param texture love.Texture
function Mesh:setTexture(texture) end

---@overload fun(self: love.Mesh, index: number, vertex: table)
---@overload fun(self: love.Mesh, index: number, x: number, y: number, u: number, v: number, r?: number, g?: number, b?: number, a?: number)
---@overload fun(self: love.Mesh, index: number, vertex: table)
---@param index number
---@param attributecomponent number
---@vararg number
function Mesh:setVertex(index, attributecomponent, ...) end

---@param vertexindex number
---@param attributeindex number
---@param value1 number
---@param value2 number
---@vararg number
function Mesh:setVertexAttribute(vertexindex, attributeindex, value1, value2, ...) end

---@overload fun(self: love.Mesh, vi1: number, vi2: number, vi3: number)
---@overload fun(self: love.Mesh, data: love.Data, datatype: love.IndexDataType)
---@param map table
function Mesh:setVertexMap(map) end

---@overload fun(self: love.Mesh, data: love.Data, startvertex?: number)
---@overload fun(self: love.Mesh, vertices: table)
---@param vertices {attributecomponent: number}
---@param startvertex? number
---@param count? number
function Mesh:setVertices(vertices, startvertex, count) end

---@class love.ParticleSystem: love.Drawable, love.Object
local ParticleSystem = {}

---@return love.ParticleSystem particlesystem
function ParticleSystem:clone() end

---@param numparticles number
function ParticleSystem:emit(numparticles) end

---@return number size
function ParticleSystem:getBufferSize() end

---@return number r1
---@return number g1
---@return number b1
---@return number a1
---@return number r2
---@return number g2
---@return number b2
---@return number a2
---@return number r8
---@return number g8
---@return number b8
---@return number a8
function ParticleSystem:getColors() end

---@return number count
function ParticleSystem:getCount() end

---@return number direction
function ParticleSystem:getDirection() end

---@return love.AreaSpreadDistribution distribution
---@return number dx
---@return number dy
---@return number angle
---@return boolean directionRelativeToCenter
function ParticleSystem:getEmissionArea() end

---@return number rate
function ParticleSystem:getEmissionRate() end

---@return number life
function ParticleSystem:getEmitterLifetime() end

---@return love.ParticleInsertMode mode
function ParticleSystem:getInsertMode() end

---@return number xmin
---@return number ymin
---@return number xmax
---@return number ymax
function ParticleSystem:getLinearAcceleration() end

---@return number min
---@return number max
function ParticleSystem:getLinearDamping() end

---@return number ox
---@return number oy
function ParticleSystem:getOffset() end

---@return number min
---@return number max
function ParticleSystem:getParticleLifetime() end

---@return number x
---@return number y
function ParticleSystem:getPosition() end

---@return love.Quad[] quads
function ParticleSystem:getQuads() end

---@return number min
---@return number max
function ParticleSystem:getRadialAcceleration() end

---@return number min
---@return number max
function ParticleSystem:getRotation() end

---@return number variation
function ParticleSystem:getSizeVariation() end

---@return number size1
---@return number size2
---@return number size8
function ParticleSystem:getSizes() end

---@return number min
---@return number max
function ParticleSystem:getSpeed() end

---@return number min
---@return number max
---@return number variation
function ParticleSystem:getSpin() end

---@return number variation
function ParticleSystem:getSpinVariation() end

---@return number spread
function ParticleSystem:getSpread() end

---@return number min
---@return number max
function ParticleSystem:getTangentialAcceleration() end

---@return love.Texture texture
function ParticleSystem:getTexture() end

---@return boolean enable
function ParticleSystem:hasRelativeRotation() end

---@return boolean active
function ParticleSystem:isActive() end

---@return boolean paused
function ParticleSystem:isPaused() end

---@return boolean stopped
function ParticleSystem:isStopped() end

---@param x number
---@param y number
function ParticleSystem:moveTo(x, y) end

function ParticleSystem:pause() end

function ParticleSystem:reset() end

---@param size number
function ParticleSystem:setBufferSize(size) end

---@overload fun(self: love.ParticleSystem, rgba1: table, ...)
---@param r1 number
---@param g1 number
---@param b1 number
---@param a1? number
---@vararg number
function ParticleSystem:setColors(r1, g1, b1, a1, ...) end

---@param direction number
function ParticleSystem:setDirection(direction) end

---@param distribution love.AreaSpreadDistribution
---@param dx number
---@param dy number
---@param angle? number
---@param directionRelativeToCenter? boolean
function ParticleSystem:setEmissionArea(distribution, dx, dy, angle, directionRelativeToCenter) end

---@param rate number
function ParticleSystem:setEmissionRate(rate) end

---@param life number
function ParticleSystem:setEmitterLifetime(life) end

---@param mode love.ParticleInsertMode
function ParticleSystem:setInsertMode(mode) end

---@param xmin number
---@param ymin number
---@param xmax? number
---@param ymax? number
function ParticleSystem:setLinearAcceleration(xmin, ymin, xmax, ymax) end

---@param min number
---@param max? number
function ParticleSystem:setLinearDamping(min, max) end

---@param x number
---@param y number
function ParticleSystem:setOffset(x, y) end

---@param min number
---@param max? number
function ParticleSystem:setParticleLifetime(min, max) end

---@param x number
---@param y number
function ParticleSystem:setPosition(x, y) end

---@overload fun(self: love.ParticleSystem, quads: table)
---@param quad1 love.Quad
---@vararg love.Quad
function ParticleSystem:setQuads(quad1, ...) end

---@param min number
---@param max? number
function ParticleSystem:setRadialAcceleration(min, max) end

---@param enable boolean
function ParticleSystem:setRelativeRotation(enable) end

---@param min number
---@param max? number
function ParticleSystem:setRotation(min, max) end

---@param variation number
function ParticleSystem:setSizeVariation(variation) end

---@param size1 number
---@param size2? number
---@param size8? number
function ParticleSystem:setSizes(size1, size2, size8) end

---@param min number
---@param max? number
function ParticleSystem:setSpeed(min, max) end

---@param min number
---@param max? number
function ParticleSystem:setSpin(min, max) end

---@param variation number
function ParticleSystem:setSpinVariation(variation) end

---@param spread number
function ParticleSystem:setSpread(spread) end

---@param min number
---@param max? number
function ParticleSystem:setTangentialAcceleration(min, max) end

---@param texture love.Texture
function ParticleSystem:setTexture(texture) end

function ParticleSystem:start() end

function ParticleSystem:stop() end

---@param dt number
function ParticleSystem:update(dt) end

---@class love.Quad: love.Object
local Quad = {}

---@return number sw
---@return number sh
function Quad:getTextureDimensions() end

---@return number x
---@return number y
---@return number w
---@return number h
function Quad:getViewport() end

---@param x number
---@param y number
---@param w number
---@param h number
---@param sw? number
---@param sh? number
function Quad:setViewport(x, y, w, h, sw, sh) end

---@class love.Shader: love.Object
local Shader = {}

---@return string warnings
function Shader:getWarnings() end

---@param name string
---@return boolean hasuniform
function Shader:hasUniform(name) end

---@overload fun(self: love.Shader, name: string, vector: table, ...)
---@overload fun(self: love.Shader, name: string, matrix: table, ...)
---@overload fun(self: love.Shader, name: string, texture: love.Texture)
---@overload fun(self: love.Shader, name: string, boolean: boolean, ...)
---@overload fun(self: love.Shader, name: string, matrixlayout: love.MatrixLayout, matrix: table, ...)
---@overload fun(self: love.Shader, name: string, data: love.Data, offset?: number, size?: number)
---@overload fun(self: love.Shader, name: string, data: love.Data, matrixlayout: love.MatrixLayout, offset?: number, size?: number)
---@overload fun(self: love.Shader, name: string, matrixlayout: love.MatrixLayout, data: love.Data, offset?: number, size?: number)
---@param name string
---@param number number
---@vararg number
function Shader:send(name, number, ...) end

---@param name string
---@param color number[]
---@vararg number[]
function Shader:sendColor(name, color, ...) end

---@class love.SpriteBatch: love.Drawable, love.Object
local SpriteBatch = {}

---@overload fun(self: love.SpriteBatch, quad: love.Quad, x: number, y: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number):number
---@param x number
---@param y number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
---@return number id
function SpriteBatch:add(x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(self: love.SpriteBatch, layerindex: number, quad: love.Quad, x?: number, y?: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number):number
---@overload fun(self: love.SpriteBatch, layerindex: number, transform: love.Transform):number
---@overload fun(self: love.SpriteBatch, layerindex: number, quad: love.Quad, transform: love.Transform):number
---@param layerindex number
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
---@return number spriteindex
function SpriteBatch:addLayer(layerindex, x, y, r, sx, sy, ox, oy, kx, ky) end

---@param name string
---@param mesh love.Mesh
function SpriteBatch:attachAttribute(name, mesh) end

function SpriteBatch:clear() end

function SpriteBatch:flush() end

---@return number size
function SpriteBatch:getBufferSize() end

---@return number r
---@return number g
---@return number b
---@return number a
function SpriteBatch:getColor() end

---@return number count
function SpriteBatch:getCount() end

---@return love.Texture texture
function SpriteBatch:getTexture() end

---@overload fun(self: love.SpriteBatch, spriteindex: number, quad: love.Quad, x: number, y: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@param spriteindex number
---@param x number
---@param y number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function SpriteBatch:set(spriteindex, x, y, r, sx, sy, ox, oy, kx, ky) end

---@overload fun(self: love.SpriteBatch)
---@param r number
---@param g number
---@param b number
---@param a? number
function SpriteBatch:setColor(r, g, b, a) end

---@overload fun(self: love.SpriteBatch)
---@param start number
---@param count number
function SpriteBatch:setDrawRange(start, count) end

---@overload fun(self: love.SpriteBatch, spriteindex: number, layerindex: number, quad: love.Quad, x?: number, y?: number, r?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number)
---@overload fun(self: love.SpriteBatch, spriteindex: number, layerindex: number, transform: love.Transform)
---@overload fun(self: love.SpriteBatch, spriteindex: number, layerindex: number, quad: love.Quad, transform: love.Transform)
---@param spriteindex number
---@param layerindex number
---@param x? number
---@param y? number
---@param r? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
function SpriteBatch:setLayer(spriteindex, layerindex, x, y, r, sx, sy, ox, oy, kx, ky) end

---@param texture love.Texture
function SpriteBatch:setTexture(texture) end

---@class love.Text: love.Drawable, love.Object
local Text = {}

---@overload fun(self: love.Text, coloredtext: table, x?: number, y?: number, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number):number
---@param textstring string
---@param x? number
---@param y? number
---@param angle? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
---@return number index
function Text:add(textstring, x, y, angle, sx, sy, ox, oy, kx, ky) end

---@overload fun(self: love.Text, coloredtext: table, wraplimit: number, align: love.AlignMode, x: number, y: number, angle?: number, sx?: number, sy?: number, ox?: number, oy?: number, kx?: number, ky?: number):number
---@param textstring string
---@param wraplimit number
---@param align love.AlignMode
---@param x number
---@param y number
---@param angle? number
---@param sx? number
---@param sy? number
---@param ox? number
---@param oy? number
---@param kx? number
---@param ky? number
---@return number index
function Text:addf(textstring, wraplimit, align, x, y, angle, sx, sy, ox, oy, kx, ky) end

function Text:clear() end

---@overload fun(self: love.Text, index: number):number, number
---@return number width
---@return number height
function Text:getDimensions() end

---@return love.Font font
function Text:getFont() end

---@overload fun(self: love.Text, index: number):number
---@return number height
function Text:getHeight() end

---@overload fun(self: love.Text, index: number):number
---@return number width
function Text:getWidth() end

---@overload fun(self: love.Text, coloredtext: table)
---@param textstring string
function Text:set(textstring) end

---@param font love.Font
function Text:setFont(font) end

---@overload fun(self: love.Text, coloredtext: table, wraplimit: number, align: love.AlignMode)
---@param textstring string
---@param wraplimit number
---@param align love.AlignMode
function Text:setf(textstring, wraplimit, align) end

---@class love.Texture: love.Drawable, love.Object
local Texture = {}

---@return number dpiscale
function Texture:getDPIScale() end

---@return number depth
function Texture:getDepth() end

---@return love.CompareMode compare
function Texture:getDepthSampleMode() end

---@return number width
---@return number height
function Texture:getDimensions() end

---@return love.FilterMode min
---@return love.FilterMode mag
---@return number anisotropy
function Texture:getFilter() end

---@return love.PixelFormat format
function Texture:getFormat() end

---@return number height
function Texture:getHeight() end

---@return number layers
function Texture:getLayerCount() end

---@return number mipmaps
function Texture:getMipmapCount() end

---@return love.FilterMode mode
---@return number sharpness
function Texture:getMipmapFilter() end

---@return number pixelwidth
---@return number pixelheight
function Texture:getPixelDimensions() end

---@return number pixelheight
function Texture:getPixelHeight() end

---@return number pixelwidth
function Texture:getPixelWidth() end

---@return love.TextureType texturetype
function Texture:getTextureType() end

---@return number width
function Texture:getWidth() end

---@return love.WrapMode horiz
---@return love.WrapMode vert
---@return love.WrapMode depth
function Texture:getWrap() end

---@return boolean readable
function Texture:isReadable() end

---@param compare love.CompareMode
function Texture:setDepthSampleMode(compare) end

---@param min love.FilterMode
---@param mag? love.FilterMode
---@param anisotropy? number
function Texture:setFilter(min, mag, anisotropy) end

---@overload fun(self: love.Texture)
---@param filtermode love.FilterMode
---@param sharpness? number
function Texture:setMipmapFilter(filtermode, sharpness) end

---@param horiz love.WrapMode
---@param vert? love.WrapMode
---@param depth? love.WrapMode
function Texture:setWrap(horiz, vert, depth) end

---@class love.Video: love.Drawable, love.Object
local Video = {}

---@return number width
---@return number height
function Video:getDimensions() end

---@return love.FilterMode min
---@return love.FilterMode mag
---@return number anisotropy
function Video:getFilter() end

---@return number height
function Video:getHeight() end

---@return love.Source source
function Video:getSource() end

---@return love.VideoStream stream
function Video:getStream() end

---@return number width
function Video:getWidth() end

---@return boolean playing
function Video:isPlaying() end

function Video:pause() end

function Video:play() end

function Video:rewind() end

---@param offset number
function Video:seek(offset) end

---@param min love.FilterMode
---@param mag love.FilterMode
---@param anisotropy? number
function Video:setFilter(min, mag, anisotropy) end

---@param source? love.Source
function Video:setSource(source) end

---@return number seconds
function Video:tell() end

---@alias love.AlignMode
---| "center"
---| "left"
---| "right"
---| "justify"

---@alias love.ArcType
---| "pie"
---| "open"
---| "closed"

---@alias love.AreaSpreadDistribution
---| "uniform"
---| "normal"
---| "ellipse"
---| "borderellipse"
---| "borderrectangle"
---| "none"

---@alias love.BlendAlphaMode
---| "alphamultiply"
---| "premultiplied"

---@alias love.BlendMode
---| "alpha"
---| "replace"
---| "screen"
---| "add"
---| "subtract"
---| "multiply"
---| "lighten"
---| "darken"
---| "additive"
---| "subtractive"
---| "multiplicative"
---| "premultiplied"

---@alias love.CompareMode
---| "equal"
---| "notequal"
---| "less"
---| "lequal"
---| "gequal"
---| "greater"
---| "never"
---| "always"

---@alias love.CullMode
---| "back"
---| "front"
---| "none"

---@alias love.DrawMode
---| "fill"
---| "line"

---@alias love.FilterMode
---| "linear"
---| "nearest"

---@alias love.GraphicsFeature
---| "clampzero"
---| "lighten"
---| "multicanvasformats"
---| "glsl3"
---| "instancing"
---| "fullnpot"
---| "pixelshaderhighp"
---| "shaderderivatives"

---@alias love.GraphicsLimit
---| "pointsize"
---| "texturesize"
---| "multicanvas"
---| "canvasmsaa"
---| "texturelayers"
---| "volumetexturesize"
---| "cubetexturesize"
---| "anisotropy"

---@alias love.IndexDataType
---| "uint16"
---| "uint32"

---@alias love.LineJoin
---| "miter"
---| "none"
---| "bevel"

---@alias love.LineStyle
---| "rough"
---| "smooth"

---@alias love.MeshDrawMode
---| "fan"
---| "strip"
---| "triangles"
---| "points"

---@alias love.MipmapMode
---| "none"
---| "auto"
---| "manual"

---@alias love.ParticleInsertMode
---| "top"
---| "bottom"
---| "random"

---@alias love.SpriteBatchUsage
---| "dynamic"
---| "static"
---| "stream"

---@alias love.StackType
---| "transform"
---| "all"

---@alias love.StencilAction
---| "replace"
---| "increment"
---| "decrement"
---| "incrementwrap"
---| "decrementwrap"
---| "invert"

---@alias love.TextureType
---| "2d"
---| "array"
---| "cube"
---| "volume"

---@alias love.VertexAttributeStep
---| "pervertex"
---| "perinstance"

---@alias love.VertexWinding
---| "cw"
---| "ccw"

---@alias love.WrapMode
---| "clamp"
---| "repeat"
---| "mirroredrepeat"
---| "clampzero"
