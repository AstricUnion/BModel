---@name Model
---@author AstricUnion


-- implement client parents for holograms
if CLIENT then
    local setParent = function(self, par)
        if self.parent then
            self.parent.children[self] = nil
            self.parent = nil
        end
        if par then
            par.children = par.children or {}
            par.children[self] = self
            self.parent = par
            self:__setParentOld(par)
        else
            self:__setParentOld(nil)
        end
    end

    local getChildren = function(self)
        return self.children
    end

    local getParent = function(self)
        return self.parent
    end

    hologram.__createOld = hologram.__createOld or hologram.create
    function hologram.create(...)
        local holo = hologram.__createOld(...)
        if !holo then return end
        holo.children = {}
        holo.__setParentOld = holo.__setParentOld or holo.setParent
        holo.setParent = setParent
        holo.__getChildrenOld = holo.__getChildrenOld or holo.getChildren
        holo.getChildren = getChildren
        holo.__getParentOld = holo.__getParentOld or holo.getParent
        holo.getParent = getParent
        return holo
    end
end

---@class ToNetwork
---@field modelId string Identifier of model
---@field params table[] Global parameters to set (functions to call)
---@field paramsToSend table[] Parameters to set to send at this moment

---Class to manipulate hologram models with custom meshes and hitboxes
---@class model
---@field registered table<string, ModelInfo>
---@field inited table<number, ModelEntity>
---@field mesh table<string, CMesh> Hashmap with mesh to get
---@field meshToLoad CMesh[] List with mesh to load
---@field toNetwork table<number, ToNetwork>
---@field networked table<number, ToNetwork>
---@field networking boolean
---@field materials table<string, Material>
local model = {}
model.registered = {}
model.inited = {}
model.mesh = {}
model.meshToLoad = {}
model.materials = {}
model.toNetwork = {}
model.networked = {}
model.networking = false
model.rigVisible = false
model.rigModel = "models/editor/axis_helper_thick.mdl"

---@alias modelfun fun(): (Entity?)


---@class Sequence
---@field id number ID of sequence to start
---@field start number Relative to curtime
---@field duration number Duration of sequence
---@field process fun(process: number): boolean Relative to curtime

---@class ModelEntity: Entity
---@field modelInfo ModelInfo Model info
---@field modelBones BoneEntity[] [CLIENT] Model bones entities, by number
---@field sequences table<number, Sequence> [CLIENT] Layers of sequences
---@field poseParameters table<string, number> [CLIENT] Pose parameters for this entity
---@field color Color Color of model entity
---@field material string Material of model entity
---@field submaterials table<number, string> Current submaterials of entity
---@field renderFX number RENDERFX enum
---@field noDraw boolean No draw this entity
local ModelEntity = {}
ModelEntity.networking = false

local function recursiveFun(origin, fun, ...)
    for _, v in pairs(origin:getChildren()) do
        if v:getClass() ~= "starfall_hologram" then goto cont end
        if isfunction(fun) then
            fun(v, ...)
        else
            if v[fun] then v[fun](v, ...) end
        end
        recursiveFun(v, fun, ...)
        ::cont::
    end
end

function ModelEntity:recursiveFun(fun, ...)
    for _, v in pairs(CLIENT and self.modelBones or self:getChildren()) do
        if v:getClass() ~= "starfall_hologram" then goto cont end
        if isfunction(fun) then
            fun(v, ...)
        else
            if v[fun] then v[fun](v, ...) end
        end
        if SERVER then
            recursiveFun(v, fun, ...)
        end
        ::cont::
    end
end

function ModelEntity:sendFunction(func, ...)
    if !SERVER or !self.modelInfo then return end
    local entId = self:entIndex()
    local args = {...}
    local toNetwork = model.toNetwork[entId]
    if !toNetwork then return end
    local params = toNetwork.paramsToSend
    local globalParams = toNetwork.params
    local tab = {func, args}
    params[#params+1] = tab
    globalParams[#globalParams+1] = tab
    if self.networking then return end
    self.networking = true
    timer.simple(0, function()
        if !isValid(self) then return end
        net.start("ModelCallFunctions")
            net.writeTable(params)
            net.writeEntity(self)
        net.send(find.allPlayers())
        table.empty(params)
        self.networking = false
    end)
end

---[SHARED] Lookup for bone in entity
---@param name string Name of the bone
---@return number id
function ModelEntity:lookupBone(name)
    return self.modelInfo.bonesIDs[name] or -1
end

---[SHARED] Lookup for sequence in entity
---@param name string Name of the sequence
---@return number id
function ModelEntity:lookupSequence(name)
    return self.modelInfo.sequencesIDs[name] or -1
end

---[SHARED] Returns current entity sequence
---@param layer number? Layer of animation
---@return number id
function ModelEntity:getSequence(layer)
    local seq = self.sequences[layer or 0]
    return seq and seq.id or 0
end

---[SHARED] Set sequence for this entity
---@param id number|string Sequence ID or name of sequence
---@param layerId number? Sequence layer ID, by default is 1
---@param time number? Time of animation, by default is 0
function ModelEntity:setSequence(id, layerId, time)
    layerId = layerId or 0
    time = time or 0
    self:sendFunction("setSequence", id, layerId, time)
    if CLIENT then
        local seq = self.modelInfo.sequences[isnumber(id) and id or self.modelInfo.sequencesIDs[id]]
        if !seq then
            self.sequences[layerId] = nil
            return
        end
        local sequence = {}
        self.sequences[layerId] = sequence
        local process = seq.startFun(self, layerId)
        sequence.id = id
        sequence.start = timer.curtime() - time
        sequence.process = process
        sequence.duration = seq.duration
    end
end

---[SHARED] Returns current entity pose parameter
---@param name string Name of pose parameter
---@return number value
function ModelEntity:getPose(name)
    return self.poseParameters[name] or 0
end

---[SHARED] Set pose parameter for this entity
---@param name string Name of pose parameter
---@param value number Value to set
function ModelEntity:setPose(name, value)
    self:sendFunction("setPose", name, value)
    if CLIENT then
        local param = self.modelInfo.poseParameters[name]
        if !param then return end
        self.poseParameters[name] = math.clamp(value, param.min, param.max)
    end
end

local function multiplyColor(c1, c2)
    return ((c1 / 255) * (c2 / 255)) * 255
end

if CLIENT then
    function ModelEntity:draw(noTint)
        self:recursiveFun("draw", noTint)
    end

    ---[CLIENT] Get entity of the bone
    ---@param id number Index of the bone
    ---@return BoneEntity?
    function ModelEntity:getBoneEntity(id)
        return self.modelBones[id]
    end

    local function vectorToPrefixed(prefix, vec)
        return string.format("\n%s %s %s %s", prefix, vec.x, vec.y, vec.z)
    end

    local function objFromModel(mdl, offset, angle, scale, numOffset)
        scale = scale
        local msh = mesh.getModelMeshes(mdl)
        if !msh then return end
        local vertexes = ""
        local normals = ""
        local faces = ""
        local verticies = msh[1].triangles
        local function getIndex(id)
            local v = verticies[id]
            if !v then return end
            vertexes = vertexes .. vectorToPrefixed("v", localToWorld(v.pos * scale, Angle(), offset, angle) / 39.37008)
            normals = normals .. vectorToPrefixed("vn", v.normal)
            return id
        end
        local numVert = #verticies
        for i=1, numVert, 3 do
            local v1i = getIndex(i)
            local v2i = getIndex(i+1)
            local v3i = getIndex(i+2)
            if !(v1i and v2i and v3i) then goto cont end
            faces = faces .. vectorToPrefixed("f", Vector(v1i + numOffset, v2i + numOffset, v3i + numOffset))
            ::cont::
        end
        return vertexes, normals, faces, numVert
    end

    local function recursiveObj(v, originPos, originAng, currentOffset, threading)
        local pos, ang = worldToLocal(v:getPos(), v:getAngles(), originPos, originAng)
        local vertexesGl, normalsGl, facesGl, offset = objFromModel(v:getModel(), pos, ang, v:getScale(), currentOffset)
        offset = offset + currentOffset
        for _, child in pairs(v:getChildren()) do
            if child.modelBone then goto cont end
            local num, vertexes, normals, faces = recursiveObj(child, originPos, originAng, offset, threading)
            offset = num
            vertexesGl = vertexesGl .. vertexes
            normalsGl = normalsGl .. normals
            facesGl = facesGl .. faces
            ::cont::
        end
        if threading then coroutine.yield() end
        return offset, vertexesGl, normalsGl, facesGl
    end

    ---[CLIENT] Get OBJ with rig for Blender
    ---@param threading boolean? Threading for it
    ---@return string mdlData
    function ModelEntity:getObj(threading)
        local objData = ""
        local boneString = ""
        local offset = 0
        local originPos, originAng = self:getPos(), self:getAngles()
        local boneInfos = self.modelInfo.bones
        for i, v in ipairs(self.modelBones) do
            local num, vertexesGl, normalsGl, facesGl = recursiveObj(v, originPos, originAng, offset, threading)
            offset = num
            local boneInfo = boneInfos[i]
            local name = boneInfo.name
            objData = objData .. "o " .. name .. vertexesGl .. normalsGl .. facesGl .. "\n"
            local parentName = boneInfo.parent
            local pos = v:getPos() / 39.37008
            local ang = v:getAngles()
            boneString = boneString .. string.format("#%s;%s,%s,%s;%s,%s,%s%s\n", name, pos.x, pos.y, pos.z, ang.p, ang.y, ang.r, parentName and ";" .. parentName or "")
        end
        return boneString .. "\n" .. objData
    end
end

hook.add("Think", "ModelEntityParameterUpdateBones", function()
    for _, ent in pairs(model.inited) do
        if !isValid(ent) then goto cont end
        local col = ent:getColor()
        if ent.color ~= col then
            ent:recursiveFun("setColor", col)
            ent.color = col
        end

        local mat = ent:getMaterial()
        if ent.material ~= mat then
            ent:recursiveFun("setMaterial", mat)
            ent.material = mat
        end

        for i=1, ent.modelInfo.submaterialCount do
            local submaterial = ent:getSubMaterial(i)
            if ent.submaterials[i] ~= submaterial then
                ent:recursiveFun("setSubMaterial", i, mat)
                ent.submaterials[i] = submaterial
            end
        end

        local renderFX = ent:getRenderFX()
        if ent.renderFX ~= renderFX then
            ent:recursiveFun("setRenderFX", renderFX)
            ent.renderFX = renderFX
        end

        local noDraw = ent:getNoDraw()
        if ent.noDraw ~= noDraw then
            ent:recursiveFun("setNoDraw", noDraw)
            ent.noDraw = noDraw
        end
        ::cont::
    end
end)

---@class Layer
---@field offset Vector
---@field angle Angle

---@class BoneEntity: Entity
---@field identifier string Identifier of bone
---@field layers table<number, Layer> Animation layers
---@field offset Vector Initial offset of bone
local BoneEntity = {}

function BoneEntity:recursiveFun(fun, ...)
    recursiveFun(self, fun, ...)
end

---[CLIENT] Set local to parent position for layer for animations
---@param layer number Layer to set
---@param pos Vector Position to set
function BoneEntity:setLocalPosLayer(layer, pos)
    local layerData = self.layers[layer]
    local currentOffset = self:getLocalPos()
    if !layerData then
        self.layers[layer] = {
            offset = pos,
            angle = Angle()
        }
        self:setLocalPos(currentOffset + pos)
        return
    end
    layerData.offset = pos
    local offset = Vector()
    for _, v in pairs(self.layers) do
        offset = offset + v.offset
    end
    self:setLocalPos(self.offset + offset)
end

---[CLIENT] Set local to parent angles for layer for animations
---@param layer number Layer to set
---@param angs Angle Angles to set
function BoneEntity:setLocalAnglesLayer(layer, angs)
    local layerData = self.layers[layer]
    local currentAngles = self:getLocalAngles()
    if !layerData then
        self.layers[layer] = {
            offset = Vector(),
            angle = angs
        }
        return
        self:setLocalAngles(currentAngles + angs)
    end
    layerData.angle = angs
    local angle = Angle()
    for _, v in pairs(self.layers) do
        angle = angle + v.angle
    end
    self:setLocalAngles(angle)
end

---[CLIENT] Get local to parent position for layer
---@param layer number Layer to get
---@return Vector pos Layer position
function BoneEntity:getLocalPosLayer(layer)
    local layerData = self.layers[layer]
    return layerData and layerData.offset or Vector()
end

---[CLIENT] Get local to parent angles for layer
---@param layer number Layer to get
---@return Angle angles Layer angles
function BoneEntity:getLocalAnglesLayer(layer)
    local layerData = self.layers[layer]
    return layerData and layerData.angle or Angle()
end

---[CLIENT] Get properties for layer (for tween lib)
---@param layer number Layer to get
---@return ParamProperty pos Layer position property
---@return ParamProperty angles Layer angles property
function BoneEntity:getPropertyForLayer(layer)
    return {
        set = function(propEnt, toSet)
            propEnt:setLocalPosLayer(layer, toSet)
        end,
        get = function(propEnt)
            return propEnt:getLocalPosLayer(layer)
        end
    }, {
        set = function(propEnt, toSet)
            propEnt:setLocalAnglesLayer(layer, toSet)
        end,
        get = function(propEnt)
            return propEnt:getLocalAnglesLayer(layer)
        end
    }
end

---[CLIENT] Set no draw for entire bone
---@param state boolean State of no draw
function BoneEntity:setNoDraw(state)
    self:recursiveFun("setNoDraw", state)
    self.noDraw = true
    if !self.modelRig then
        self:__setNoDrawOld(state)
    end
end

---[SHARED] Set submaterial for this model
---@param index number Submaterial index. 0 is default for all
---@param mat string Material to set
function BoneEntity:setSubMaterial(index, mat)
    self:recursiveFun(function(holo)
        if holo.modelSubmaterial == index then
            holo:setMaterial(mat)
        end
    end)
end

---[SHARED] Set main material for this model
---@param mat string Material to set
function BoneEntity:setMaterial(mat)
    self:recursiveFun("setMaterial", mat)
end


---[SHARED] Set color for this bone
---@param col Color Color to set
function BoneEntity:setColor(col)
    self:recursiveFun(function(holo)
        local initCol = holo.modelInitialColor
        if !initCol then return end
        holo:setColor(Color(
            multiplyColor(initCol[1], col[1]),
            multiplyColor(initCol[2], col[2]),
            multiplyColor(initCol[3], col[3]),
            col[4]
        ))
    end)
    if !self.modelRig then
        local initCol = self.modelInitialColor
        if !initCol then return end
        self:__setColorOld(Color(
            multiplyColor(initCol[1], col[1]),
            multiplyColor(initCol[2], col[2]),
            multiplyColor(initCol[3], col[3]),
            col[4]
        ))
    end
end

---[CLIENT] Get no draw for bone
---@return boolean state State of no draw
function BoneEntity:getNoDraw()
    return self.noDraw == true
end


---Override methods of entity to work with models
---@param self ModelInfo
---@param ent Entity
---@return ModelEntity
local function modelMethodsOverride(self, ent)
    ent.modelInfo = self
    ent.sequences = {}
    ent.poseParameters = {}
    for name, v in pairs(ModelEntity) do
        local old = "__" .. name .. "Old"
        ent[old] = ent[old] or ent[name]
        ent[name] = v
    end
    ---@cast ent ModelEntity

    return ent
end


---Override methods of entity to work with models (as bone)
---@param ent Entity
---@return BoneEntity
local function boneMethodsOverride(ent)
    ent.offset = ent:getLocalPos()
    ent.modelBone = true
    ent.layers = {}
    for name, v in pairs(BoneEntity) do
        local old = "__" .. name .. "Old"
        ent[old] = ent[old] or ent[name]
        ent[name] = v
    end
    ---@cast ent BoneEntity

    return ent
end



if SERVER then
    ---[SERVER] Sync holograms to clients
    function model.sync(ply)
        local newToNetwork = {}
        for id, toNetworkInfo in pairs(model.toNetwork) do
            local origin = entity(id)
            if !isValid(origin) then goto cont end
            newToNetwork[id] = toNetworkInfo
            ::cont::
        end
        model.toNetwork = newToNetwork
        net.start("NetworkModels")
            net.writeTable(model.toNetwork)
        net.send(ply or find.allPlayers())
    end

    hook.add("ClientInitialized", "InitializeModels", function(ply)
        if table.isEmpty(model.toNetwork) then return end
        model.sync(ply)
    end)
else
    ---@class MeshPretend
    ---@field holo Hologram
    ---@field part string

    ---Class to create custom mesh for holograms
    ---@class CMesh
    ---@field id string
    ---@field url string? [SERVER] URL of custom mesh to load
    ---@field data string? [CLIENT] OBJ data of custom mesh
    ---@field mesh Mesh? [CLIENT] Loaded mesh
    ---@field material string [CLIENT] Material to set
    ---@field pretendsToIt MeshPretend[] [CLIENT] Holograms, that pretends to this mesh, when it not loaded
    local CMesh = {}
    CMesh.__index = CMesh


    ---[CLIENT] Set material ID to set for all parts of this mesh
    ---@param id string Identifier of material
    function CMesh:setMaterial(id)
        self.material = id
    end

    ---[CLIENT] Load CMesh
    function CMesh:load()
        model.mesh[self.id] = self
        model.meshToLoad[#model.meshToLoad+1] = self
        http.get(self.url, function(data)
            self.data = data
        end)
    end

    ---[CLIENT] Create new mesh
    ---@param id string
    ---@param url string URL or file path to mesh
    ---@return CMesh
    function model.newMesh(id, url)
        return setmetatable({ id = id, pretendsToIt = {}, url = url }, CMesh)
    end

    local meshLoadCoroutine = coroutine.wrap(function()
        while true do
            coroutine.yield()
            local newToLoad = {}
            for _, v in ipairs(model.meshToLoad) do
                do
                    if v.mesh then goto cont end
                    if !v.data then goto cont end
                    v.mesh = mesh.createFromObj(v.data, true)
                    for _, pretendent in ipairs(v.pretendsToIt) do
                        if !isValid(pretendent.holo) then goto cont end
                        v:setTo(pretendent.holo, pretendent.part)
                        ::cont::
                    end
                    v.pretendsToIt = {}
                    goto cont1
                end
                ::cont::
                newToLoad[#newToLoad+1] = v
                ::cont1::
            end
            model.meshToLoad = newToLoad
        end
    end)

    local emptyMesh = mesh.createEmpty()

    local function createAfterNetworking(ent, toNetworkInfo)
        if !isValid(ent) or ent.modelBones or !toNetworkInfo then return end
        local mdl = model.registered[toNetworkInfo.modelId]
        if !mdl then return end
        local class = ent:getClass()
        if (class == "starfall_prop" or class == "starfall_hologram") and ent:getRenderMode() == RENDERMODE.NONE then
            ent:setMesh(emptyMesh)
            ent:setRenderMode(RENDERMODE.NORMAL)
        end
        mdl:create(ent)
        modelMethodsOverride(mdl, ent)
        for _, funcTable in ipairs(toNetworkInfo.params) do
            if !ent[funcTable[1]] then goto cont end
            ent[funcTable[1]](ent, unpack(funcTable[2]))
            ::cont::
        end
    end

    net.receive("NetworkModels", function()
        model.networked = net.readTable()
        for id, toNetworkInfo in pairs(model.networked) do
            local ent = entity(id)
            createAfterNetworking(ent, toNetworkInfo)
        end
    end)

    hook.add("Think", "CustomMeshLoad", function()
        if next(model.meshToLoad) ~= nil then
            local maxQuota = quotaMax() / 4
            local currentQuota = quotaAverage()
            if currentQuota > maxQuota then return end
            for _=1, math.floor(maxQuota / currentQuota) do
                meshLoadCoroutine()
            end
        end
    end)

    hook.add("NetworkEntityCreated", "NetworkModels", function(ent)
        local id = ent:entIndex()
        local toNetworkInfo = model.networked[id]
        createAfterNetworking(ent, toNetworkInfo)
    end)

    ---[CLIENT] Set this mesh to hologram
    ---@param holo Hologram Hologram to set
    ---@param part string Part to set (mesh table key)
    function CMesh:setTo(holo, part)
        if self.mesh then
            holo:setMesh(self.mesh[part])
            local mat = model.materials[self.material]
            if mat then
                holo:setMeshMaterial(mat)
            end
            return
        end
        self.pretendsToIt[#self.pretendsToIt+1] = {holo = holo, part = part}
    end

    ---@alias MaterialShader
    ---| '"UnlitGeneric"'"
    ---| '"VertexLitGeneric"'"
    ---| '"Refract_DX90"'"
    ---| '"Water_DX90"'"
    ---| '"Sky_DX9"'
    ---| '"gmodscreenspace"'
    ---| '"Modulate_DX9"'

    ---[CLIENT] Create new custom material
    ---@param id string
    ---@param shader MaterialShader
    ---@return Material
    function model.newMaterial(id, shader)
        local mat = material.create(shader)
        model.materials[id] = mat
        return mat
    end

    hook.add("Think", "ModelSequences", function()
        local cur = timer.curtime()
        for _, v in pairs(model.inited) do
            if !isValid(v) then goto cont end
            for layer, sequence in pairs(v.sequences) do
                local process = cur - sequence.start
                local duration = sequence.duration
                local ended = sequence.process(process)
                if duration == 0 then
                    if ended then sequence.start = timer.curtime() end
                    goto cont
                end
                if process > duration then
                    v.sequences[layer] = nil
                    goto cont
                end
                ::cont::
            end
            ::cont::
        end
    end)

    net.receive("ModelCallFunctions", function()
        local funcs = net.readTable()
        net.readEntity(function(ent)
            if !model.inited[ent:entIndex()] then return end
            for _, funcTable in ipairs(funcs) do
                if !ent[funcTable[1]] then goto cont end
                ent[funcTable[1]](ent, unpack(funcTable[2]))
                ::cont::
            end
        end)
    end)
end

local function recursiveRemove(ent)
    if !isValid(ent) then return end
    for _, v in pairs(ent:getChildren()) do
        recursiveRemove(v)
    end
    ent:remove()
end

hook.add("EntityRemoved", "ModelRemove", function(ent, fullupdate)
    if CLIENT then
        if isValid(ent) and ent.modelBones then
            if !fullupdate then
                for _, v in ipairs(ent.modelBones) do
                    if !isValid(v) then goto cont end
                    recursiveRemove(v)
                    ::cont::
                end
                model.networked[ent:entIndex()] = nil
            end
        end
    else
        model.toNetwork[ent:entIndex()] = nil
    end
end)


---[SHARED] Sets rig visibility on creation. Call before rig()
---@param state boolean
function model.setRigVisible(state)
    model.rigVisible = state
end

local rigScale = Vector(0.2, 0.2, 0.2)
---[SHARED] Create rig hologram (invisible with static model)
---@param pos Vector? Position offset. Default `Vector(0, 0, 0)`
---@param ang Angle? Angle offset. Default `Angle(0, 0, 0)`
---@return modelfun
function model.rig(pos, ang)
    pos = pos or Vector()
    ang = ang or Angle()
    return function()
        if !hologram.canSpawn() then return end
        local holo = hologram.create(pos, ang, model.rigModel, rigScale)
        if !holo then return end
        holo:suppressEngineLighting(true)
        holo:setNoDraw(!model.rigVisible)
        holo.modelRig = true
        return holo
    end
end

local polygons = 32

local cylinder = {}
for i=1,polygons do
    local ang = math.rad((360 / polygons) * i)
    local x = math.cos(ang)
    local y = math.sin(ang)
    cylinder[#cylinder+1] = Vector(x, y, 1)
    cylinder[#cylinder+1] = Vector(x, y, -1)
end

---@alias VertexType
---| '"cube"'
---| '"custom"'
---| '"wedge"'
---| '"cylinder"'
local VertexType = {
    ["cube"] = {
        Vector(1, 1, 1), Vector(1, -1, 1), Vector(-1, -1, 1), Vector(-1, 1, 1),
        Vector(1, 1, -1), Vector(1, -1, -1), Vector(-1, -1, -1), Vector(-1, 1, -1)
    },
    ["wedge"] = {
        Vector(1, -1, -1), Vector(1, 1, -1),
        Vector(-1, 1, -1), Vector(-1, -1, -1),
        Vector(-1, 1, 1), Vector(-1, -1, 1),
    },
    ["cylinder"] = cylinder
}

---@class VertexParameters
---@field type VertexType?
---@field offset Vector?
---@field angle Angle?
---@field scale Vector?
---@field vertices Vector[]?

local rotMat = {
    x = function(a)
        return {
            Vector(1, 0, 0),
            Vector(0, math.cos(a), -math.sin(a)),
            Vector(0, math.sin(a), math.cos(a)),
        }
    end,
    y = function(a)
        return {
            Vector(math.cos(a), 0, math.sin(a)),
            Vector(0, 1, 0),
            Vector(-math.sin(a), 0, math.cos(a)),
        }
    end,
    z = function(a)
        return {
            Vector(math.cos(a), -math.sin(a), 0),
            Vector(math.sin(a), math.cos(a), 0),
            Vector(0, 0, 1),
        }
    end
}

---[SHARED] Create new vertex
---@param tbl VertexParameters
---@return Vector[]
function model.vertex(tbl)
    local type = tbl.type or tbl[1] or "custom"
    local offset = tbl.offset or tbl[2] or Vector()
    local angle = tbl.angle or tbl[3] or Angle()
    local scale = tbl.scale or tbl[4] or Vector(1, 1, 1)
    local byType = VertexType[type]
    local vertices = byType and table.copy(byType) or tbl.vertices or tbl[5]
    local mats = {
        x = rotMat.x(math.rad(angle.p)),
        y = rotMat.y(math.rad(angle.y)),
        z = rotMat.z(math.rad(angle.r)),
    }
    for vId, v in ipairs(vertices) do
        local pos = v * scale
        local pZ = Vector(mats.z[1]:dot(pos), mats.z[2]:dot(pos), mats.z[3]:dot(pos))
        local pY = Vector(mats.y[1]:dot(pZ), mats.y[2]:dot(pZ), mats.y[3]:dot(pZ))
        local pX = Vector(mats.x[1]:dot(pY), mats.x[2]:dot(pY), mats.x[3]:dot(pY))
        vertices[vId] = pX + offset
    end
    return vertices
end


---@class HitboxParameters
---@field freeze boolean?
---@field mass number?
---@field material string?
---@field visible boolean?
---@field buoyancyRatio number?


-- TODO: i can set mesh for custom prop. maybe can make less holos
---[SHARED] Create new vertex
---@param tbl HitboxParameters
---@return modelfun
function model.hitbox(tbl)
    if CLIENT then return model.rig(Vector()) end
    local freeze = tbl.freeze or (isbool(tbl[1]) and tbl[1]) or false
    local mass = tbl.mass or (isnumber(tbl[2]) and tbl[2]) or 30
    local mat = tbl.material or (isstring(tbl[3]) and tbl[3]) or ""
    local visible = tbl.visible or (isbool(tbl[4] and tbl[4])) or false
    local buoyancyRatio = tbl.buoyancyRatio or (isnumber(tbl[5]) and tbl[5]) or 0
    local vertexes = {}
    for i, v in ipairs(tbl) do
        vertexes[i] = v
    end
    return function()
        local pr = prop.createCustom(Vector(), Angle(), vertexes, true)
        local phys = pr:getPhysicsObject()
        pr:setFrozen(freeze)
        -- pr:setNoDraw(!visible)
        pr.buoyancyRatio = buoyancyRatio
        timer.simple(0, function()
            pr:setRenderMode(RENDERMODE.NONE)
            if !isValid(phys) then return end
            phys:setMass(mass)
            phys:setMaterial(mat)
            phys:setBuoyancyRatio(buoyancyRatio)
        end)
        return pr
    end
end

if SERVER then
    local function setBuoyancy(ent)
        local phys = ent:getPhysicsObject()
        if !isValid(phys) then return end
        phys:setBuoyancyRatio(ent.buoyancyRatio)
    end

    hook.add("OnEntityWaterLevelChanged", "HitboxSetBuoyancyInWater", function(ent, old, new)
        if new > 0 and ent.buoyancyRatio then
            setBuoyancy(ent)
        end
    end)

    hook.add("PhysgunDrop", "HitboxSetBuoyancyInWater", function(ply, ent)
        if !ent.buoyancyRatio then return end
        timer.simple(0, function()
            if !isValid(ent) then return end
            if ent:getWaterLevel() > 0 then
                setBuoyancy(ent)
            end
        end)
    end)
end


model.partsHolos = {}
local partCreateHolosCoroutine = coroutine.wrap(function(...)
    while true do
        coroutine.yield()
        local newPartsHolos = {}
        for _, v in ipairs(model.partsHolos) do
            do
                if quotaAverage() > quotaMax() / 4 then
                    coroutine.yield()
                end
                local holo = v[1]()
                if !holo then goto cont end
                local offset = holo:getLocalPos()
                local ang = holo:getLocalAngles()
                local initCol = holo.modelInitialColor
                if initCol then
                    local col = v[2]:getColor()
                    holo:setColor(Color(
                        multiplyColor(initCol[1], col[1]),
                        multiplyColor(initCol[2], col[2]),
                        multiplyColor(initCol[3], col[3]),
                        col[4]
                    ))
                end
                holo:setNoDraw(v[2]:getNoDraw())
                holo:setParent(v[2])
                holo:setLocalPos(offset)
                holo:setLocalAngles(ang)
                goto cont1
            end
            ::cont::
            newPartsHolos[#newPartsHolos+1] = v
            ::cont1::
        end
        model.partsHolos = newPartsHolos
    end
end)
hook.add("Think", "PartCreateHolos", partCreateHolosCoroutine)


---[SHARED] Create new part - sequence of holos, parented to first in sequence
---@param tbl modelfun[]
---@return modelfun
function model.part(tbl)
    return function()
        local parent
        for _, fn in ipairs(tbl) do
            if !parent then
                parent = fn()
                goto cont
            end
            model.partsHolos[#model.partsHolos+1] = {fn, parent}
            ::cont::
        end
        return parent
    end
end

---@class Clip
---@field [1] Vector Offset of clip, relative to entity
---@field [2] Vector Normal of clip, relative to entity

---@class HoloParameters
---@field pos Vector? Position offset to spawn this holo. Relative to model
---@field ang Angle? Angle offset to spawn this holo. Relative to model
---@field model string? Model of this holo
---@field scale Vector? Scale of this holo
---@field size Vector? Hologram size. Scale multiplies start size of holo, when size sets... size :D
---@field submaterial number? Submaterial append holo to. By default 0 (WIP, not working)
---@field subcolor number? Subcolor append holo to. By default 0. (WIP, not working)
---@field material string|table? Material to set. Can be identifier for custom material, or material file, or table of submaterials
---@field color Color? Color of holo
---@field noLight boolean? Suppress engine lighting for holo
---@field mesh string? Mesh for holo
---@field meshPart string? Mesh part. You can found this lines in obj file: `o name_of_part`
---@field clips Clip[]? Clips of holo
---@field cullmode number? Cull mode of holo
---@field noColorize boolean? No colorize this holo when changing color with setColor, default false

local emptyColor = Color(255, 255, 255, 255)
local vectorNull = Vector()
local angleNull = Angle()
local scaleNull = Vector(1, 1, 1)

---[SHARED] Create hologram with extended parameters. On server does nothing
---@param tbl HoloParameters
---@return modelfun
function model.holo(tbl)
    local pos = tbl.pos or tbl[1] or vectorNull
    local ang = tbl.ang or tbl[2] or angleNull
    local mdl = tbl.model or tbl[3] or "models/holograms/cube.mdl"
    local scale = tbl.scale or tbl[4] or scaleNull
    local size = tbl.size or tbl[5]
    local submat = tbl.submaterial or tbl[6] or 0
    local subcol = tbl.subcolor or tbl[7] or 0
    local matName = tbl.material or tbl[8]
    local color = tbl.color or tbl[9] or emptyColor
    local noLight = tbl.noLight or tbl[10] or false
    local meshId = tbl.mesh or tbl[11]
    local meshPart = tbl.meshPart or tbl[12]
    local clips = tbl.clips or tbl[13] or {}
    local cullmode = tbl.cullmode or tbl[14] or 0
    local noColorize = tbl.noColorize or tbl[15]
    local funcToMat
    if matName then
        local function setMaterial(holo, index, funcMatName)
            local mat = model.materials[funcMatName]
            local matToSet = mat and "!" .. mat:getName() or funcMatName
            -- Submaterial fixes bug with client material reset (because Material URL)
            holo:setSubMaterial(index, matToSet)
        end
        if isstring(matName) then
            funcToMat = function(holo)
                setMaterial(holo, 0, matName)
            end
        elseif istable(matName) then
            funcToMat = function(holo)
                ---@cast matName table<number, string>
                for index, v in pairs(matName) do
                    setMaterial(holo, index, v)
                end
            end
        end
    end
    return function()
        if !hologram.canSpawn() then return end
        local holo = hologram.create(pos, ang, mdl, scale)
        if !holo then return end
        holo:suppressEngineLighting(noLight)
        holo:setCullMode(cullmode)
        if size then holo:setSize(size) end
        if funcToMat then funcToMat(holo) end
        holo:setColor(color)
        for i, v in ipairs(clips) do
            holo:setClip(i, true, size and v[1] + size or v[1] * scale, v[2], holo)
        end
        if CLIENT then
            local msh = model.mesh[meshId]
            if msh then msh:setTo(holo, meshPart) end
        end
        holo.modelSubcolor = subcol
        holo.modelSubmaterial = submat
        if !noColorize then holo.modelInitialColor = color end
        return holo
    end
end



---@class Bone
---@field parent string
---@field bone modelfun
---@field name string
---@field noDraw boolean

---@class ModelSequence
---@field name string
---@field startFun fun(ent: ModelEntity, layer: number): fun(process: number): boolean
---@field duration number

---@class PoseParameter
---@field name string
---@field min number
---@field max number

---@class ModelInfo
---@field origin fun()
---@field bones Bone[]
---@field bonesIDs table<string, number>
---@field sequences ModelSequence[]
---@field sequencesIDs table<string, number>
---@field poseParameters table<string, PoseParameter>
---@field submaterialCount number
---@field identifier string
local ModelInfo = {}
ModelInfo.__index = ModelInfo


---[SHARED] Create new model info
---@param identifier string Identifier of model
---@param origin Vector|modelfun Origin of this entity
---@return ModelInfo
function model.new(identifier, origin)
    local rig = isfunction(origin) and origin or model.rig(origin)
    local obj = setmetatable(
        { origin = rig, bones = {}, bonesIDs = {}, sequences = {}, sequencesIDs = {}, identifier = identifier, poseParameters = {}, submaterialCount = 0 },
        ModelInfo
    )
    model.registered[identifier] = obj
    return obj
end

---[SHARED] Add new bone to model
---@param parent string Identifier of bone to parent
---@param bone string|modelfun Identifier of bone
---@param mdl modelfun? Function to create model
---@return ModelInfo
function ModelInfo:add(parent, bone, mdl)
    local outName
    local outModel
    local outParent
    if !mdl then
        outName = parent
        outModel = bone
    else
        outParent = parent
        outName = bone
        outModel = mdl
    end
    local id = #self.bones+1
    self.bones[id] = {
        name = outName,
        parent = outParent,
        bone = outModel
    }
    self.bonesIDs[outName] = id
    return self
end

---[SHARED] Add sequence info to model
---@param name string Identifier of sequence
---@param duration number Duration of sequence
---@param startFun fun(ent: ModelEntity, layer: number): fun(process: number): boolean Start function
---@return ModelInfo
function ModelInfo:addSequence(name, duration, startFun)
    local id = #self.sequences+1
    self.sequences[id] = {
        startFun = startFun,
        duration = duration,
        name = name
    }
    self.sequencesIDs[name] = id
    return self
end

---[SHARED] Add pose parameter to model
---@param name string Identifier of sequence
---@param min number? Minimal value
---@param max number? Maximal value
---@return ModelInfo
function ModelInfo:addPoseParameter(name, min, max)
    self.poseParameters[name] = {
        name = name,
        min = min or -32768,
        max = max or 32768
    }
    return self
end


---@param origin Entity? Origin to parent
---@return ModelEntity?
function ModelInfo:create(origin)
    local originHolo = origin or self.origin()
    if !originHolo or !isValid(originHolo) then
        throw("Can't create origin")
        return
    end
    local id = originHolo:entIndex()
    if SERVER then
        model.toNetwork[id] = {
            modelId = self.identifier,
            params = {},
            paramsToSend = {}
        }
        model.sync()
        originHolo = modelMethodsOverride(self, originHolo)
        model.inited[id] = originHolo
        return originHolo
    end
    ---@type table<string, Entity>
    local bones = {}
    for i, part in ipairs(self.bones) do
        if !part then goto cont end
        local holo = part.bone()
        if !holo then goto cont end
        holo.identifier = part.name
        boneMethodsOverride(holo)
        bones[i] = holo
        local parent = part.parent
        local parentHolo = bones[self.bonesIDs[parent]] or (!parent and originHolo)
        if !parentHolo then
            throw(string.format("Parent \"%s\" for \"%s\" not found! Maybe you placed it in incorrect sequence?", parent, part.name))
            return
        end
        local pos, ang = localToWorld(holo:getPos(), holo:getAngles(), parentHolo:getPos(), parentHolo:getAngles())
        holo:setPos(pos)
        holo:setAngles(ang)
        holo:setParent(parentHolo)
        ::cont::
    end
    originHolo = modelMethodsOverride(self, originHolo)
    originHolo.modelBones = bones
    model.inited[id] = originHolo
    return originHolo
end


---[SHARED] Create model by registered model info
---@param identifier string Identifier of the model
---@return ModelEntity?
function model.create(identifier)
    local mdl = model.registered[identifier]
    return mdl:create()
end


return model

