---@name Model
---@author AstricUnion

---@class Sequence
---@field id number ID of sequence to start
---@field start number Relative to curtime
---@field duration number Duration of sequence
---@field process fun(process: number): boolean Relative to curtime

---@class ModelEntity: Entity
---@field identifier string Identifier of model
---@field modelInfo ModelInfo Model info
---@field modelBones BoneEntity[] [CLIENT] Model bones entities, by number
---@field sequences table<number, Sequence> [CLIENT] Layers of sequences
---@field poseParameters table<string, number> [CLIENT] Pose parameters for this entity

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

    hologram.__createOld = hologram.__createOld or hologram.create
    function hologram.create(...)
        local holo = hologram.__createOld(...)
        if !holo then return end
        holo.children = {}
        holo.__setParentOld = holo.__setParentOld or holo.setParent
        holo.setParent = setParent
        holo.__getChildrenOld = holo.__getChildrenOld or holo.getChildren
        holo.getChildren = getChildren
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
---@field materials table<string, Material>
local model = {}
model.registered = {}
model.inited = {}
model.mesh = {}
model.meshToLoad = {}
model.materials = {}
model.toNetwork = {}
model.networked = {}
model.rigVisible = false

---@alias modelfun fun(): (Entity?)

local function boneMethodsOverride(ent)
    ---@class BoneEntity
    local ent = ent

    if CLIENT then
        ent.layers = {}
        ent.offset = ent:getLocalPos()

        ---[CLIENT] Set local to parent position for layer for animations
        ---@param layer number Layer to set
        ---@param pos Vector Position to set
        function ent:setLocalPosLayer(layer, pos)
            local layerData = ent.layers[layer]
            local currentOffset = ent:getLocalPos()
            if !layerData then
                ent.layers[layer] = {
                    offset = pos,
                    angle = Angle()
                }
                ent:setLocalPos(currentOffset + pos)
                return
            end
            layerData.offset = pos
            local offset = Vector()
            for _, v in pairs(ent.layers) do
                offset = offset + v.offset
            end
            ent:setLocalPos(ent.offset + offset)
        end

        ---[CLIENT] Set local to parent angles for layer for animations
        ---@param layer number Layer to set
        ---@param angs Angle Angles to set
        function ent:setLocalAnglesLayer(layer, angs)
            local layerData = ent.layers[layer]
            local currentAngles = ent:getLocalAngles()
            if !layerData then
                ent.layers[layer] = {
                    offset = Vector(),
                    angle = angs
                }
                return
                ent:setLocalAngles(currentAngles + angs)
            end
            layerData.angle = angs
            local angle = Angle()
            for _, v in pairs(ent.layers) do
                angle = angle + v.angle
            end
            ent:setLocalAngles(angle)
        end

        ---[CLIENT] Get local to parent position for layer
        ---@param layer number Layer to get
        ---@return Vector pos Layer position
        function ent:getLocalPosLayer(layer)
            local layerData = ent.layers[layer]
            return layerData and layerData.offset or Vector()
        end

        ---[CLIENT] Get local to parent angles for layer
        ---@param layer number Layer to get
        ---@return Angle angles Layer angles
        function ent:getLocalAnglesLayer(layer)
            local layerData = ent.layers[layer]
            return layerData and layerData.angle or Angle()
        end

        ---[CLIENT] Get properties for layer (for tween lib)
        ---@param layer number Layer to get
        ---@return ParamProperty pos Layer position property
        ---@return ParamProperty angles Layer angles property
        function ent:getPropertyForLayer(layer)
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
    end
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


---Override methods of entity to work with models
---@param ent Entity
---@return ModelEntity
local function modelMethodsOverride(ent)
    ---@class ModelEntity
    local ent = ent

    local function recursiveFun(origin, fun, ...)
        for _, v in pairs(origin.modelBones or origin:getChildren()) do
            if isfunction(fun) then
                fun(v, ...)
            else
                if v[fun] then v[fun](v, ...) end
            end
            recursiveFun(v, fun, ...)
        end
    end

    local entId = ent:entIndex()
    local networking = false
    local function sendFunction(func, ...)
        if !SERVER or !ent.modelBones then return end
        local args = {...}
        local toNetwork = model.toNetwork[entId]
        if !toNetwork then return end
        local params = toNetwork.paramsToSend
        local globalParams = toNetwork.params
        local tab = {func, args}
        params[#params+1] = tab
        globalParams[#globalParams+1] = tab
        if networking then return end
        networking = true
        timer.simple(0, function()
            if !isValid(ent) then return end
            net.start("ModelCallFunctions")
                net.writeTable(params)
                net.writeEntity(ent)
            net.send(find.allPlayers())
            table.empty(params)
            networking = false
        end)
    end
    -- I can use ent, not self, because this is method only for this entity
    ent.__setNoDrawOld = ent.__setNoDrawOld or ent.setNoDraw
    function ent:setNoDraw(state)
        ent.noDraw = state
        sendFunction("setNoDraw", state)
        recursiveFun(ent, "setNoDraw", state)
    end

    ent.__getNoDrawOld = ent.__getNoDrawOld or ent.getNoDraw
    function ent:getNoDraw()
        return ent.noDraw
    end

    ent.__setCullModeOld = ent.__setCullModeOld or ent.setCullMode
    function ent:setCullMode(state)
        for _, v in pairs(ent:getChildren()) do
            v:setCullMode(state)
        end
    end

    ent.__lookupBoneOld = ent.__lookupBoneOld or ent.lookupBone
    ---[SHARED] Lookup for bone in entity
    ---@param name string Name of the bone
    ---@return number id
    function ent:lookupBone(name)
        return ent.modelInfo.bonesIDs[name] or -1
    end

    ent.__lookupSequenceOld = ent.__lookupSequenceOld or ent.lookupSequence
    ---[SHARED] Lookup for sequence in entity
    ---@param name string Name of the sequence
    ---@return number id
    function ent:lookupSequence(name)
        return ent.modelInfo.sequencesIDs[name] or -1
    end

    ent.__getSequenceOld = ent.__getSequenceOld or ent.getSequence
    ---[SHARED] Returns current entity sequence
    ---@param layer number? Layer of animation
    ---@return number id
    function ent:getSequence(layer)
        local seq = ent.sequences[layer or 0]
        return seq and seq.id or 0
    end

    ent.__setSequenceOld = ent.__setSequenceOld or ent.setSequence
    ---[SHARED] Set sequence for this entity
    ---@param id number Sequence ID
    ---@param layerId number? Sequence layer ID. 0 is default
    function ent:setSequence(id, layerId)
        layerId = layerId or 0
        sendFunction("setSequence", id, layerId)
        if CLIENT then
            local seq = ent.modelInfo.sequences[id]
            if !seq then
                ent.sequences[layerId] = nil
                return
            end
            local sequence = {}
            ent.sequences[layerId] = sequence
            local process = seq.startFun(ent, layerId)
            sequence.id = id
            sequence.start = timer.curtime()
            sequence.process = process
            sequence.duration = seq.duration
        end
    end

    ent.__getPoseParameterOld = ent.__getPoseParameterOld or ent.getPoseParameter
    ---[SHARED] Returns current entity pose parameter
    ---@param name string Name of pose parameter
    ---@return number value
    function ent:getPoseParameter(name)
        return ent.poseParameters[name] or 0
    end

    ent.__setPoseParameterOld = ent.__setPoseParameterOld or ent.setPoseParameter
    ---[SHARED] Set pose parameter for this entity
    ---@param name string Name of pose parameter
    ---@param value number Value to set
    function ent:setPoseParameter(name, value)
        sendFunction("setPoseParameter", name, value)
        if CLIENT then
            local param = ent.modelInfo.poseParameters[name]
            if !param then return end
            ent.poseParameters[name] = math.clamp(value, param.min, param.max)
        end
    end

    ent.__setSubMaterialOld = ent.__setSubMaterialOld or ent.setSubMaterial
    ---[SHARED] Set submaterial for this model
    ---@param index number Submaterial index. 0 is default for all
    ---@param mat string Material to set
    function ent:setSubMaterial(index, mat)
        sendFunction("setSubMaterial", index, mat)
        recursiveFun(ent, index ~= -1 and function(holo)
            if holo.modelSubmaterial == index then
                holo:setSubMaterial(0, mat)
            end
        end)
    end

    ent.__setMaterialOld = ent.__setMaterialOld or ent.setMaterial
    ---[SHARED] Set main material for this model
    ---@param mat string Material to set
    function ent:setMaterial(mat)
        sendFunction("setMaterial", mat)
        recursiveFun(ent, "setSubMaterial", 0, mat)
    end

    ---[SHARED] Set subcolor for this model
    ---@param index number Color index. 0 is default for all
    ---@param col Color Color to set
    function ent:setSubColor(index, col)
        sendFunction("setSubColor", index, col)
        recursiveFun(ent, function(holo)
            if holo.modelSubcolor == index then
                holo:setColor(col)
            end
        end)
    end

    ent.__setColorOld = ent.__setColorOld or ent.setColor
    ---[SHARED] Set color for this model
    ---@param col Color Color to set
    function ent:setColor(col)
        sendFunction("setColor", col)
        recursiveFun(ent, "setColor", col)
    end

    ent.__setRenderFXOld = ent.__setRenderFXOld or ent.setRenderFX
    ---[SHARED] Set render FX for this model
    ---@param renderFx number Render FX. RENDERFX enum
    function ent:setRenderFX(renderFx)
        sendFunction("setRenderFX", renderFx)
        recursiveFun(ent, "setRenderFX", renderFx)
    end

    if CLIENT then
        ent.__drawOld = ent.__drawOld or ent.draw
        function ent:draw(noTint)
            recursiveFun(ent, "draw", noTint)
        end

        ---[CLIENT] Get entity of the bone
        ---@param id number Index of the bone
        ---@return BoneEntity?
        function ent:getBoneEntity(id)
            return ent.modelBones[id]
        end

        ---[CLIENT] Get OBJ with rig for Blender
        ---@return string mdlData
        function ent:getObj()
            local objData = ""
            local boneString = ""
            local offset = 0
            local originPos, originAng = ent:getPos(), ent:getAngles()
            local boneInfos = self.modelInfo.bones
            for i, v in ipairs(self.modelBones) do
                local vertexesGl = ""
                local normalsGl = ""
                local facesGl = ""
                for _, child in pairs(v:getChildren()) do
                    if child == v then goto cont end
                    local pos, ang = worldToLocal(child:getPos(), child:getAngles(), originPos, originAng)
                    local vertexes, normals, faces, num = objFromModel(child:getModel(), pos, ang, child:getScale(), offset)
                    offset = offset + num
                    vertexesGl = vertexesGl .. vertexes
                    normalsGl = normalsGl .. normals
                    facesGl = facesGl .. faces
                    ::cont::
                end
                local boneInfo = boneInfos[i]
                local name = boneInfo.name
                objData = objData .. "o " .. name .. vertexesGl .. normalsGl .. facesGl .. "\n"
                local parentName = boneInfo.parent
                local pos = v:getPos() / 39.37008
                local ang = v:getAngles()
                boneString = boneString .. string.format("#%s;%s,%s,%s;%s,%s,%s;%s\n", name, pos.x, pos.y, pos.z, ang.p, ang.y, ang.r, parentName)
            end
            return boneString .. "\n" .. objData
        end
    end

    return ent
end

if SERVER then
    local networking = false

    ---[SERVER] Sync holograms to clients
    ---@param ply Player? Player to send. False to prevent send (to clear toNetwork)
    function model.sync(ply)
        local newToNetwork = {}
        for id, toNetworkInfo in pairs(model.toNetwork) do
            local origin = entity(id)
            if !isValid(origin) then goto cont end
            newToNetwork[id] = toNetworkInfo
            ::cont::
        end
        model.toNetwork = newToNetwork
        if networking then return end
        networking = true
        timer.simple(0, function()
            net.start("NetworkModels")
                net.writeTable(model.toNetwork)
            net.send(find.allPlayers())
            networking = false
        end)
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

    net.receive("NetworkModels", function()
        model.networked = net.readTable()
    end)

    local function getNetworkedModels()
        for id, toNetworkInfo in pairs(model.networked) do
            local ent = entity(id)
            if !isValid(ent) then goto cont end
            if ent.modelBones then
                model.networked[id] = nil
                return
            end
            local mdl = model.registered[toNetworkInfo.modelId]
            if !mdl then goto cont end
            mdl:create(ent)
            modelMethodsOverride(ent)
            for _, funcTable in ipairs(toNetworkInfo.params) do
                if !ent[funcTable[1]] then goto cont end
                ent[funcTable[1]](ent, unpack(funcTable[2]))
                ::cont::
            end
            model.networked[id] = nil
            ::cont::
        end
    end

    hook.add("Think", "CustomMeshLoad", function()
        if next(model.meshToLoad) ~= nil then
            local maxQuota = quotaMax() / 4
            local currentQuota = quotaAverage()
            if currentQuota > maxQuota then return end
            for _=1, math.floor(maxQuota / currentQuota) do
                meshLoadCoroutine()
            end
        end
        if !table.isEmpty(model.networked) then
            getNetworkedModels()
        end
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

    hook.add("RenderOffscreen", "ModelSequences", function()
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
            for _, v in ipairs(ent.modelBones) do
                if !isValid(v) then goto cont end
                recursiveRemove(v)
                ::cont::
            end
            model.networked[ent:entIndex()] = nil
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
        local holo = hologram.create(pos, ang, "models/editor/axis_helper_thick.mdl", rigScale)
        if !holo then return end
        holo:suppressEngineLighting(true)
        holo:setNoDraw(!model.rigVisible)
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
        pr:setNoDraw(!visible)
        pr.buoyancyRatio = buoyancyRatio
        timer.simple(0, function()
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
                coroutine.yield()
                local holo = v[1]()
                if !holo then goto cont end
                local offset = holo:getLocalPos()
                local ang = holo:getLocalAngles()
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

local emptyFunction = function() end

---[SHARED] Create hologram with extended parameters. On server does nothing
---@param tbl HoloParameters
---@return modelfun
function model.holo(tbl)
    local pos = tbl.pos or tbl[1] or Vector()
    local ang = tbl.ang or tbl[2] or Angle()
    local mdl = tbl.model or tbl[3] or "models/holograms/cube.mdl"
    local scale = tbl.scale or tbl[4] or Vector(1, 1, 1)
    local size = tbl.size or tbl[5]
    local submat = tbl.submaterial or tbl[6] or 0
    local subcol = tbl.subcolor or tbl[7] or 0
    local matName = tbl.material or tbl[8]
    local color = tbl.color or tbl[9] or Color(255, 255, 255, 255)
    local noLight = tbl.noLight or tbl[10] or false
    local meshId = tbl.mesh or tbl[11]
    local meshPart = tbl.meshPart or tbl[12]
    local clips = tbl.clips or tbl[13] or {}
    local cullmode = tbl.cullmode or tbl[14] or 0
    local funcToMat = emptyFunction
    if matName then
        local function setMaterial(holo, index, funcMatName)
            local mat = model.materials[funcMatName]
            local matToSet = mat and "!" .. mat:getName() or funcMatName
            -- Submaterial fixes bug with client material reset
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
        funcToMat(holo)
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
        return holo
    end
end



---@class Bone
---@field parent string
---@field bone modelfun
---@field name string

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
        { origin = rig, bones = {}, bonesIDs = {}, sequences = {}, sequencesIDs = {}, identifier = identifier, poseParameters = {} },
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

---@class Layer
---@field offset Vector
---@field angle Angle

---@class BoneEntity: Entity
---@field identifier string Identifier of bone
---@field layers table<number, Layer> Animation layers


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
        originHolo = modelMethodsOverride(originHolo)
        originHolo.identifier = self.identifier
        originHolo.modelBones = {}
        originHolo.modelInfo = self
        originHolo.sequences = {}
        originHolo.poseParameters = {}
        model.inited[id] = originHolo
        return originHolo
    end
    ---@type table<string, Entity>
    local bones = {}
    for i, part in ipairs(self.bones) do
        if !part then goto cont end
        local holo = part.bone()
        if !holo then goto cont end
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
    -- i will remove repeating code, i promise
    originHolo = modelMethodsOverride(originHolo)
    originHolo.identifier = self.identifier
    originHolo.modelBones = bones
    originHolo.modelInfo = self
    originHolo.sequences = {}
    originHolo.poseParameters = {}
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

