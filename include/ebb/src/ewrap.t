-- The MIT License (MIT)
-- 
-- Copyright (c) 2015 Stanford University.
-- All rights reserved.
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.


local Exports = {}
package.loaded["ebb.src.ewrap"] = Exports

local use_exp = rawget(_G,'EBB_USE_EXPERIMENTAL_SIGNAL')
if not use_exp then return Exports end

local C       = require "ebb.src.c"
local Util    = require 'ebb.src.util'

-- Following modules are probably not going to depdend (directly or indirectly)
-- on ewrap since they define basic types.
local Pre     = require 'ebb.src.prelude'
local Rawdata = require 'ebb.src.rawdata'
local DynamicArray = Rawdata.DynamicArray
--local Types   = require 'ebb.src.types'

-- signal to gasnet library not to try to find the shared lib or headers
rawset(_G,'GASNET_PRELOADED',true)
local gas       = require 'gasnet'
local gaswrap   = require 'gaswrap'

local newlist = terralib.newlist
local function shallow_copy(table)
  local t = {}
  for k,v in pairs(table) do
    t[k] = v
  end
  return t
end


-------------------------------------------------------------------------------
-- Basic Prepare  
-------------------------------------------------------------------------------

local N_NODES                   = gas.nodes()
local THIS_NODE                 = gas.mynode()
local CONTROL_NODE              = 0

local BASIC_SAFE_GHOST_WIDTH    = 2

-- constants/modes
local GRID                      = 'GRID'
local CPU                       = tostring(Pre.CPU)
local GPU                       = tostring(Pre.GPU)

local GHOST_DIGITS              = 3
local NODE_DIGITS               = 4

local USE_CONSERVATIVE_GHOSTS   = true
local POLL_USLEEP               = 2


-------------------------------------------------------------------------------
-- Helper methods
-------------------------------------------------------------------------------

-- assumption: 0 is control node, remaining are compute nodes
local function numComputeNodes()  -- get total number of compute nodes
  return gas.nodes() - 1
end
local function BroadcastLuaEventToComputeNodes(event_name, ...)
  print('*** DEBUG INFO: Sending ' .. event_name)
  for i = 1,numComputeNodes() do
    gaswrap.sendLuaEvent(i, event_name, ...)
  end
end
local function on_control_node() return THIS_NODE == CONTROL_NODE end

local default_align_max_pow = 32 -- this should accomodate diff architectures
local function pow2align(N,max_pow)
  max_pow = max_pow or default_align_max_pow
  if N > max_pow then -- smallest multiple of max_pow that works
    return math.ceil(N/max_pow)*max_pow
  else
    -- find smallest power of 2 >= N
    while max_pow / 2 >= N do max_pow = max_pow / 2 end
    return max_pow
  end
end

local function is_2_nums(obj)
  return type(obj) == 'table' and #obj == 2
     and type(obj[1]) == 'number' and type(obj[2]) == 'number'
end
local function is_3_nums(obj)
  return type(obj) == 'table' and #obj == 3
     and type(obj[1]) == 'number' and type(obj[2]) == 'number'
                                  and type(obj[3]) == 'number'
end


-------------------------------------------------------------------------------
-- Relation and Field objects at compute nodes
-------------------------------------------------------------------------------

--[[
_array,
_ghost_width,
_ ... see below
--]]
local FieldInstanceTable = {}
FieldInstanceTable.__index = FieldInstanceTable

local struct BoundsStruct { lo : uint64, hi : uint64 }
local struct FieldInstance {
  ptr     : &uint8
  strides : uint64[3]
}

--[[
params {
  bounds,
  ghost_width,
  type_size
}
--]]
local function NewFieldInstanceTable(params)
  local widths      = params.bounds:getwidths()
  local ghost_width = shallow_copy(params.ghost_width)
  local n_elems     = 1
  local dim_size    = {}
  local strides     = {}
  for d = 1,3 do
    strides[d]      = n_elems   -- column major?
    if not ghost_width[d] then ghost_width[d] = 0 end
    dim_size[d]     = widths[d] + 1 -- adjust for hi/lo inclusive convention
    n_elems         = n_elems * (dim_size[d] + 2*ghost_width[d])
  end

  local elem_size   = params.type_size
  local elem_stride = pow2align(elem_size,4)
  assert(elem_stride == elem_size)
  local array = DynamicArray.New {
    size      = n_elems,
    type      = uint8[elem_size],
    processor = Pre.CPU,
  }
  return setmetatable ({
    _array        = array,
    _strides      = strides,
    _elem_size    = elem_size,
    _ghost_width  = ghost_width,
    _n_elems      = n_elems,
  }, FieldInstanceTable)
end

function FieldInstanceTable:DataPtr()
  return self._array:_raw_ptr()
end

function FieldInstanceTable:DataPtrGhostAdjusted()
  local ptr = terralib.cast(&uint8, self:DataPtr())
  local offset = 0
  for d = 1,3 do
    offset = offset + self._ghost_width[d] * self._strides[d]
  end
  return ptr + offset * self._elem_size
end

function FieldInstanceTable:NElems() return self._n_elems end
function FieldInstanceTable:Strides() return self._strides end
function FieldInstanceTable:ElemSize() return self._elem_size end

local GhostMetadata = {}
GhostMetadata.__index = GhostMetadata

local struct GhostInstance  {
  union {
    src : &gaswrap.AsyncBufSrcChannel;
    dst : &gaswrap.AsyncBufDstChannel;
  }
  buffer : &uint8;
  -- add global bounds
}

-- use an hid_base as there could be multiple channels for the same field
-- programmatically generate the rest, keep last 3 digits for ghost num, and
-- NODE_DIGITS digits for node ids (source and destination).
local function hs_id(hid_base, src, dst, ghost_num)
  return ghost_num +
         dst      * math.pow(10, GHOST_DIGITS) +
         src      * math.pow(10, GHOST_DIGITS + NODE_DIGITS) +
         hid_base * math.pow(10, GHOST_DIGITS + NODE_DIGITS * 2)
end

local worker_ghost_num_channels = {}
local worker_ghost_channels_freeze = {}

--[[
  allocates buffer for ghost region
  params {
  hid_base,      -- id info
  ghost_id,      -- id info
  fid,           -- for call back, signaling to controller when ready
  type_size,     -- elem size
  ndims,
  partition,     -- neighbor info, bounds/location
  ghost_width,   -- size
  }
--]]
local function CreateGridGhostMetadata(off, params)
  assert(not worker_ghost_channels_freeze[params.hid_base],
         'Already started setting up ghost channels. ' ..
         'All calls to create ghost channels must precede channel set up calls.')
  local g        = {
    hid_base = params.hid_base,
    ghost_id = params.ghost_id,
    fid      = params.fid,
    nb_id    = nil,
    buffer   = nil,
    buf_size = 0,
    bounds   = nil,
  }
  local blocking = params.partition.blocking
  local bid      = params.partition.block_id
  local allocate = true
  local nb_bid = {}
  for d = 1, params.ndims do
    if not params.periodic then
      nb_bid[d] = bid[d] + off[d]
      allocate = allocate and (nb_bid[d] >= 1 and nb_bid[d] <= blocking[d])
      nb_bid[d] = (nb_bid[d] - 1) % blocking[d] + 1
    end
  end
  if allocate then
    local nb_lin_id = params.partition.map
    for d = 1, params.ndims do
      nb_lin_id = nb_lin_id[nb_bid[d]]
    end
    g.nb_id    = nb_lin_id
    local partition_width = params.partition.bounds:getwidths()
    local ghost_width     = params.ghost_width
    local buf_size = params.type_size
    for d = 1, params.ndims do
      if off[d] == 0 then
        buf_size = buf_size * ghost_width[d]
      else
        buf_size = buf_size * partition_width[d]
      end
    end
    g.buf_size = buf_size
    g.buffer = terralib.cast(&uint8, C.malloc(buf_size))
    if not worker_ghost_num_channels[params.hid_base] then
      worker_ghost_num_channels[params.hid_base] = 0
    else
      worker_ghost_num_channels[params.hid_base] =
        worker_ghost_num_channels[params.hid_base] + 1
    end
  end
  return setmetatable(g, GhostMetadata)
end

function GhostMetadata:CreateOutgoingGhostChannel(g)
  worker_ghost_channels_freeze[self.hid_base] = true
  -- set buffer
  g.buffer = self.buffer
  if not self.buffer then return end
  local function DoneCallback(chan)
    worker_ghost_num_channels[self.hid_base] =
      worker_ghost_num_channels[self.hid_base] - 1
    if worker_ghost_num_channels[self.hid_base] == 0 then
      -- inform controller that ghost channel setup is done
      print('*** Node ' .. gas.mynode() .. ' done with channels for ' ..
            self.fid)
      gaswrap.sendLuaEvent(CONTROL_NODE, 'markGhostsReady',
                           self.fid, self.hid_base)
    end
    -- set channel
    g.src = chan
  end
  local hid = hs_id(self.hid_base, gas.mynode(), self.nb_id, self.ghost_id)
  gaswrap.CreateAsyncBufSrcChannel(self.nb_id, hid,
                                   self.buffer, self.buf_size, DoneCallback)
end

function GhostMetadata:CreateIncomingGhostChannel(g)
  worker_ghost_channels_freeze[self.hid_base] = true
  -- set buffer
  g.buffer = self.buffer
  if not self.buffer then return end
  local function DoneCallback(chan)
    worker_ghost_num_channels[self.hid_base] =
      worker_ghost_num_channels[self.hid_base] - 1
    if worker_ghost_num_channels[self.hid_base] == 0 then
      -- inform controller that ghost channel setup is done
      print('*** Node ' .. gas.mynode() .. ' done with channels for ' ..
            self.fid)
      gaswrap.sendLuaEvent(CONTROL_NODE, 'markGhostsReady',
                           self.fid, self.hid_base)
    end
    -- set channel
    g.dst = chan
  end
  local hid = hs_id(self.hid_base, self.nb_id, gas.mynode(), self.ghost_id)
  gaswrap.CreateAsyncBufDstChannel(self.nb_id, hid,
                                   self.buffer, self.buf_size, DoneCallback)
end

local worker_relation_metadata = {}
local worker_field_metadata    = {}

--[[
WorkerField : {
  id          = #,
  type_size   = #, (bytes)
  name        = 'string',
  relation    = WorkerRelation,
  instance    = FieldInstance,
  last_read   = Signal,
  last_write  = Signal,
}
--]]
local WorkerField = {}
WorkerField.__index = WorkerField

local function NewWorkerField(relation, params)
  return setmetatable({
                        id           = params.id,
                        type_size    = params.type_size,
                        name         = params.name,
                        relation     = relation,
                        instance     = nil,
                        last_read    = nil,
                        last_write   = nil,
                      },
                      WorkerField)
end

function WorkerField:Name()
  return self.name
end

function WorkerField:isAllocated()
  return (self.instance ~= nil)
end

function WorkerField:AllocateInstance(gw)
  assert(self.array == nil, 'Trying to allocate already allocated array.')
  assert(self.relation:isPartitioned(),
         'Relation ' .. self.relation:Name() .. 'not partitioned. ' ..
         'Cannot allocate data over it.')
  self.instance   = NewFieldInstanceTable {
                      bounds      = self.relation:GetPartitionBounds(),
                      ghost_width = gw,
                      type_size   = self:GetTypeSize(),
                    }
  self.last_read  = gaswrap.newSignalSource():trigger()
  self.last_write = gaswrap.newSignalSource():trigger()
end

function WorkerField:GetTypeSize()
  return self.type_size
end
function WorkerField:GetTypeStride()
  return self.instance:ElemSize()
end

function WorkerField:GetInstance()
  return self.instance
end

function WorkerField:GetDataPtr()
  return self.instance:DataPtr()
end
function WorkerField:GetElemCount() -- includes ghosts
  return self.instance:NElems()
end
function WorkerField:GetStrides()
  return self.instance:Strides()
end

function WorkerField:GetReadSignal()
  return self.last_read
end
function WorkerField:GetWriteSignal()
  return self.last_write
end
function WorkerField:GetReadWriteSignal()
  local signals = terralib.new(gaswrap.Signal[2])
  signals[0] = self.last_read
  signals[1] = self.last_write
  return gaswrap.mergeSignals(2, signals)
end
function WorkerField:ForkWriteSignal()
  local signals = terralib.new(gaswrap.Signal[2])
  self.last_write:fork(2, signals)
  self.last_write = signals[1]
  return signals[0]
end
function WorkerField:MergeReadSignal(signal)
  local signals = terralib.new(gaswrap.Signal[2])
  signals[0] = self.last_read
  signals[1] = signal
  self.last_read = gaswrap.mergeSignals(2, signals)
end
function WorkerField:SetReadWriteSignal(signal)
  local signals = terralib.new(gaswrap.Signal[2])
  signal:fork(2, signals)
  self.last_read  = signals[0]
  self.last_write = signals[1]
end

-- Allocate incoming and outgoing buffers for data exchange, set up channels
-- with neighboring nodes, and send a confirmation to control node when all
-- channels are set up.
local ghost_listing_2d = newlist()
local ghost_listing_3d = newlist()
if USE_CONSERVATIVE_GHOSTS then
  for x = -1,1 do
    for y = -1,1 do
      if x ~= 0 or y ~= 0 then
        ghost_listing_2d:insert({x,y})
      end
      for z = -1,1 do
        if x ~= 0 or y ~= 0 or z ~= 0 then
          ghost_listing_3d:insert({x,y,z})
        end
      end
    end
  end
else
  for d = 1,3 do
    local neg, pos = {0,0}, {0,0}
    neg[d] = -1
    pos[d] =  1
    ghost_listing_2d:insertall({neg, pos})
  end
  for d = 1,3 do
    local neg, pos = {0,0,0}, {0,0,0}
    neg[d] = -1
    pos[d] =  1
    ghost_listing_3d:insertall({neg, pos})
  end
end
local function ghost_id(offset, ndims)
  local g = 0
  for d = 1, ndims do
    g = g * 3 + (offset[d] + 1)
  end
  return g
end
function WorkerField:SetUpGhostChannels(hid_base, ghost_width)
  local ndims = #self.relation:Dims()
  local ghost_listing = nil
  if ndims == 2 then
    ghost_listing = ghost_listing_2d
  else
    ghost_listing = ghost_listing_3d
  end
  local partition    = self.relation:GetPartition()
  local inner_ghosts = newlist()
  local outer_ghosts = newlist()
  for i = 1,#ghost_listing do
    local off = ghost_listing[i]
    inner_ghosts[i] = CreateGridGhostMetadata(
      off, {
              hid_base    = hid_base,
              ghost_id    = ghost_id(off, ndims),
              fid         = self.id,
              ndims       = ndims,
              type_size   = self:GetTypeSize(),
              partition   = partition,
              ghost_width = ghost_width
            })
    local nb_off = {}
    for d = 1,ndims do
      nb_off[d] = -off[d]
    end
    outer_ghosts[i] = CreateGridGhostMetadata(
      off, {
              hid_base    = hid_base,
              ghost_id    = ghost_id(nb_off, ndims),
              fid         = self.id,
              ndims       = ndims,
              type_size   = self:GetTypeSize(),
              partition   = partition,
              ghost_width = ghost_width
            })
  end
  self.inner_ghosts_size = #ghost_listing
  self.outer_ghosts_size = #ghost_listing
  self.inner_ghosts = terralib.new(GhostInstance[#ghost_listing])
  self.outer_ghosts = terralib.new(GhostInstance[#ghost_listing])
  for i = 1,#ghost_listing do
    inner_ghosts[i]:CreateOutgoingGhostChannel(self.inner_ghosts[i-1])
    outer_ghosts[i]:CreateIncomingGhostChannel(self.outer_ghosts[i-1])
  end
end

local struct GhostCopyArgs {
  bounds : BoundsStruct[3];
  field : FieldInstance;
  num_ghosts : uint;
  ghosts : &GhostInstance;
}

-- send ghosts
-- TODO: incomplete
-- one or multiple actions per ghost?
local terra CopyGhostsToSend(copy_args : &opaque)
  C.printf('**** CopyGhostsToSend UINIMPLEMENTED.\n')
end
-- start_sig = last write
-- merge output signal with read
local terra CopyAndSendGhosts(start_sig : gaswrap.Signal,
                              num_ghosts : uint32, ghosts : &GhostInstance)
  var copy_sig_forked : &gaswrap.Signal =
    [&gaswrap.Signal](C.malloc(sizeof(gaswrap.Signal) * num_ghosts))
  var send_sig : &gaswrap.Signal =
    [&gaswrap.Signal](C.malloc(sizeof(gaswrap.Signal) * num_ghosts))
  gaswrap.acquireScheduler()
  -- just schedule on one worker thread for now
  var worker_id : uint32 = 0
  -- copy into buffers once start_sig triggers
  var copy_args = [&GhostCopyArgs](C.malloc(sizeof(GhostCopyArgs)))
  var copy_sig = start_sig:exec(
    worker_id, CopyGhostsToSend, copy_args)
  -- send buffers after copying
  for i = 0, num_ghosts do
    if ghosts[i].buffer == nil then
      copy_sig_forked[i]:sink()
      send_sig[i] = gaswrap.newSignalSource():trigger()
    else
      send_sig[i] = ghosts[i].src:send(copy_sig_forked[i])
    end
  end
  -- merge send done signals
  var done_sig = gaswrap.mergeSignals(num_ghosts, send_sig)
  gaswrap.releaseScheduler()
  C.free(copy_sig_forked)
  C.free(send_sig)
  return done_sig
end

-- receive ghosts
-- TODO: incomplete
-- one or multiple actions per ghost?
local terra CopyGhostsRcved(copy_args : &opaque)
  C.printf('**** CopyGhostsRcved UINIMPLEMENTED.\n')
end
-- start_sig = (? I think this should depend on the last uncentered read)
-- merge output signal with last write
local terra RecvAndCopyGhosts(start_sig : gaswrap.Signal,
                              num_ghosts : uint32, ghosts : &GhostInstance)
  var recv_and_start_sig : &gaswrap.Signal =
    [&gaswrap.Signal](C.malloc(sizeof(gaswrap.Signal) * (num_ghosts + 1)))
  gaswrap.acquireScheduler()
  -- receive all the buffers
  for i = 0, num_ghosts do
    if ghosts[i].buffer == nil then
      recv_and_start_sig[i] = gaswrap.newSignalSource():trigger()
    else
      recv_and_start_sig[i] = ghosts[i].dst:recv()
    end
  end
  -- just schedule on one worker thread for now
  var worker_id : uint32 = 0
  -- copy out from buffers once all data is received and start_sig triggers
  var copy_sig = gaswrap.mergeSignals(num_ghosts+1, recv_and_start_sig)
  -- copy into buffers
  var copy_args = [&GhostCopyArgs](C.malloc(sizeof(GhostCopyArgs)))
  var done_sig = copy_sig:exec(
    worker_id, CopyGhostsRcved, copy_args)
  -- merge send done signals
  gaswrap.releaseScheduler()
  C.free(recv_and_start_sig)
  return done_sig
end

--[[
WorkerRelation : {
  name        = 'string',
  mode        = GRID,
  dims        = { #, #, ? },
  partition   = { blocking, block_id, bounds, map },
  fields      = list{ WorkerField },
}
--]]
local WorkerRelation = {}
WorkerRelation.__index = WorkerRelation

local function NewWorkerRelation(params)
  assert(params.mode == GRID, 'Relations must be of grid type on GASNet.')
  return setmetatable({
                        id        = params.id,
                        name      = params.name,
                        mode      = params.mode,
                        dims      = params.dims,
                        periodic  = params.periodic,
                        partition = nil,
                        fields    = newlist(),
                      }, WorkerRelation)
end

function WorkerRelation:Name()
  return self.name
end

function WorkerRelation:Dims()
  return self.dims
end

function WorkerRelation:Fields()
  return self.fields
end

function WorkerRelation:RecordPartition(blocking, block_id, bounds, map)
  if self.partition ~= nil then
    print(
          'Only one partition per relation supported. Node ' ..
          tostring(gas.mynode()) .. ' already has partition ' ..
          gaswrap.lson_stringify(self.partition.bounds) .. ',' ..
          'Cannot add ' .. gaswrap.lson_stringify(bounds)
         )
    assert(false)
  end
  assert(Util.isrect2d(bounds) or Util.isrect3d(bounds))
  self.partition = {
    blocking = blocking,  -- how relation is partitioned
    block_id = block_id,  -- multi-dimensional partition block id
    bounds   = bounds,    -- bounds for this partition
    map      = map,       -- from block id to node id
  }
end

function WorkerRelation:isPartitioned()
  return self.partition
end

function WorkerRelation:RecordField(params)
  local f_id = params.id
  assert(self.fields[f_id] == nil, "Recording already recorded field '"..
                                   params.name.."' with id # "..f_id)
  self.fields:insert(f_id)
  worker_field_metadata[f_id] = NewWorkerField(self, params)
end

function WorkerRelation:GetPartition()
  return self.partition
end

function WorkerRelation:GetPartitionBounds()
  return self.partition.bounds
end

function WorkerRelation:GetPartitionMap()
  return self.partition.map
end

local function RecordNewRelation(params)
  local unq_id = params.id
  assert(worker_relation_metadata[unq_id] == nil,
         "Recordling already recorded relation '"..params.name..
         "' with id # "..unq_id)
  worker_relation_metadata[unq_id] = NewWorkerRelation(params)
end

local function GetWorkerRelation(unq_id)
  return worker_relation_metadata[unq_id]
end

function GetWorkerField(f_id)
  return worker_field_metadata[f_id]
end


-------------------------------------------------------------------------------
-- Relations, fields, partitions
-------------------------------------------------------------------------------

------------------------------------
-- EVENT BROADCASTS/ EVENT HANDLERS
------------------------------------

-- send relation metadata
local function BroadcastNewRelation(unq_id, name, mode, dims, periodic)
  assert(mode == GRID, 'Unsupported relation mode ' .. mode)
  assert(type(dims) == 'table')
  local dims_ser     = gaswrap.lson_stringify(dims)
  local periodic_ser = gaswrap.lson_stringify(periodic)
  BroadcastLuaEventToComputeNodes( 'newRelation', unq_id, name,
                                                  mode, dims_ser, periodic_ser)
end
-- event handler for relation metadata
local function CreateNewRelation(unq_id, name, mode, dims, periodic)
  RecordNewRelation {
    id       = tonumber(unq_id),
    name     = name,
    mode     = mode,
    dims     = gaswrap.lson_eval(dims),
    periodic = gaswrap.lson_eval(periodic),
  }
end

-- disjoint partition blocking over relation
-- options: send subregions here or let nodes construct it from the blocking
-- assumption: we'll have only one disjoint partitioning per relation
--             works for static relations, revisit later for dynamic relations
local function SendGlobalGridPartition(
  nid, rel_id, blocking, bid, partition, map_str
)
  local blocking_str  = gaswrap.lson_stringify(blocking)
  local block_id_str  = gaswrap.lson_stringify(bid) 
  assert(Util.isrect2d(partition) or Util.isrect3d(partition))
  local partition_str = gaswrap.lson_stringify(partition:getranges())
  gaswrap.sendLuaEvent(nid, 'globalGridPartition', rel_id, blocking_str,
                       block_id_str, partition_str, map_str)
end
local function BroadcastGlobalGridPartition(
  rel_id, blocking, partitioning, map
)
  -- map: How node/partitions are arranged into a block.
  --      So could be {{1,2}, {3,4}}.
  -- Lets controller decide which partitions go where.
  local num_partitions = 1
  for d = 1,#blocking do
    num_partitions = num_partitions * blocking[d]
  end
  assert(num_partitions == numComputeNodes(),
         'Number of partitions ' .. num_partitions ..
         ' ~= number of nodes ' .. numComputeNodes())
  local map_str = gaswrap.lson_stringify(map)
  if #blocking == 2 then
    for xid, m in ipairs(map) do
      for yid, nid in ipairs(m) do
        assert(nid >= 1 and nid <= numComputeNodes())
        SendGlobalGridPartition(nid, rel_id, blocking, {xid, yid},
                                partitioning[xid][yid], map_str)
      end
    end
  else
    assert(#blocking == 3, 'Expected 2 or 3 dimensional grid.')
    for xid, mt in ipairs(map) do
      for yid, m in ipairs(mt) do
        for zid, nid in ipairs(mt) do
          assert(nid >= 1 and nid <= numComputeNodes())
          sendGlobalGridPartition(nid, rel_id, blocking, {xid, yid, zid},
                                  partitioning[xid][yid][zid], map_str)
        end
      end
    end
  end
end
-- event handler for partition metadata
-- assumption: only one partition gets mapped to this node
-- question: how do we do local partititons in a node?
local function CreateGlobalGridPartition(rel_id, blocking_str,
                                         blocking_id_str,
                                         partition_str, map_str)
  local relation = GetWorkerRelation(tonumber(rel_id))
  assert(relation,
         'Relation #' .. rel_id .. ' to partition is not defined.')
  assert(relation.block_id == nil,
         'Already recorded a partition. ' ..
         'Are multiple partitions mapped to this node?')
  local blocking  = gaswrap.lson_eval(blocking_str)
  local block_id  = gaswrap.lson_eval(blocking_id_str)
  local range     = gaswrap.lson_eval(partition_str)
  if not range[3] then range[3] = {1,1} end
  local bounds = Util.NewRect3d(unpack(range))
  local map       = gaswrap.lson_eval(map_str)
  relation:RecordPartition(blocking, block_id, bounds, map)
end

-- record a new field over a relation
local function BroadcastNewField(f_id, rel_id, field_name, type_size)
  BroadcastLuaEventToComputeNodes('recordNewField', f_id, rel_id, field_name,
                                                    type_size)
end
local function RecordNewField(f_id, rel_id, field_name, type_size)
  local relation = GetWorkerRelation(tonumber(rel_id))
  relation:RecordField {
    id        = tonumber(f_id),
    name      = field_name,
    type_size = tonumber(type_size)
  }
end

local hid_base_used = 0

-- allocate field array over remote nodes and channels between neighbors
-- shared memory, one array across threads for now
local function RemotePrepareField(f_id, ghost_width, hid_base)
  hid_base_used = hid_base_used + 1
  BroadcastLuaEventToComputeNodes('prepareField', f_id,
                                  gaswrap.lson_stringify(ghost_width),
                                  hid_base_used)
end
-- event handler to allocate arrays, and channels for a field
local function PrepareField(f_id, ghost_width_str, hid_base)
  local field = GetWorkerField(tonumber(f_id))
  assert(field, 'Attempt to allocate unrecorded field #'..f_id)
  local ghost_width = gaswrap.lson_eval(ghost_width_str)
  field:AllocateInstance(ghost_width)
  field:SetUpGhostChannels(hid_base, ghost_width)
end


local function stringify_binary_data( n_bytes, valptr )
  assert(n_bytes % 4 == 0, 'unexpected size, bin_stringify NEEDS FIXING')
  local n_words   = n_bytes / 4
  local w_ptr     = terralib.cast(&uint32, valptr)
  local num_list  = newlist()
  for k=1,n_words do num_list[k] = w_ptr[k-1] end
  return gaswrap.lson_stringify(num_list)
end
local function destringify_binary_data( valstr, n_bytes, valptr )
  assert(n_bytes % 4 == 0, 'unexpected size, bin_destringify NEEDS FIXING')
  local num_list  = gaswrap.lson_eval(valstr)
  local n_words   = n_bytes / 4
  local w_ptr     = terralib.cast(&uint32, valptr)
  for k=1,n_words do w_ptr[k-1] = num_list[k] end
end

--
-- just constant for now
local function RemoteLoadFieldConstant(f_id, n_bytes, valptr)
  local value_ser = stringify_binary_data(n_bytes, valptr)
  BroadcastLuaEventToComputeNodes('loadFieldConstant', f_id, value_ser)
end
local struct LoadConstArgs{
  data_ptr  : &uint8
  valptr    : &uint8
  val_size  : uint32
  n_elems   : uint32
}
local terra load_field_constant_action(raw_args : &opaque)
  var args        = [&LoadConstArgs](raw_args)
  var data_ptr    = args.data_ptr
  var valptr      = args.valptr
  var val_size    = args.val_size
  var n_elems     = args.n_elems
  -- fill out array
  for i=0, n_elems do
    for k=0, val_size do
      data_ptr[k] = valptr[k]
    end
    data_ptr = data_ptr + val_size
  end
  -- free
  C.free(valptr)
  C.free(args)
end
local terra alloc_temp_val( n_bytes : uint32 ) : &uint8
  var p = [&uint8](C.malloc(n_bytes))
  for k=0,n_bytes do p[k] = 0 end
  return p
end
local terra alloc_LoadConstArgs()
  return [&LoadConstArgs](C.malloc(sizeof(LoadConstArgs)))
end
local function LoadFieldConstant(f_id, value_ser)
  local field    = GetWorkerField(tonumber(f_id))
  assert(field, 'Attempt to load into unrecorded field ' .. f_id .. '.')
  assert(field:isAllocated(), 'Attempt to load into unallocated field ' ..
                              field:Name())

  local args        = alloc_LoadConstArgs()
  args.data_ptr     = terralib.cast(&uint8, field:GetDataPtr())
  local elem_stride = field:GetTypeStride()
  -- fill out the value with up-to-stride 0-padded
  args.valptr       = alloc_temp_val(elem_stride)
  destringify_binary_data(value_ser, field:GetTypeSize(), args.valptr)
  args.val_size     = elem_stride
  args.n_elems      = field:GetElemCount()

  -- schedule action to load the field.
  local worker_id = 0
  -- single threaded right now
  gaswrap.acquireScheduler()
  local a_in  = field:GetReadWriteSignal()
  local a_out = a_in:exec(worker_id,
                          load_field_constant_action:getpointer(),
                          args)
  field:SetReadWriteSignal(a_out)
  gaswrap.releaseScheduler()
end


-----------------------------------
-- HELPER METHODS FOR CONTROL NODE
-----------------------------------

local controller_relations = {}
local controller_fields    = {}

--[[
  id,
  dims,
  _partition_map,
  _partition_bounds,
--]]
local ControllerGridRelation    = {}
ControllerGridRelation.__index  = ControllerGridRelation
local function is_cgrid_relation(obj)
  return getmetatable(obj) == ControllerGridRelation
end

--[[
  rel_id,
  id,
  type,
  ready,       -- move this out to a table?
  waiting_on,  -- move this out to a table?
--]]
local ControllerField   = {}
ControllerField.__index = ControllerField
local function is_cfield(obj) return getmetatable(obj) == ControllerField end

--[[
  name = 'string'
  dims = {1d,2d,3d}
--]]
local relation_id_counter = 1
local function NewGridRelation(args)
  assert(type(args)=='table','expected table')
  assert(type(args.name) == 'string',"expected 'name' string arg")
  assert(is_2_nums(args.dims) or is_3_nums(args.dims),
         "expected 'dims' arg: list of 2 or 3 numbers")

  local rel_id        = relation_id_counter
  relation_id_counter = rel_id + 1

  BroadcastNewRelation(rel_id, args.name, GRID, args.dims, args.periodic)

  local rel = setmetatable({
    id       = rel_id,
    dims     = args.dims,
    periodic = args.periodic,
  }, ControllerGridRelation)
  controller_relations[rel.id] = rel
  return rel
end

--[[
  name = 'string'
  rel  = ControllerGridRelation
  type = TerraType
--]]
local field_id_counter = 1
local function NewField(args)
  assert(type(args)=='table','expected table')
  assert(type(args.name) == 'string',"expected 'name' string arg")
  assert(is_cgrid_relation(args.rel),"expected 'rel' relation arg")
  assert(terralib.types.istype(args.type),"expected 'type' terra type arg")

  local f_id        = field_id_counter
  field_id_counter  = f_id + 1

  -- create the field
  BroadcastNewField(f_id, args.rel.id, args.name, terralib.sizeof(args.type))
  -- allocate memory to back the field
  local ghosts = {}
  for i,_ in ipairs(args.rel.dims) do ghosts[i] = BASIC_SAFE_GHOST_WIDTH end
  RemotePrepareField(f_id, ghosts, f_id)

  local f = setmetatable({
    id      = f_id,
    rel_id  = args.rel.id,
    type    = args.type,
    ready   = false,   -- set ready when field arrays and channels are set up
    waiting_on = numComputeNodes(),
  }, ControllerField)
  controller_fields[f.id] = f

  return f
end

--[[
  blocking = {#,#,?} -- dimensions of grid of blocks
--]]
function ControllerGridRelation:partition_across_nodes(args)
  assert(type(args)=='table','expected table')
  assert(is_2_nums(args.blocking) or is_3_nums(args.blocking),
         "expected 'blocking' arg: list of 2 or 3 numbers")
  local dims    = self.dims
  local blocks  = args.blocking
  assert(#dims == #blocks, 'dimension of blocking did not '..
                           'match dimension of grid')
  local bounds  = {}
  local map     = {}
  for i=1,#dims do assert(dims[i] > blocks[i], '# cells < # blocks') end

  -- generate bounds and map
  local nX,nY,nZ = unpack(blocks)
  if #dims == 2 then
    local dx      = math.floor(dims[1] / nX)
    local xlo,xhi = 0, dims[1] - dx*(nX-1)
    for i=1,nX do
      bounds[i], map[i] = {},{}

      local dy      = math.floor(dims[2] / nY)
      local ylo,yhi = 0, dims[2] - dy*(nY-1)
      for j=1,nY do
        local node_id = (i-1)*nY + (j-1) + 1
        map[i][j]     = node_id
        bounds[i][j]  = Util.NewRect2d({xlo,xhi-1},{ylo,yhi-1})
        ylo,yhi = yhi,yhi+dy
      end
      xlo,xhi = xhi,xhi+dx
    end
  else assert(#dims == 3)
    local dx      = math.floor(dims[1] / nX)
    local xlo,xhi = 0, dims[1] - dx*(nX-1)
    for i=1,nX do
      bounds[i], map[i] = {},{}

      local dy      = math.floor(dims[2] / nY)
      local ylo,yhi = 0, dims[2] - dy*(nY-1)
      for j=1,nY do
        bounds[i][j], map[i][j] = {},{}

        local dz      = math.floor(dims[3] / nZ)
        local zlo,zhi = 0, dims[3] - dz*(nZ-1)
        for k=1,nZ do
          local node_id   = (i-1)*nY*nZ + (j-1)*nZ + (k-1) + 1
          map[i][j][k]    = node_id
          bounds[i][j][k] = Util.NewRect3d({xlo,xhi-1},{ylo,yhi-1},{zlo,zhi-1})
          zlo,zhi = zhi,zhi+dz
        end
        ylo,yhi = yhi,yhi+dy
      end
      xlo,xhi = xhi,xhi+dx
    end
  end

  self._partition_map     = map
  self._partition_bounds  = bounds
  BroadcastGlobalGridPartition(self.id, blocks, bounds, map)
end

-- TODO:
-- local partitions (for partitioning task across threads)
function ControllerGridRelation:partition_within_nodes()
end

function ControllerField:LoadConst( c_val )
  local typsize   = terralib.sizeof(self.type)
  local temp_mem  = terralib.cast(&self.type, C.malloc(typsize))
  temp_mem[0]     = c_val
  RemoteLoadFieldConstant(self.id, typsize, temp_mem)
  C.free(temp_mem)
end

-- Mark ghosts instances (buffers and channels) ready to use for a field
local function MarkGhostsReady(fid, hid_base)
  -- ignore hid_base for now
  -- assume only one set of ghost channels (one hid_base) per field
  local field = controller_fields[tonumber(fid)]
  field.waiting_on = field.waiting_on - 1
  if field.waiting_on == 0 then
    field.ready = true
  end
end

function ControllerField:SpinTillReady()
  while not self.ready do
    C.usleep(POLL_USLEEP)
    gaswrap.pollLuaEvents(0, 0)
  end
end

-------------------------------------------------------------------------------
-- Handle actions over sets of fields and privileges
-------------------------------------------------------------------------------

-- **** THIS SECTION IS VERY UNSTABLE AND INCOMPLETE ****

--[[
Each task is associated with:
  * terra code for the task
  * relation the task is compiled for
  * processor (CPU or GPU)
  * field_accesses
  * .. globals not yet
Each ufversion maps to a unique task.
The controller node is responsible for managing mapping between functions
and ufversions, making launch decisions, and invoking the correct task with
a selected partitioning.
If the controller decides to invoke a function across cpus + gpus (in rare
cases?), it is responsible for invoking two tasks, the cpu version and the gpu
version, with the correct partitioning.
Compute nodes should not be making these decisions.

A task can be invoked with different partitionings. This partitioning only
determines how a task is run in parallel all the local processors, and over
what parts of the relation.
A task partitioning over a relation must be registered separately before a task
with that partitioning is invoked.

For now, we assume that the controller node has allocated data correctly on
worker nodes, to support all the tasks (with uncentered accesses), and
that there is only one instance of data for every {relation, field}.
--]]

--[[
{
  id,
  name, (optional)
  func, (args : bounds, ordered list of fields, 0 indexed, return : void)
  rel_id,
  processor,
  fields, (ordered list, 1 indexed)
  field_accesses
}
--]]



-----------------------------------
-- Field Accesses
-----------------------------------


-- enum constants
local READ_ONLY_PRIVILEGE     = 1
local READ_WRITE_PRIVILEGE    = 2
local REDUCE_PRIVILEGE        = 3
Exports.READ_ONLY_PRIVILEGE   = READ_ONLY_PRIVILEGE
Exports.READ_WRITE_PRIVILEGE  = READ_WRITE_PRIVILEGE
Exports.REDUCE_PRIVILEGE      = REDUCE_PRIVILEGE

--[[
{
  privilege   = <enum>,
  field       = ControllerField,
}
--]]
local FAccess           = {}
FAccess.__index         = FAccess
local function NewFAccess(args)
  assert(is_cfield(args.field), 'expecting ewrap field arg')
  return setmetatable({
    privilege   = assert(args.privilege),
    field       = args.field,
    centered    = args.centered,
    -- TODO: Add stencil support 
  }, FAccess)
end
local function is_faccess(obj) return getmetatable(obj) == FAccess end

--[[
{
  privilege   = <enum>,
  field       = WorkerField,
}
--]]
local WorkerFAccess     = {}
WorkerFAccess.__index   = WorkerFAccess
local function NewWorkerFAccess(rawobj)
  local field = GetWorkerField(rawobj.f_id)
  return setmetatable({
    privilege   = assert(rawobj.privilege),
    field       = field,
  }, WorkerFAccess)
end






-----------------------------------
-- Task Creation
-----------------------------------


local ControllerTask    = {}
ControllerTask.__index  = ControllerTask
local WorkerTask        = {}
WorkerTask.__index      = WorkerTask
local task_id_counter   = 0
local worker_task_store = {}

local struct TaskArgs {
  bounds : BoundsStruct[3];
  fields : &FieldInstance;
}

-- Event/handler for registering a new task. Returns a task id.
--[[
params : {
  func              = <terra func>,
  name              = 'string', (optional)
  rel_id            = #,
  processor         = <enum>,
  field_accesses    = list{ FAccess },
}
--]]
local function RegisterNewTask(params)
  assert(on_control_node())
  assert(type(params) == 'table', 'expect named args')
  assert(terralib.isfunction(params.func),
                                "expect arg: terra function 'func'")
  assert(is_cgrid_relation(params.relation),
                                "expect arg: ewrap relation 'relation'")
  assert(params.processor,      "expect arg: enum value 'processor'")
  assert(params.field_accesses, "expect arg: list of FAccess 'field_ids'")

  assert(params.processor == Pre.CPU, 'Only CPU tasks supported right now.')

  -- generate id and other arguments
  task_id_counter = task_id_counter + 1
  local task_id   = task_id_counter
  local task_name = params.name or params.func:getname()
  local fas       = newlist()
  for i,fa in ipairs(params.field_accesses) do
    assert(is_faccess(fa), "entry #"..i.." is not a field access")
    fas:insert {
                 privilege = fa.privilege, f_id = fa.field.id,
                 centered  = fa.centered,
               }
  end
  local bitcode   = terralib.saveobj(nil,'bitcode',{[task_name]=params.func})

  -- broadcast to workers
  BroadcastLuaEventToComputeNodes('newTask', bitcode,
    gaswrap.lson_stringify {
      id              = task_id,
      name            = task_name,
      rel_id          = params.relation.id,
      processor       = tostring(params.processor),
      field_accesses  = fas,
  })

  local controller_task = setmetatable({
    id             = task_id,
    rel_id         = params.rel_id,
    field_accesses = shallow_copy(params.field_accesses),
  }, ControllerTask)
  return controller_task
end

local keep_hooks_live = newlist()
local function NewWorkerTask(bitcode, metadata)
  local md          = gaswrap.lson_eval(metadata)
  assert(md.processor == 'CPU')

  -- convert bitcode
  local blob        = terralib.linkllvmstring(bitcode)
  local task_func   = blob:extern(md.name, {TaskArgs} -> {})
  keep_hooks_live:insert(task_func)
  keep_hooks_live:insert(blob)
  local task_wrapper = terra(args : &opaque)
    var task_args   = [&TaskArgs](args)
    --C.printf('[%d] start exec action in wrapper\n', THIS_NODE)
    task_func(@task_args)
    -- free memory allocated for args
    --C.printf('[%d] done exec action in wrapper\n', THIS_NODE)
    if task_args.fields ~= nil then C.free(task_args.fields) end
    C.free(task_args)
  end
  task_wrapper:compile()

  -- convert faccesses
  local wfaccesses = newlist()
  for i,fa in ipairs(md.field_accesses) do
    wfaccesses[i] = NewWorkerFAccess(fa)
  end

  local wtask = setmetatable({
    id              = md.id,
    name            = md.name,
    func            = task_wrapper,
    rel_id          = md.rel_id,
    processor       = Pre.CPU,
    field_accesses  = wfaccesses,
  }, WorkerTask)
  return wtask
end
local function ReceiveNewTask(bitcode, metadata)
  local task = NewWorkerTask(bitcode, metadata)
  worker_task_store[task.id] = task
end

function WorkerTask:GetRelation()
  return GetWorkerRelation(self.rel_id)
end


-----------------------------------
-- Task Execution
-----------------------------------

local terra allocTaskArgs( n_fields : uint32 ) : &TaskArgs
  var args    = [&TaskArgs]( C.malloc(sizeof(TaskArgs)) )
  if n_fields == 0 then args.fields = nil
  else
    args.fields = [&FieldInstance]( C.malloc(n_fields*sizeof(FieldInstance)) )
  end
  return args
end


function ControllerTask:exec()
  for _, fa in ipairs(self.field_accesses) do
    if fa.privilege == READ_WRITE_PRIVILEGE then
      print('*** READ WRITE! Checking if ghost channels are set up for ' ..
            fa.field.id)
      fa.field:SpinTillReady()
      print('*** Proceeding. Ghost channels seem to be set up for ' ..
            fa.field.id)
    end
  end
  BroadcastLuaEventToComputeNodes('launchTask', self.id)
end

local function LaunchTask(task_id)
  local task  = worker_task_store[tonumber(task_id)]
  assert(task, 'Task #' .. task_id ..  ' is not registered.')
  --print(THIS_NODE..' launch task started')

  -- unpack things
  local relation    = task:GetRelation()
  local n_dims      = #relation.dims

  -- allocate signal arrays
  local n_fields    = #task.field_accesses
  local sigs_f_in   = terralib.new(gaswrap.Signal[n_fields])
  local sigs_f_out  = terralib.new(gaswrap.Signal[n_fields])

  -- Assemble Arguments
  -- because a task may be scheduled more than once before being
  -- executed, we must either re-allocate the arguments each time
  -- or ensure that the arguments are the same on all executions
  local args        = allocTaskArgs(n_fields)
  local range       = relation:GetPartitionBounds():getranges()
  for d = 1,3 do
    args.bounds[d-1].lo   = range[d][1]
    args.bounds[d-1].hi   = range[d][2]
  end
  for i, fa in ipairs(task.field_accesses) do
    local local_ptr   = fa.field:GetInstance():DataPtrGhostAdjusted()
    local strides     = fa.field:GetStrides()
    local af          = args.fields[i-1]
    local offset      = 0
    for d=1,n_dims do
      offset          = offset + strides[d] * range[d][1]
      af.strides[d-1] = strides[d]
    end
    af.ptr            = local_ptr - offset * fa.field:GetTypeStride()
  end


  -- Do Scheduling
  gaswrap.acquireScheduler()
  -- collect and merge all the input signals
  for i, fa in ipairs(task.field_accesses) do
    if fa.privilege == READ_ONLY_PRIVILEGE then
      sigs_f_in[i-1]  = fa.field:ForkWriteSignal()
    elseif fa.privilege == READ_WRITE_PRIVILEGE then
      -- check if ghost channels are ready
      sigs_f_in[i-1]  = fa.field:GetReadWriteSignal()
    elseif fa.privilege == REDUCE_PRIVILEGE then
      error('TODO: REDUCE PRIV UNIMPLEMENTED')
    else assert('unrecognized field privilege') end
  end
  local a_in = nil
  if n_fields == 0 then
    a_in = gaswrap.newSignalSource():trigger()
  elseif n_fields == 1 then
    a_in = sigs_f_in[0]
  else
    a_in = gaswrap.mergeSignals(n_fields, sigs_f_in)
  end
  -- Schedule the task action itself
  local worker_id = 0 -- TODO: use partition in the future...?
  local a_out     = a_in:exec(worker_id, task.func:getpointer(), args)
  -- fork and record the output signal
  if n_fields == 0 then
    a_out:sink()
  elseif n_fields == 1 then
    sigs_f_out[0]   = a_out
  else
    a_out:fork(n_fields, sigs_f_out)
  end
  for i, fa in ipairs(task.field_accesses) do
    if fa.privilege == READ_ONLY_PRIVILEGE then
      fa.field:MergeReadSignal(sigs_f_out[i-1])
    elseif fa.privilege == READ_WRITE_PRIVILEGE then
      fa.field:SetReadWriteSignal(sigs_f_out[i-1])
    elseif fa.privilege == REDUCE_PRIVILEGE then
      error('TODO: REDUCE PRIV UNIMPLEMENTED')
    else assert('unrecognized field privilege') end
  end
  -- Release
  gaswrap.releaseScheduler()
  --print(THIS_NODE..' launch task exited')
end

-- Task sequences can be done using:
--   1. update single task launch to support a sequence
--      pros: reduce communication/lua event overhead
--      not sure if we actually need this
--   2. register a new terra task that performs a series of tasks
--      pros: can reorder/transform code when fusing tasks
--      cons: probably not trivial to support any data exchanges within the task








-------------------------------------------------------------------------------
-- Extra Events
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- Register event handlers 
-------------------------------------------------------------------------------

-- relational data
gaswrap.registerLuaEvent('newRelation',         CreateNewRelation)
gaswrap.registerLuaEvent('globalGridPartition', CreateGlobalGridPartition)
gaswrap.registerLuaEvent('recordNewField',      RecordNewField)
gaswrap.registerLuaEvent('prepareField',        PrepareField)
gaswrap.registerLuaEvent('loadFieldConstant',   LoadFieldConstant)
gaswrap.registerLuaEvent('markGhostsReady',     MarkGhostsReady)

-- task code and data
gaswrap.registerLuaEvent('newTask',             ReceiveNewTask)
gaswrap.registerLuaEvent('launchTask',          LaunchTask)


-------------------------------------------------------------------------------
-- Exports for testing
-------------------------------------------------------------------------------

Exports._TESTING_BroadcastNewRelation         = BroadcastNewRelation
Exports._TESTING_BroadcastGlobalGridPartition = BroadcastGlobalGridPartition
Exports._TESTING_BroadcastNewField            = BroadcastNewField
Exports._TESTING_RemotePrepareField           = RemotePrepareField
Exports._TESTING_RemoteLoadFieldConstant      = RemoteLoadFieldConstant
Exports._TESTING_BroadcastLuaEventToComputeNodes =
  BroadcastLuaEventToComputeNodes

-------------------------------------------------------------------------------
-- Exports
-------------------------------------------------------------------------------

Exports.N_NODES                       = N_NODES
Exports.THIS_NODE                     = THIS_NODE

Exports.NewGridRelation               = NewGridRelation
Exports.NewField                      = NewField
Exports.RegisterNewTask               = RegisterNewTask

Exports.TaskArgs                      = TaskArgs
Exports.FieldInstance                 = FieldInstance
Exports.NewFAccess                    = NewFAccess
Exports.RegisterNewTask               = RegisterNewTask



