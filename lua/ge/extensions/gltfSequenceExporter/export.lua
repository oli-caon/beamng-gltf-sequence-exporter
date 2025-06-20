-- Modified from "BeamNG.drive/lua/ge/extensions/util/export.lua"
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Updated for BeamNG.drive v0.34+

local M = {}

local ffi = require("ffi")
local sbuffer = require('string.buffer')

local jbeamIO = require('jbeam/io')

local EXTENSION_JBEAM = "BNG_JBeamData"
local EXTENSION_DIRECTION = "BNG_Direction"
local abs = math.abs

if not _G['__gpuFlexMesh_t_cdef'] then
  ffi.cdef[[
  typedef struct gpuPrimitive_t {
    uint32_t startIndex;
    uint32_t indexCount;
    uint32_t materialId;
  } gpuPrimitive_t;
  ]]
  rawset(_G, '__gpuFlexMesh_t_cdef', true)
end

-- constants
local base64Prefix = "data:application/octet-stream;base64,"
local floatByteSize = ffi.sizeof('float')
local unsignedIntByteSize = ffi.sizeof('unsigned int')

local continueRecording = false
local framesRecorded = 0
local gltfRoot
local keyFrameTimes = {}
local timer = hptimer()
local binaryBuffers = {}

local lastMeshInfo
local bufferPathPattern = nil
local exportHandler = nil
local savedImages = {}

local originWorld = {x=0.0, y=0.0, z=0.0}
local currentTranslation = {x=0.0, y=0.0, z=0.0}

local gltfRootTemplate = {
  asset = {
    generator = beamng_appname .. " " .. beamng_versiond,
    version = "2.0"
  },
  scenes = {
    {
      nodes = {}
    }
  },
  nodes = {},
  materials = {},
  meshes = {},
  buffers = {},
  bufferViews = {},
  accessors = {},
  images = {},
  textures = {},
}

local _log = log
local function log(level, msg)
  _log(level, 'gltfSequenceExporter', msg)
end

local function dbgNodeName(gltfRoot, jsonIndex)
  local luaIndex = jsonIndex +1
  if gltfRoot.nodes[luaIndex] then
    return dumps(gltfRoot.nodes[luaIndex].name).."["..dumps(jsonIndex).."]"
  else
    return "NodeDoesNotExist!!!!["..dumps(jsonIndex).."]"
  end
end

local function _addBuffer(gltfRoot, data, dataSize, name)
  -- buffer table goes first
  local buffer = {
    byteLength = dataSize
  }
  table.insert(gltfRoot.buffers, buffer)
  local bufferID = #gltfRoot.buffers - 1

  if M.gltfBinaryFormat then
    table.insert(binaryBuffers, {data=data, len=dataSize})
    bufferID = #binaryBuffers - 1
  else
    local dataString = sbuffer.new()
    dataString:set(data, dataSize)

    -- then we encode or write the data out
    if M.embedBuffers then
      -- write index buffer in base64 encoding
      local res = mime.b64(dataString:get())
      if not res then
        log('E', 'Unable to base64 encode buffer.')
        return
      end
      buffer.uri = base64Prefix .. res
    else
      log('D', 'Buffers are to be stored externally.')
      local binaryFilename = string.format(bufferPathPattern, bufferID, name)
      writeFile(binaryFilename, dataString:get())
      local p, filename, ext
      p, filename, ext = path.split(binaryFilename)
      buffer.uri = filename
      log('D', 'Wrote buffer to: ' .. binaryFilename)
    end
  end
  return bufferID
end

local function _addBufferView(gltfRoot, bufferID, byteOffset, byteLength, name)
  -- then bufferview
  local bufferView = {
    buffer = bufferID,
    byteOffset = byteOffset,
    byteLength = byteLength,
  }
  if name then bufferView.name = name end
  table.insert(gltfRoot.bufferViews, bufferView)
  return #gltfRoot.bufferViews - 1
end

local function _addBufferviewAccessor(gltfRoot, bufferID, byteOffset, byteLength, accessor, name)
  local bufferViewId = _addBufferView(gltfRoot, bufferID, byteOffset, byteLength, name)

  -- then the accessor
  local _accessor = {
    bufferView = bufferViewId,
    byteOffset = 0,
  }
  tableMerge(_accessor, accessor)
  table.insert(gltfRoot.accessors, _accessor)
  local accessorID = #gltfRoot.accessors - 1
  return accessorID
end

local function _addTimeBuffers(gltfRoot)
  -- first, the times
  local timeBufferSize = #keyFrameTimes * floatByteSize
  local keyFrameTimes_c = ffi.new('float[' .. #keyFrameTimes .. ']', 0)
  for i = 1, #keyFrameTimes do
    keyFrameTimes_c[i - 1] = keyFrameTimes[i]
  end

  local accessor = {
    min = { keyFrameTimes[1] },
    max = { keyFrameTimes[#keyFrameTimes - 1] },
    componentType = 5126, -- 5126 = Float32Array.BYTES_PER_ELEMENT
    type = "SCALAR",
  }

  local bufferIDTimes = _addBuffer(gltfRoot, keyFrameTimes_c, timeBufferSize, 'time')
  local accessorIDTimes = _addBufferviewAccessor(gltfRoot, bufferIDTimes, 0, timeBufferSize, accessor, 'times')

  -- then the keyframes
  local keyframeNumbersBufferSize = #keyFrameTimes * unsignedIntByteSize
  local keyFrameNumbers_c = ffi.new('unsigned int[' .. #keyFrameTimes .. ']', 0)
  for i = 1, #keyFrameTimes do
    keyFrameNumbers_c[i - 1] = i - 1
  end

  accessor = {
    min = { 0 },
    max = { #keyFrameTimes - 1 },
    componentType = 5125, -- 5125 = Uint32Array.BYTES_PER_ELEMENT,
    type = "SCALAR",
  }

  local bufferIDKeyframes = _addBuffer(gltfRoot, keyFrameNumbers_c, keyframeNumbersBufferSize, 'keyframes')
  local accessorIDKeyframes = _addBufferviewAccessor(gltfRoot, bufferID, 0, keyframeNumbersBufferSize, accessor, 'keyframes')

  -- integration into gltf root
  local animSampler = gltfRoot.animations[1].samplers[1]
  animSampler.input = accessorIDTimes
  animSampler.output = accessorIDKeyframes
end

local function _addIndexBuffer(gltfRoot, meshInfo)
  local indices = ffi.new('unsigned int[?]', meshInfo.indicesCount)
  if not meshInfo:indicesGet(indices) then
    log('E', 'Cannot get indices (check that the size is right).')
  end
  return _addBuffer(gltfRoot, indices, meshInfo.indicesCount * unsignedIntByteSize, 'index')
end

local function _findBufferMinMax(count, buffer)
  local minx = math.huge
  local miny = math.huge
  local minz = math.huge
  local maxx = -math.huge
  local maxy = -math.huge
  local maxz = -math.huge
  for i = 0, (count - 1) * 3, 3 do
    local x = buffer[i]
    local y = buffer[i + 1]
    local z = buffer[i + 2]
    minx = math.min(minx, x)
    miny = math.min(miny, y)
    minz = math.min(minz, z)
    maxx = math.max(maxx, x)
    maxy = math.max(maxy, y)
    maxz = math.max(maxz, z)
  end
  return { min = { minx, miny, minz}, max = { maxx, maxy, maxz} }
end

local function _addBufferAndAccessor(gltfRoot, count, bufferSize, buffer, componentType, type, name, minMax)
  if minMax == nil then
    minMax = false
  end

  local accessor = {
    count = count,
    componentType = componentType,
    type = type
  }

  if minMax then
    local minMax = _findBufferMinMax(count, buffer)
    accessor.min = minMax.min
    accessor.max = minMax.max
  end

  local bufferID = _addBuffer(gltfRoot, buffer, bufferSize, name)
  return _addBufferviewAccessor(gltfRoot, bufferID, 0, bufferSize, accessor, name)
end

local function _addVec3Buffer(gltfRoot, count, buffer, name)
  return _addBufferAndAccessor(gltfRoot, count, count * floatByteSize * 3, buffer, 5126, "VEC3", name, true)
end

local function _addColorBuffer(gltfRoot, count, buffer, name)
  return _addBufferAndAccessor(gltfRoot, count, count * 4, buffer, 5121, "VEC4", name)
end

local function _addTangentBuffer(gltfRoot, count, buffer, name)
  return _addBufferAndAccessor(gltfRoot, count, count * floatByteSize * 4, buffer, 5126, "VEC4", name)
end

local function _addTexcoordBuffer(gltfRoot, count, buffer, name)
  return _addBufferAndAccessor(gltfRoot, count, count * floatByteSize * 2, buffer, 5126, "VEC2", name)
end

local function _ensureResourcedFreed()
  if lastMeshInfo then
    lastMeshInfo:free()
    lastMeshInfo = nil
  end
end

local function _triggerExport()
  _ensureResourcedFreed()
  lastMeshInfo = GPUMesh.bng_getGPUMesh(be:getPlayerVehicleID(0))
end

local function _findOrCreateMaterial(gltfRoot, matId)
  for k,v in ipairs(gltfRoot.materials) do
    if v.extras.bngMaterialId == matId then
      return k-1
    end
  end

  --create
  local mat = {
    extras = {bngMaterialId = matId},
    doubleSided = true,
    name = dumps(matId),
  }

  table.insert(gltfRoot.materials, mat)
  return #gltfRoot.materials -1
end

local function _addMesh(gltfRoot, attributes, indexBufferID, meshInfo, submeshInfo)
  local meshName
  if submeshInfo.meshName then
    meshName = submeshInfo.meshName
  end

  -- first: add a new bufferview and accessor
  local mesh = {primitives = {}}

  local primitives = ffi.new('gpuPrimitive_t[?]', submeshInfo.primitivesCount)
  if not submeshInfo:primitivesGet(primitives) then
    log('E', 'Cannot get primitives (check that the size is right).')
    primitives = nil
  end
  
  for primI = 0, (submeshInfo.primitivesCount - 1 ) do
    if primitives == nil then goto continue end
    local primitive = primitives[primI]
    local startIndex = primitive.startIndex
    -- find min/max triangle
    local endIndex = math.min(startIndex + primitive.indexCount - 1, meshInfo.indicesCount - 1)
    local minIdx, maxIdx = meshInfo:indicesMinMax(startIndex, endIndex)

    local accessor = {
      count = primitive.indexCount,
      min = { minIdx },
      max = { maxIdx },
      componentType = 5125, -- 5125 = Uint32Array.BYTES_PER_ELEMENT
      type = "SCALAR",
    }

    local meshIndexAccessorID = _addBufferviewAccessor(gltfRoot, indexBufferID, startIndex * unsignedIntByteSize, primitive.indexCount * unsignedIntByteSize, accessor, 'index_' .. meshName)

    table.insert(mesh.primitives,
      {
        indices = meshIndexAccessorID,
        attributes = attributes,
        material = _findOrCreateMaterial(gltfRoot, primitive.materialId)
      }
    )

    ::continue::
  end

  -- second: add the according mesh
  table.insert(gltfRoot.meshes, mesh)
  local meshID = #gltfRoot.meshes - 1

  -- then the node
  local node = {
    name = meshName,
    mesh = meshID
  }
  table.insert(gltfRoot.nodes, node)
  local nodeID = #gltfRoot.nodes - 1

  return nodeID
end

local function _addMeshProp(gltfRoot, prop)
  local indexBufferID = _addIndexBuffer(gltfRoot, prop)
  
  local vertices = ffi.new('float [?]', prop.verticesCount * 3)
  if not prop:verticesGet(vertices) then
    log('E', 'Cannot get vertices (check that the size is right).')
  end
  local vertexAccessorID = _addVec3Buffer(gltfRoot, prop.verticesCount, vertices, "vertices")
  local attributes = {
    POSITION = vertexAccessorID
  }

  if M.exportNormals then
    local normals = ffi.new('float [?]', prop.normalsCount * 3)
    if not prop:normalsGet(normals) then
      log('E', 'Cannot get normals (check that the size is right).')
    end
    local normalAccessorID = _addVec3Buffer(gltfRoot, prop.normalsCount, normals, "normals")
    attributes.NORMAL = normalAccessorID
  end

  if M.exportTangents then
    local tangents = ffi.new('float [?]', prop.tangentsCount * 4)
    if not prop:tangentsGet(tangents) then
      log('E', 'Cannot get tangents (check that the size is right).')
    end
    local tangentAccessorID = _addTangentBuffer(gltfRoot, prop.tangentsCount, tangents, "tangents")
    attributes.TANGENT = tangentAccessorID
  end

  if M.exportTexCoords then
    local uv1 = ffi.new('float [?]', prop.uv1Count * 2)
    if not prop:uv1Get(uv1) then
      log('E', 'Cannot get uv1 (check that the size is right).')
    end
    local uv2 = ffi.new('float [?]', prop.uv2Count * 2)
    if not prop:uv2Get(uv2) then
      log('E', 'Cannot get uv2 (check that the size is right).')
    end
    local texcoord1AccessorID = _addTexcoordBuffer(gltfRoot, prop.uv1Count, uv1, "texcoord1")
    local texcoord2AccessorID = _addTexcoordBuffer(gltfRoot, prop.uv2Count, uv2, "texcoord2")
    attributes.TEXCOORD_0 = texcoord1AccessorID
    attributes.TEXCOORD_1 = texcoord2AccessorID
  end

  if M.exportColors then
    local vertColors = ffi.new('unsigned int [?]', prop.vertColorsCount * 4)
    if not prop:vertColorsGet(vertColors) then
      log('E', 'Cannot get vertColors (check that the size is right).')
    end
    local colorAccessorID = _addColorBuffer(gltfRoot, prop.vertColorsCount, vertColors, "colors")
    attributes.COLOR_0 = colorAccessorID
  end
  
  local nodeId = _addMesh(gltfRoot, attributes, indexBufferID, prop, prop)
  gltfRoot.nodes[nodeId+1].translation = {prop.position.x, prop.position.z, -prop.position.y}
  gltfRoot.nodes[nodeId+1].rotation = {-prop.rotation.x, -prop.rotation.z, prop.rotation.y, prop.rotation.w}
  return nodeId
end

local function _getPartNodeBeams(veh, v)
  local partNodeBeams = {}

  for i, beam in pairs(v.vdata.beams) do
    local id1 = beam.id1
    local id2 = beam.id2
    local part = beam.partPath
    if part then
      local n1 = v.vdata.nodes[id1].name
      local n2 = v.vdata.nodes[id2].name

      if n1 == nil then
        n1 = tostring(id1)
      end

      if n2 == nil then
        n2 = tostring(id2)
      end

      if partNodeBeams[part] == nil then
        partNodeBeams[part] = {
          nodes = {},
          beams = {},
        }
      end

      local p1
      local p2
      local length
      local entry = partNodeBeams[part]

      p1 = vec3(veh:getNodePosition(id1))
      p2 = vec3(veh:getNodePosition(id2))
      length = (p1 - p2):length()
      entry.nodes[n1] = {p1.x, p1.z, -p1.y}
      entry.nodes[n2] = {p2.x, p2.z, -p2.y}
      table.insert(entry.beams, {n1, n2, length})
    end
  end

  return partNodeBeams
end

local function _createOrGetNode(gltfRoot, partNodes, partNodeIDs, rootNodes, partNodeBeams, part)
  if partNodes[part] == nil then
    local node = {name = part}
    partNodes[part] = node
    table.insert(gltfRoot.nodes, node)
    local nodeID = #gltfRoot.nodes - 1
    rootNodes[nodeID] = true
    partNodeIDs[part] = nodeID

    if M.exportExtras then
      if partNodeBeams ~= nil and partNodeBeams[part] ~= nil then
        node.extras = {}
        node.extras[EXTENSION_JBEAM] = partNodeBeams[part]
      end
    end
  end

  return partNodes[part]
end

local function _addMeshNodes(node, meshes, meshNodeMap)
  if node.children == nil then
    node.children = {}
  end

  for mesh, d in pairs(meshes) do
    if meshNodeMap[mesh] then
      table.insert(node.children, meshNodeMap[mesh])
    else
      log("E","mesh not found "..dumps(mesh))
    end
  end
  if #node.children ==0 then
    log("W","empty node child meshes. fixing gltf")
    node.children = nil --just to have valid GLTF
  end
end

local function _createPartTree(gltfRoot, vehiclePartTree, slotMap, partToFlexMesh, meshNodeMap, partNodeBeams, createdNodeIDs)
  partToFlexMesh = deepcopy(partToFlexMesh)
  gltfRoot.scenes[1].nodes = {}

  local parentage = {}
  for parent, children in pairs(slotMap) do
    for idx, child in ipairs(children) do
      parentage[child] = parent
    end
  end

  local partNodes = {}
  local partNodeIDs = {}
  local rootNodes = {}

  local parentPart = {}

  local partTreeParser
  partTreeParser = function (partNode,parentName)
    local node
    if partNode.chosenPartName == "" then
      goto continueChosenParts
    end
    node = _createOrGetNode(gltfRoot, partNodes, partNodeIDs, rootNodes, partNodeBeams, partNode.id )

    if partToFlexMesh[partNode.partPath] ~= nil then
      _addMeshNodes(node, partToFlexMesh[partNode.partPath], meshNodeMap)
      partToFlexMesh[partNode.partPath] = nil
      parentPart[partNode.chosenPartName] = parentName
    end

    if partToFlexMesh[partNode.chosenPartName] ~= nil then
      _addMeshNodes(node, partToFlexMesh[partNode.chosenPartName], meshNodeMap)
      partToFlexMesh[partNode.chosenPartName] = nil
      parentPart[partNode.chosenPartName] = parentName
    end
    ::continueChosenParts::
    if partNode.children then
      for _, child in pairs(partNode.children) do
        partTreeParser(child,partNode.chosenPartName)
      end
    end
  end
  partTreeParser(vehiclePartTree,"scene")

  for part, data in pairs(slotMap) do
    if parentPart[part] ~= nil and parentPart[part] ~= '' then
      local node = _createOrGetNode(gltfRoot, partNodes, partNodeIDs, rootNodes, partNodeBeams, part)
      if data.slots ~= nil then
        for subPart, d in pairs(data.slots) do
          if parentPart[subPart] ~= nil and parentPart[subPart] ~= '' then
            if partNodes[subPart] ~= nil then
              if node.children == nil then
                node.children = {}
              end

              local subNodeID = partNodeIDs[subPart]
              table.insert(node.children, subNodeID)
              rootNodes[subNodeID] = false
            end
          end
        end
      end
    end
  end

  --parent chk
  local parent = {}
  for kn,vn in pairs(gltfRoot.nodes) do
    if rootNodes[kn-1] then
      parent[kn-1] = "scene"
    end
    if gltfRoot.nodes[kn].children then
      for _,kc in ipairs(gltfRoot.nodes[kn].children) do
        if parent[kc] then
          log("E", "parent already defined for "..dbgNodeName(gltfRoot,kc).." curentParent="..dbgNodeName(gltfRoot,parent[kc]) .." new="..dbgNodeName(gltfRoot,kn-1))
        end
        parent[kc] = kn
      end
    end
  end

  for kn,vn in pairs(gltfRoot.nodes) do
    if not parent[kn-1] then
      log("W", "parent not found for "..dbgNodeName(gltfRoot,kn-1)..",item will be missing when reimporting")
    end
  end

  return rootNodes
end

local function _isTextureCookerFilepath(filepath)
  if not string.sub(filepath, -4) == ".png" then return false end
  return string.match(filepath, "%.color%.png$") or string.match(filepath, "%.normal%.png$") or string.match(filepath, "%.data%.png$")
end

local function _findOrCreateTexture(gltfRoot, filepath)
  filepath = filepath:lower()
  if savedImages[filepath] then
    return savedImages[filepath]
  end

  -- validate texture
  local filepathIn = filepath
  if not FS:fileExists(filepath) then
    if filepath:sub(1, 1) == '@' then
      local filepathIn = filepath
      local veh = getPlayerVehicle(0)
      if veh then
        filepath = '/temp/ceftexture_' .. filepath:gsub('@', '') .. '.png'
        -- always overwrite, the file might have been a leftover from another vehicle
        if veh:dumpCEFTexture(filepathIn, filepath) then
          log('I', 'dumped CEF texture ' .. filepathIn .. ' to file ' .. filepath)
        else
          log('E', 'Could not dump CEF texture ' .. filepathIn .. ' to file ' .. filepath)
        end
      end
    elseif _isTextureCookerFilepath(filepath) then
      filepath = string.sub(filepath, 1, -5) .. ".dds"
    else
      local foundFiles = FS:findFiles('/', filepathIn, -1, false, false)
      if #foundFiles == 1 then
        filepath = foundFiles[1]
        log('D', 'assuming ' .. filepathIn .. ' is actually ' .. filepath)
      else
        log('E', 'texture file not found: ' .. tostring(filepathIn))
        return nil
      end
    end
  end

  -- convert dds to png if needed
  local _, _, ext = path.split(filepath)
  local mimeType = 'image/jpeg'
  if ext == 'jpg' or ext == 'jpeg' then
    mimeType = 'image/jpeg'
  elseif ext == 'png' then
    mimeType = 'image/png'
  elseif ext == 'dds' then
    mimeType = 'image/png'
    local filepathIn = filepath
    filepath = '/temp/' .. filepath .. '.png'
    if not FS:fileExists(filepath) then
      if not convertDDSToPNG(filepathIn, filepath) then
        log('E', 'Unable to convert dds to png: ' .. tostring(filepath))
      end
      log('I', 'Converted dds to png: ' .. tostring(filepathIn) .. ' > ' .. tostring(filepath))
    end
  else
    log('E', 'Unsupported texture format: ' .. tostring(filepath))
    return nil
  end

  local dir, filename, ext = path.splitWithoutExt(filepath)
  if filename:endswith(".dds") then filename = filename:sub(1, -5) end

  local image = {
    mimeType = mimeType,
    name = filename,
  }

  -- store path to image or store the whole image itself
  if M.externalTextures then
    image.uri = filepath
  else
    local f = io.open(filepath, "rb")
    local fileData = ''
    if not f then
      log('E', 'unable to open texture file: ' .. tostring(filepath))
      return nil
    end

    -- write image into buffer
    fileData = f:read("*all")
    f:close()
    local fileSize = string.len(fileData)
    local bufferIDTexture = _addBuffer(gltfRoot, fileData, fileSize, 'texture')
    local bufferViewID = _addBufferView(gltfRoot, bufferIDTexture, 0, fileSize, filepath)

    image.bufferView = bufferViewID
  end

  if M.exportExtras then
    image.extras = {bngFilePath = filepathIn}
  end

  table.insert(gltfRoot.images, image)
  local imageId = #gltfRoot.images - 1
  table.insert(gltfRoot.textures, {source = imageId})

  savedImages[filepathIn] = {index = imageId}

  return savedImages[filepathIn]
end

local function _convertType(value, fieldInfo)
  if fieldInfo.type == "filename" or fieldInfo.type == "char" then
    return value
  elseif fieldInfo.type == "float" then
    local res = tonumber(value)
    if res then
      return res
    else
      log("E", "could not convert "..dumps(value).." to "..dumps(fieldInfo.type))
      return value
    end
  elseif fieldInfo.type == "bool" then
    local res = tonumber(value)
    if res then
      return (res == 1 and true or false)
    else
      log("E", "could not convert "..dumps(value).." to "..dumps(fieldInfo.type))
      return value
    end
  elseif fieldInfo.type == "Point3F" then
    return vec3():fromString(value):toTable()
  else
    log("W", "unknown field type "..dumps(fieldInfo.type).."\n"..dumps(fieldInfo))
    return value
  end
end

local function _getMaterialStages(materialObj, field, maxLayers)
  local stages = {}
  local info = materialObj:getFieldInfo(field, 0)
  if not maxLayers then maxLayers=3 end
  for i=0,maxLayers-1 do
    local tmp = materialObj:getField(field, i)
    if tmp ~= "" then
      table.insert(stages,_convertType(tmp, info))
    else
      table.insert(stages,"")
    end
  end
  if #stages == 0 then return nil end
  return stages
end

local function _exportMaterial(gltfCurrentMaterial, materialObj)
  gltfCurrentMaterial.version = tonumber(materialObj:getField('version', 0))

  if gltfCurrentMaterial.version == 1 then
    gltfCurrentMaterial.colorMap = _getMaterialStages(materialObj, "colorMap")
    gltfCurrentMaterial.normalMap = _getMaterialStages(materialObj, "normalMap")
    gltfCurrentMaterial.pixelSpecular = _getMaterialStages(materialObj, "pixelSpecular")
    gltfCurrentMaterial.specularMap = _getMaterialStages(materialObj, "specularMap")
    gltfCurrentMaterial.specularPower = _getMaterialStages(materialObj, "specularPower")
    gltfCurrentMaterial.useAnisotropic = _getMaterialStages(materialObj, "useAnisotropic")
    gltfCurrentMaterial.translucent = materialObj:getField('translucent', 0)
    gltfCurrentMaterial.translucentBlendOp = materialObj:getField('translucentBlendOp', 0)
    gltfCurrentMaterial.instanceDiffuse = _getMaterialStages(materialObj, "instanceDiffuse", gltfCurrentMaterial.activeLayers)
    if tableContains(gltfCurrentMaterial.instanceDiffuse, true) then
      local veh = getPlayerVehicle(0)
      gltfCurrentMaterial.instanceColor = {veh.color.x, veh.color.y, veh.color.z, veh.color.w}
      gltfCurrentMaterial.instanceColorPalette0 = {veh.colorPalette0.x, veh.colorPalette0.y, veh.colorPalette0.z, veh.colorPalette0.w}
      gltfCurrentMaterial.instanceColorPalette1 = {veh.colorPalette1.x, veh.colorPalette1.y, veh.colorPalette1.z, veh.colorPalette1.w}
    end
  elseif abs(gltfCurrentMaterial.version - 1.5) < 1e-7 then
    gltfCurrentMaterial.activeLayers = materialObj.activeLayers
    gltfCurrentMaterial.translucent = materialObj:getField('translucent', 0)
    gltfCurrentMaterial.alphaRef = materialObj:getField('alphaRef', 0)
    gltfCurrentMaterial.doubleSided = materialObj:getField('doubleSided', 0)
    gltfCurrentMaterial.translucentBlendOp = materialObj:getField('translucentBlendOp', 0)
    gltfCurrentMaterial.ambientOcclusionMap = _getMaterialStages(materialObj, "ambientOcclusionMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.baseColorMap = _getMaterialStages(materialObj, "baseColorMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.diffuseMapUseUV = _getMaterialStages(materialObj, "diffuseMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.metallicFactor = _getMaterialStages(materialObj, "metallicFactor", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.metallicMap = _getMaterialStages(materialObj, "metallicMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.metallicMapUseUV = _getMaterialStages(materialObj, "metallicMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.normalMap = _getMaterialStages(materialObj, "normalMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.normalMapUseUV = _getMaterialStages(materialObj, "normalMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.roughnessMap = _getMaterialStages(materialObj, "roughnessMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.roughnessMapUV1 = _getMaterialStages(materialObj, "roughnessMapUV1", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.instanceDiffuse = _getMaterialStages(materialObj, "instanceDiffuse", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.useAnisotropic = _getMaterialStages(materialObj, "useAnisotropic", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.clearCoatFactor = _getMaterialStages(materialObj, "clearCoatFactor", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.clearCoatMap = _getMaterialStages(materialObj, "clearCoatMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.clearCoatRoughnessFactor = _getMaterialStages(materialObj, "clearCoatRoughnessFactor", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.clearCoatMapUseUV = _getMaterialStages(materialObj, "clearCoatMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.colorPaletteMap = _getMaterialStages(materialObj, "colorPaletteMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.colorPaletteMapUseUV = _getMaterialStages(materialObj, "colorPaletteMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.opacityMap = _getMaterialStages(materialObj, "opacityMap", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.opacityMapUseUV = _getMaterialStages(materialObj, "opacityMapUseUV", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.emissiveFactor = _getMaterialStages(materialObj, "emissiveFactor", gltfCurrentMaterial.activeLayers)
    gltfCurrentMaterial.emissiveMap = _getMaterialStages(materialObj, "emissiveMap", gltfCurrentMaterial.activeLayers)

    if tableContains(gltfCurrentMaterial.instanceDiffuse, true) or gltfCurrentMaterial.colorPaletteMap then
      local veh = getPlayerVehicle(0)
      gltfCurrentMaterial.instanceColor = {veh.color.x, veh.color.y, veh.color.z, veh.color.w}
      gltfCurrentMaterial.instanceColorPalette0 = {veh.colorPalette0.x, veh.colorPalette0.y, veh.colorPalette0.z, veh.colorPalette0.w}
      gltfCurrentMaterial.instanceColorPalette1 = {veh.colorPalette1.x, veh.colorPalette1.y, veh.colorPalette1.z, veh.colorPalette1.w}
    end
  else
    log("E","unknown material version "..dumps(gltfCurrentMaterial.version))
  end

  for k,v in pairs(gltfCurrentMaterial) do
    if k:endswith("Map") then
      gltfCurrentMaterial[k.."Index"] = {}
      for klayer, layer in ipairs(v) do
        if layer and layer ~= "" then
          local tex = _findOrCreateTexture(gltfRoot,layer)
          if tex then
            gltfCurrentMaterial[k.."Index"][klayer] = tex.index
          end
        end
      end
      if #gltfCurrentMaterial[k.."Index"] ==0 then gltfCurrentMaterial[k.."Index"] = nil end
    end
  end
end

local function processExport()
  local indexBufferID
  if not gltfRoot then
    gltfRoot = deepcopy(gltfRootTemplate)
    -- only add the index buffer at the beginning
    indexBufferID = _addIndexBuffer(gltfRoot, lastMeshInfo)
  end

  local vertices = ffi.new('float [?]', lastMeshInfo.verticesCount * 3)
  if not lastMeshInfo:verticesGet(vertices) then
    log('E', 'Cannot get vertices (check that the size is right).')
  end
  local vertexAccessorID = _addVec3Buffer(gltfRoot, lastMeshInfo.verticesCount, vertices, "vertices")
  local attributes = {
    POSITION = vertexAccessorID
  }

  if M.exportNormals then
    local normals = ffi.new('float [?]', lastMeshInfo.normalsCount * 3)
    if not lastMeshInfo:normalsGet(normals) then
      log('E', 'Cannot get normals (check that the size is right).')
    end
    local normalAccessorID = _addVec3Buffer(gltfRoot, lastMeshInfo.normalsCount, normals, "normals")
    attributes.NORMAL = normalAccessorID
  end

  if M.exportTangents then
    local tangents = ffi.new('float [?]', lastMeshInfo.tangentsCount * 4)
    if not lastMeshInfo:tangentsGet(tangents) then
      log('E', 'Cannot get tangents (check that the size is right).')
    end
    local tangentAccessorID = _addTangentBuffer(gltfRoot, lastMeshInfo.tangentsCount, tangents, "tangents")
    attributes.TANGENT = tangentAccessorID
  end

  if M.exportTexCoords then
    local uv1 = ffi.new('float [?]', lastMeshInfo.uv1Count * 2)
    if not lastMeshInfo:uv1Get(uv1) then
      log('E', 'Cannot get uv1 (check that the size is right).')
    end
    local uv2 = ffi.new('float [?]', lastMeshInfo.uv2Count * 2)
    if not lastMeshInfo:uv2Get(uv2) then
      log('E', 'Cannot get uv2 (check that the size is right).')
    end
    local texcoord1AccessorID = _addTexcoordBuffer(gltfRoot, lastMeshInfo.uv1Count, uv1, "texcoord1")
    local texcoord2AccessorID = _addTexcoordBuffer(gltfRoot, lastMeshInfo.uv2Count, uv2, "texcoord2")
    attributes.TEXCOORD_0 = texcoord1AccessorID
    attributes.TEXCOORD_1 = texcoord2AccessorID
  end

  if M.exportColors then
    local vertColors = ffi.new('unsigned int [?]', lastMeshInfo.vertColorsCount * 4)
    if not lastMeshInfo:vertColorsGet(vertColors) then
      log('E', 'Cannot get vertColors (check that the size is right).')
    end
    local colorAccessorID = _addColorBuffer(gltfRoot, lastMeshInfo.vertColorsCount, vertColors, "colors")
    attributes.COLOR_0 = colorAccessorID
  end

  -- now add the meshes
  local meshNodeMap = {}
  gltfRoot.scenes[1].nodes = {}
  for i = 0, lastMeshInfo.flexmeshesCount - 1 do
    local flexmesh = lastMeshInfo:flexmeshes(i)
    local nodeID = _addMesh(gltfRoot, attributes, indexBufferID, lastMeshInfo, flexmesh)
    meshNodeMap[flexmesh.meshName] = nodeID
  end
  for i = 0, lastMeshInfo.propmeshesCount - 1 do
    local propmesh = lastMeshInfo:propmeshes(i)
    local nodeID = _addMeshProp(gltfRoot, propmesh)
    meshNodeMap[propmesh.meshName] = nodeID
  end

  -- map the parts to flexmeshes to allow sorting meshes according to part tree
  local v = core_vehicle_manager.getPlayerVehicleData()
  if not v then
    log('E', 'Unable to get vehicle data? Try reloading the vehicle and try again.')
    return
  end
  local partToFlexMesh = {}
  for _, flexMesh in pairs(v.vdata.flexbodies or {}) do
    local path = flexMesh.partPath or ""
    if partToFlexMesh[path] == nil then
      partToFlexMesh[path] = {}
    end

    partToFlexMesh[path][flexMesh.mesh] = true
  end
  for _, prop in pairs(v.vdata.props or {}) do
    if prop.mesh ~= "SPOTLIGHT" then
      local path = prop.partPath or ""
      if partToFlexMesh[path] == nil then
        partToFlexMesh[path] = {}
      end
      partToFlexMesh[path][prop.mesh] = true
    end
  end

  local veh = getPlayerVehicle(0)

  local partNodeBeams = nil
  if M.exportExtras and M.exportBeams then
    partNodeBeams = _getPartNodeBeams(veh, v)
  end

  local slotMap = jbeamIO.getAvailableParts(v.ioCtx)

  local rootNodes = _createPartTree(gltfRoot, v.config.partsTree, slotMap, partToFlexMesh, meshNodeMap, partNodeBeams)

  -- create the root node as the final node
  local finalRootNode = {
    name = "root",
    children = {},
    -- position vectors are transformed
    translation = {currentTranslation.x, currentTranslation.z, -currentTranslation.y},
  }
  table.insert(gltfRoot.nodes, finalRootNode)
  local finalNodeID = #gltfRoot.nodes - 1

  gltfRoot.scenes[1].nodes = {}
  table.insert(gltfRoot.scenes[1].nodes, finalNodeID)

  -- add the other root nodes as children to the final root node
  for nodeID, root in pairs(rootNodes) do
    if root then
      table.insert(gltfRoot.nodes[finalNodeID+1].children, nodeID)
    end
  end

  -- add materials
  if veh.getMaterialNames then
    local matNames = veh:getMaterialNames()
    for i,v in pairs(gltfRoot.materials) do
      gltfRoot.materials[i].name = matNames[v.extras.bngMaterialId+1]

      gltfRoot.materials[i].pbrMetallicRoughness = {}

      local mat = scenetree.findObject(matNames[v.extras.bngMaterialId+1])
      local matVer
      local matIsCar = false
      if not mat then
        log("E", dumps(matNames[v.extras.bngMaterialId+1]) .. " sceneobject was not found")
        goto continueMat
      end
      if mat:getClassName():lower() ~= "material" then
        log("E", dumps(matNames[v.extras.bngMaterialId+1]) .. " is not a Material. type="..dumps(mat:getClassName()))
        goto continueMat
      end

      matVer = mat:getField("version", 0 )
      if matVer == "1" then --float are string because TS
        matIsCar = mat:getField("normalMap", 2) ~= ""

        if mat:getField("normalMap", 0) ~= "" then
          gltfRoot.materials[i].normalTexture = _findOrCreateTexture(gltfRoot, mat:getField("normalMap", 0))
        end

        if matIsCar then
          if mat:getField("colorMap", 1) ~= "" then
            gltfRoot.materials[i].pbrMetallicRoughness.baseColorTexture = _findOrCreateTexture(gltfRoot, mat:getField("colorMap", 1))
          end
          if mat:getField("specularMap", 1) ~= "" then
            gltfRoot.materials[i].pbrMetallicRoughness.metallicRoughnessTexture = _findOrCreateTexture(gltfRoot, mat:getField("specularMap", 1))
          end
        else
          if mat:getField("colorMap", 0) ~= "" then
            gltfRoot.materials[i].pbrMetallicRoughness.baseColorTexture = _findOrCreateTexture(gltfRoot, mat:getField("colorMap", 0))
          end
          if mat:getField("specularMap", 0) ~= "" then
            gltfRoot.materials[i].pbrMetallicRoughness.metallicRoughnessTexture = _findOrCreateTexture(gltfRoot, mat:getField("specularMap", 0))
          end
        end

      elseif matVer == "1.5" then --pbr like input
        if mat:getField("normalMap", 0) ~= "" then
          gltfRoot.materials[i].normalTexture = _findOrCreateTexture(gltfRoot, mat:getField("normalMap", 0))
        end
        if mat:getField("baseColorMap", 0) ~= "" then
          gltfRoot.materials[i].pbrMetallicRoughness.baseColorTexture = _findOrCreateTexture(gltfRoot, mat:getField("baseColorMap", 0))
        end
        if mat:getField("emissiveMap", 0) ~= "" then
          gltfRoot.materials[i].emissiveTexture = _findOrCreateTexture(gltfRoot, mat:getField("emissiveMap", 0))
        end
        if mat:getField("occlusionTexture", 0) ~= "" then
          gltfRoot.materials[i].ambientOcclusionMap = _findOrCreateTexture(gltfRoot, mat:getField("occlusionTexture", 0))
        end
        if mat:getField("metallicMap", 0) ~= "" then
          gltfRoot.materials[i].pbrMetallicRoughness.metallicRoughnessTexture = _findOrCreateTexture(gltfRoot, mat:getField("metallicMap", 0))
        end
      else
        log("E", "unknown Material version "..dumps(matVer))
      end

      if M.exportExtras then
        gltfRoot.materials[i].extras.bngMaterial = {}
        _exportMaterial(gltfRoot.materials[i].extras.bngMaterial, mat)
      end

      ::continueMat::

      if tableSize(gltfRoot.materials[i].pbrMetallicRoughness) == 0 then
        gltfRoot.materials[i].pbrMetallicRoughness = nil
      end
    end
  else
    log("E", "getMaterialNames not available" )
  end

  -- optionally add beamng extra info
  if M.exportExtras then
    for i, e in pairs(gltfRoot.nodes[finalNodeID+1].children) do
      local node = gltfRoot.nodes[e + 1]
      local d = veh:getDirectionVector()
      local u = veh:getDirectionVectorUp()
      if node.extras == nil then
        node.extras = {}
      end
      node.extras[EXTENSION_DIRECTION] = {
        dir = {d.x, d.z, -d.y},
        up = {u.x, u.z, -u.y}
      }
    end
  end

  if not continueRecording and #keyFrameTimes > 1 then
    -- ensure animation exists
    if not gltfRoot.animations then
      gltfRoot.animations = {
        {
          samplers = {
            {
              interpolation = 'LINEAR',
            }
          },
          channels = {
            {
              sampler = 0,
              target = {
                node = 0,
                path = 'weights',
              }
            }
          }
        }
      }
    end
    _addTimeBuffers(gltfRoot)
  end

  --enpty array in GLTF is not allowed
  if #gltfRoot.images == 0 then
    gltfRoot.images= nil
  end
  if #gltfRoot.textures == 0 then
    gltfRoot.textures= nil
  end

  exportHandler(gltfRoot)
  _ensureResourcedFreed()

  -- continue or stop?
  if continueRecording then
    _triggerExport()
    framesRecorded = framesRecorded + 1
    local frameTime = timer:stop() / 1000
    table.insert(keyFrameTimes, frameTime)
    print(' ** frame ' .. tostring(framesRecorded) .. ' = ' .. tostring(frameTime) ..' s')
  else
    exportHandler = nil
    gltfRoot = nil
    framesRecorded = 0
  end

  guihooks.trigger("ThreeDExported")
end

local function export(handler)
  if lastMeshInfo ~= nil then
    handler(nil)
    return
  end

  exportHandler = handler

  _triggerExport()

  if lastMeshInfo.dataIsReady then
    processExport()
  else
    log("E", "not ready")
  end
end

local function updateGFX(dt)
  if lastMeshInfo and lastMeshInfo.dataIsReady then
    processExport()
  end
end

local function getVehiclePosition()
  local veh = be:getPlayerVehicle(0)

  if not veh then
    log('E', 'Unable to get player vehicle.')
    return
  else
    return veh:getPosition()
  end
end

local function exportFile(filename)
  local currentVehiclePosition = getVehiclePosition()
  if currentVehiclePosition then
    currentTranslation.x = currentVehiclePosition.x - originWorld.x
    currentTranslation.y = currentVehiclePosition.y - originWorld.y
    currentTranslation.z = currentVehiclePosition.z - originWorld.z
  end

  if not M.embedBuffers then
    local dir, filename, ext = path.splitWithoutExt(filename)
    if dir == nil then
      dir = ''
    end
    bufferPathPattern = dir .. filename .. '_buffer_%03d_%s.bin'
  end

  savedImages = {} -- clear from last run

  local jsonHandler = function(gltfRoot)
    jsonWriteFile(tostring(filename), gltfRoot, true, 20)
    bufferPathPattern = nil
    log("I", "GLTF json exported "..dumps(filename))
  end

  local glbHandler = function(gltfRoot)
    local f = io.open(tostring(filename), "wb")
    local bit = require "bit"
    local function sepbytes(num)
      return bit.band(num,0xFF), bit.band(bit.rshift(num,8),0xFF), bit.band(bit.rshift(num,16),0xFF), bit.band(bit.rshift(num,24),0xFF);
    end
    local function fourByteAlignPaddingSize(size)
      if size%4 == 0 then
        return 0
      else
        return 4-(size%4)
      end
    end
    local function getStartByteBufferView(index)
      local tmp = 0
      for k,v in ipairs(binaryBuffers) do
        if k-1 == index then
          return tmp
        end
        tmp = tmp + v.len
      end
      return tmp
    end

    --GLB Header
    f:write(string.char(0x67,0x6C,0x54,0x46)) --Magic "glTF"
    f:write(string.char(sepbytes(2))) -- version 2

    --merge all buffers, GLB have only one binary section
    local totalBinBufSize = getStartByteBufferView(#binaryBuffers)
    for k,v in pairs(gltfRoot.bufferViews) do
      if v.buffer ~= 0 then
        gltfRoot.bufferViews[k].byteOffset = gltfRoot.bufferViews[k].byteOffset + getStartByteBufferView(v.buffer)
        gltfRoot.bufferViews[k].buffer = 0
      end
    end
    gltfRoot.buffers = {{ byteLength = totalBinBufSize }}

    local jsonContent = jsonEncode(gltfRoot)
    local fileLen = #jsonContent + 2*4 + fourByteAlignPaddingSize(#jsonContent) +3*4
    fileLen = fileLen + totalBinBufSize + 2*4 + fourByteAlignPaddingSize(totalBinBufSize) -- header[2] + 4 byte alignement

    --total fileSize Including all headers
    f:write( string.char(sepbytes(fileLen)) )

    ---- ALL CHUNKS NEED TO BE 4 BYTES ALIGNED IN GLB!!!
    --chunk[0] JSON
    f:write( string.char(sepbytes(#jsonContent + fourByteAlignPaddingSize(#jsonContent))) ) --size
    f:write(string.char(0x4A,0x53,0x4F,0x4E)) --type JSON
    f:write(jsonContent)
    if fourByteAlignPaddingSize(#jsonContent) > 0 then
      f:write(string.rep(" ", fourByteAlignPaddingSize(#jsonContent))) --JSON padding
    end

    -----
    --chunk[1] Binary data / buffers
    f:write( string.char(sepbytes(totalBinBufSize + fourByteAlignPaddingSize(totalBinBufSize))) ) --size
    f:write(string.char(0x42,0x49,0x4E,0x00)) --type BIN\0
    for k,v in ipairs(binaryBuffers) do
      if type(v.data) == 'cdata' then
        -- ffi buffer
        f:write(ffi.string(v.data, v.len))
      elseif type(v.data) == 'string' then
        -- normal lua buffer
        f:write(v.data)
      else
        log('E', 'unknown buffer type: ' .. type(v.data))
      end
    end
    if fourByteAlignPaddingSize(totalBinBufSize) > 0 then
      f:write(string.rep(string.char(0), fourByteAlignPaddingSize(totalBinBufSize))) --BIN padding
    end
    binaryBuffers={}

    log("I", "GLTF binary exported "..dumps(filename))
  end

  if M.gltfBinaryFormat then
    export(glbHandler)
  else
    export(jsonHandler)
  end

  guihooks.message("Exported frame " .. dumps(filename), 5, "gltfSequenceExporter", "movie")
end

local function checkVulkan()
  local isVulkanEnabled = Engine.getVulkanEnabled()
  if isVulkanEnabled == false then --double check because of command argument
    for k,adapter in pairs(GFXInit.getAdapters()) do
      if adapter.gfx == "VK" then
        isVulkanEnabled = true
        break
      end
    end
  end
  return isVulkanEnabled
end

local function setOrigin()
  local playerPos = getVehiclePosition()
  if not playerPos then
    log('E', 'Unable to set origin.')
    return
  end

  originWorld = {
    x = playerPos.x,
    y = playerPos.y,
    z = playerPos.z
  }
  
  log('I', 'Set origin to ' .. tostring(playerPos))
  guihooks.message(
    string.format("glTF origin set at (%.2f, %.2f, %.2f).",playerPos.x, playerPos.y, playerPos.z),
    5,
    "gltfSequenceExporter",
    "my_location" -- notification icon
  )
end

local function clearOrigin()
  originWorld = {
    x = 0.0,
    y = 0.0,
    z = 0.0
  }
  log('I', 'Set origin to (0, 0, 0)')
  guihooks.message("glTF origin cleared.", 5, "gltfSequenceExporter", "location_disabled")
end

-- public interface
M.embedBuffers = true
M.gltfBinaryFormat = true
M.exportNormals = true
M.exportTangents = false
M.exportTexCoords = false
M.exportColors = false
M.exportBeams = true

M.exportExtras = false
M.externalTextures = true

M.updateGFX = updateGFX

M.export = export
M.exportFile = exportFile

M.setOrigin = setOrigin
M.clearOrigin = clearOrigin

M.checkVulkan = checkVulkan

return M
