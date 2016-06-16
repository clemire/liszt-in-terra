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

local UF   = {}
package.loaded["ebb.src.ufversions"] = UF

local use_legion = not not rawget(_G, '_legion_env')
local use_single = not use_legion

local Pre = require "ebb.src.prelude"
local C   = require "ebb.src.c"
local G   = require "ebb.src.gpu_util"
local T   = require "ebb.src.types"

local CPU       = Pre.CPU
local GPU       = Pre.GPU
local uint64T   = T.uint64
local keyT      = T.key

local EbbGlobal = Pre.Global

local codegen         = require "ebb.src.codegen"
local codesupport     = require "ebb.src.codegen_support"
local LE, legion_env, LW, run_config
if use_legion then
  LE = rawget(_G, '_legion_env')
  legion_env = LE.legion_env[0]
  LW = require 'ebb.src.legionwrap'
  run_config = rawget(_G, '_run_config')
end
local use_partitioning = use_legion and run_config.use_partitioning
local DataArray       = require('ebb.src.rawdata').DataArray

local F         = require 'ebb.src.functions'
local UFunc     = F.Function
local UFVersion = F.UFVersion
local _INTERNAL_DEV_OUTPUT_PTX = F._INTERNAL_DEV_OUTPUT_PTX

local VERBOSE = rawget(_G, 'EBB_LOG_EBB')

-- Create a Lua Object that generates the needed Terra structure to pass
-- fields, globals and temporary allocated memory to the function as arguments
local ArgLayout = {}
ArgLayout.__index = ArgLayout


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ UFVersion                                                             ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


function UFVersion:Execute()
  if not self:isCompiled() then
    self:Compile()
  end

  UFVersion._total_function_launch_count:increment()

  self._exec_timer:start()

  -- Regardless of the caching, we need to make sure
  -- that the current state of the system and relevant data safely allows
  -- us to launch the UFunc.  This might include checks to make sure that
  -- all of the relevant data does in fact exist, and that any invariants
  -- we assumed when the UFunc was compiled and cached are still true.
  self:_DynamicChecks()

  -- Next, we partition the primary relation and other relations that are
  -- referenced fro UFunc. Separating this out from Launch will keep the record
  -- phase for stencil analysis separate from actual function code.
  self:_PartitionData()

  -- Next, we bind all the necessary data into the version.
  -- This involves looking up appropriate pointers, argument values,
  -- data location, Legion or CUDA parameters, and packing
  -- appropriate structures
  self:_BindData()

  --local prelaunch = terralib.currenttimeinseconds()
  -- Then, once all the data is bound and marshalled, we
  -- can actually launch the computation.  Oddly enough, this
  -- may require some amount of further marshalling and binding
  -- of data depending on what runtime this version is being launched on.
  self:_Launch()
  --LAUNCH_TIMER = LAUNCH_TIMER + (terralib.currenttimeinseconds() - prelaunch)

  -- Finally, some features may require some post-processing after the
  -- launch of the UFunc.  This hook provides a place for
  -- any such computations.
  self:_PostLaunchCleanup()

  self._exec_timer:stop()
end

-- Define ways of inspecting high-level UFVersion state/modes
function UFVersion:isCompiled()
  return nil ~= self._executable
end
function UFVersion:UsesInsert()
  return nil ~= self._insert_data
end
function UFVersion:UsesDelete()
  return nil ~= self._delete_data
end
function UFVersion:UsesGlobalReduce()
  return next(self._global_reductions) ~= nil
end
function UFVersion:isOnGPU()
  return self._proc == GPU
end
function UFVersion:overElasticRelation()
  return self._is_elastic
end
function UFVersion:isOverSubset()
  return nil ~= self._subset
end
function UFVersion:isBoolMaskSubset()
  return nil ~= self._subset._boolmask
end
function UFVersion:isIndexSubset()
  return nil ~= self._subset._index
end

--                  ---------------------------------------                  --
--[[ UF Compilation                                                        ]]--
--                  ---------------------------------------                  --

function UFVersion:Compile()
  self._compile_timer:start()

  local typed_ast   = self._typed_ast
  local phase_data  = self._phase_data

  self._arg_layout = ArgLayout.New()
  self._arg_layout:setRelation(self._relation)

  -- compile various kinds of data into the arg layout
  self:_CompileFieldsGlobalsSubsets(phase_data)

  -- also compile insertion and/or deletion if used
  if phase_data.inserts then self:_CompileInserts(phase_data.inserts) end
  if phase_data.deletes then self:_CompileDeletes(phase_data.deletes) end

  -- handle GPU specific compilation
  if self:isOnGPU() and self:UsesGlobalReduce() then
    self._sharedmem_size = 0
    self:_CompileGPUReduction()
  end

  if use_single then
    -- allocate memory for the arguments struct on the CPU.  It will be used
    -- to hold the parameter values that will be passed to the Ebb function.
    self._args = DataArray.New{
      size = 1,
      type = self._arg_layout:TerraStruct(),
      processor = CPU -- DON'T MOVE
    }
    
    -- compile an executable
    self._executable = codegen.codegen(typed_ast, self)

  elseif use_legion then
    self:_CompileLegion(typed_ast)
  else
    error("INTERNAL: IMPOSSIBLE BRANCH")
  end

  self._compile_timer:stop()
end

--  We do not use write discard and reduce privileges in Legion right now. When
--  we do use those features, record_permission should be updated to reflect
--  the correct privileges and coherence values.
local function record_permission(reg_data, use)
  -- The three cases are read only, centered (read/ write) and reduce.
  if use:isReadOnly() then
    reg_data.privilege = LW.READ_ONLY
  elseif use:isCentered() then
    reg_data.privilege = LW.READ_WRITE
  else
    reg_data.privilege = LW.REDUCE
    if LW.reduction_ops[use:reductionOp()] == nil or
      T.typenames[reg_data.field:Type()] == nil then
      error('Reduction operation ' .. use:reductionOp() ..
            ' on '.. tostring(reg_data.field:Type()) ..
            ' currently unspported with Legion')
    end
    reg_data.redoptyp  = 'field_' .. (LW.reduction_ops[use:reductionOp()]  or 'none') ..
                         '_' .. T.typenames[reg_data.field:Type()]
  end
  reg_data.coherence   = LW.EXCLUSIVE
end

-- Set privilege to read, coherence to exclusive, useful for primary and
-- boolmasks.
local function record_read(reg_data)
  reg_data.privilege = LW.READ_WRITE
  reg_data.coherence = LW.EXCLUSIVE
end

function UFVersion:_CompileFieldsGlobalsSubsets(phase_data)
  -- initialize id structures
  self._field_ids    = {}
  self._n_field_ids  = 0

  self._global_ids   = {}
  self._n_global_ids = 0

  self._global_reductions = {}

  if use_legion then
    self._region_data        = {}
    self._sorted_region_data = {}
    self._n_regions          = 0

    self._future_nums  = {}
    self._n_futures    = 0
    self._global_reduce = nil

    local reg_data = self:_getPrimaryRegionData()
  end

  -- reserve ids
  self._field_use = phase_data.field_use
  for field, use in pairs(self._field_use) do
    self:_getFieldId(field)
    -- record region data for legion
    -- (logical region, region number, permission)
    if use_legion then
      local reg_data = self:_getRegionData(field)
      record_permission(reg_data, use)
    end
  end
  if self:overElasticRelation() then
    if use_legion then error("LEGION UNSUPPORTED TODO") end
    self:_getFieldId(self._relation._is_live_mask)
  end
  if self:isOverSubset() then
    if self._subset._boolmask then
      self:_getFieldId(self._subset._boolmask)
      if use_legion then
        local reg_data = self:_getRegionData(self._subset._boolmask)
        record_read(reg_data)
      end
      self._compiled_with_boolmask = true
    end
  end
  self._global_use = phase_data.global_use
  for globl, phase in pairs(self._global_use) do
    local gid = self:_getGlobalId(globl)

    -- record reductions
    if phase.reduceop then
      self._uses_global_reduce = true
      local ttype             = globl._type:terratype()

      local reduce_data       = self:_getReduceData(globl)
      reduce_data.phase       = phase
    end
  end

  -- compile subsets in if appropriate
  if self._subset then
    self._arg_layout:turnSubsetOn()
  end
end

--                  ---------------------------------------                  --
--[[ UFVersion Interface for Codegen / Compilation                         ]]--
--                  ---------------------------------------                  --

function UFVersion:_argsType ()
  return self._arg_layout:TerraStruct()
end

local function get_region_data(ufv, relation, field)
  if not use_legion then
    error('INTERNAL: Should only try to record Regions '..
          'when running on the Legion Runtime')
  end
  -- NOTE WE create a new region data for each region/field pair
  local sig = tostring(relation:_INTERNAL_UID())
  if field then sig = sig ..'_'..tostring(field._fid) end
  local reg_data    = ufv._region_data[sig]
  if reg_data then return reg_data
  else
    if ufv._arg_layout:isCompiled() then
      error('INTERNAL ERROR: cannot add region after compiling \n'..
            '  argument layout.  (debug data follows)\n'..
            '      violating relation: '..relation:Name())
    end
    
    local reg_data = {
      wrapper   = relation._logical_region_wrapper,
      num       = ufv._n_regions,
      relation  = relation,
      field     = field,
      privilege = LW.NO_ACCESS,
      coherence = LW.EXCLUSIVE,
      redop     = nil
    }
    ufv._n_regions = ufv._n_regions + 1

    ufv._region_data[sig]                 = reg_data
    ufv._sorted_region_data[reg_data.num] = reg_data
    return reg_data
  end
end

function UFVersion:_getPrimaryRegionData()
  if use_single then error("INTERNAL: Cannot use regions w/o Legion") end
  self._primary_region = get_region_data(self, self._relation)
  return self._primary_region
end

function UFVersion:_getRegionData(field)
  if use_single then error("INTERNAL: Cannot use regions w/o Legion") end
  local rel         = field:Relation()
  return get_region_data(self, rel, field)
end

function UFVersion:_getFutureNum(globl)
  if use_single then error("INTERNAL: Cannot use futures w/o Legion") end
  local fut_num     = self._future_nums[globl]
  if fut_num then return fut_num
  else
    if self._arg_layout:isCompiled() then
      error('INTERNAL ERROR: cannot add future after compiling '..
            'argument layout.')
    end

    fut_num         = self._n_futures
    self._n_futures = self._n_futures + 1

    self._future_nums[globl] = fut_num
    return fut_num
  end
end

function UFVersion:_getFieldId(field)
  local id = self._field_ids[field]
  if id then return id
  else
    id = 'field_'..tostring(self._n_field_ids)..'_'..field:Name()
    self._n_field_ids = self._n_field_ids+1

    self._field_ids[field] = id
    self._arg_layout:addField(id, field)
    return id
  end
end

function UFVersion:_getGlobalId(global)
  local id = self._global_ids[global]
  if id then return id
  else
    id = 'global_'..tostring(self._n_global_ids) -- no global names
    self._n_global_ids = self._n_global_ids+1

    if use_legion then self:_getFutureNum(global) end

    self._global_ids[global] = id
    self._arg_layout:addGlobal(id, global)
    return id
  end
end

function UFVersion:_getReduceData(global)
  local data = self._global_reductions[global]
  if not data then
    local gid = self:_getGlobalId(global)
    local id  = 'reduce_globalmem_'..gid:sub(#'global_' + 1)
         data = { id = id }

    self._global_reductions[global] = data
    if self:isOnGPU() then
      self._arg_layout:addReduce(id, global._type:terratype())
    end
  end
  return data
end

function UFVersion:_setFieldPtr(field)
  if use_legion then
    error('INTERNAL: Do not call setFieldPtr() when using Legion') end
  local id = self:_getFieldId(field)
  local dataptr = field:_Raw_DataPtr()
  self._args:_raw_ptr()[id] = dataptr
end
function UFVersion:_setGlobalPtr(global)
  if use_legion then
    error('INTERNAL: Do not call setGlobalPtr() when using Legion') end
  local id = self:_getGlobalId(global)
  local dataptr = global:_Raw_DataPtr()
  self._args:_raw_ptr()[id] = dataptr
end

function UFVersion:_getLegionGlobalTempSymbol(global)
  local id = self:_getGlobalId(global)
  if not self._legion_global_temps then self._legion_global_temps = {} end
  local sym = self._legion_global_temps[id]
  if not sym then
    local ttype = global._type:terratype()
    sym = symbol(&ttype)
    self._legion_global_temps[id] = sym
  end
  return sym
end
function UFVersion:_getTerraGlobalPtr(args_sym, global)
  local id = self:_getGlobalId(global)
  return `[args_sym].[id]
end


--                  ---------------------------------------                  --
--[[ UFVersion Dynamic Checks                                              ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicChecks()
  if use_single then
    -- Check that the fields are resident on the correct processor
    local underscore_field_fail = nil
    for field, _ in pairs(self._field_ids) do
      if field._array:location() ~= self._proc then
        if field:Name():sub(1,1) == '_' then
          underscore_field_fail = field
        else
          error("cannot execute function because field "..field:FullName()..
                " is not currently located on "..tostring(self._proc), 3)
        end
      end
    end
    if underscore_field_fail then
      error("cannot execute function because hidden field "..
            underscore_field_fail:FullName()..
            " is not currently located on "..tostring(self._proc), 3)
    end
  end

  if self:isOverSubset() then
    if self._compiled_with_boolmask and not self:isBoolMaskSubset() then
      error('INTERNAL: Should not try to run a function compiled for '..
            'boolmask subsets over an index subset')
    elseif not self._compiled_with_boolmask and not self:isIndexSubset() then
      error('INTERNAL: Should not try to run a function compiled for '..
            'index subsets over a boolmask subset')
    end
  end

  if self:UsesInsert()  then  self:_DynamicInsertChecks()  end
  if self:UsesDelete()  then  self:_DynamicDeleteChecks()  end
end


-------------------------------------------------------------------------------
--[[ Ufversion Data Partitioning                                           ]]--
-------------------------------------------------------------------------------

function UFVersion:_PartitionData()
  if not use_legion then return end
  self:_addPrimaryPartition()
  for field, _ in pairs(self._field_use) do
    self:_addRegionPartition(field, false)
  end
  if self:isOverSubset() then
    assert(self._subset._boolmask)
    self:_addRegionPartition(self._subset._boolmask, true)
  end
end


--                  ---------------------------------------                  --
--[[ UFVersion Data Binding                                                ]]--
--                  ---------------------------------------                  --

function UFVersion:_BindData()
  -- Bind inserts and deletions before anything else, because
  -- the binding may trigger computations to re-size/re-allocate
  -- data in some cases, invalidating previous data pointers
  if self:UsesInsert()  then  self:_bindInsertData()       end
  if self:UsesDelete()  then  self:_bindDeleteData()       end

  -- Bind the rest of the data
  self:_bindFieldGlobalSubsetArgs()
end

function UFVersion:_bindFieldGlobalSubsetArgs()
  -- Don't worry about binding on Legion, since we need
  -- to handle that a different way anyways
  if use_legion then return end

  local argptr    = self._args:_raw_ptr()

  -- Case 1: subset indirection index
  if self._subset and self._subset._index then
    argptr.index        = self._subset._index:_Raw_DataPtr()
    -- Spoof the number of entries in the index, which is what
    -- we actually want to iterate over
    argptr.bounds[0].lo = 0
    argptr.bounds[0].hi = self._subset._index:Size() - 1 

  -- Case 2: elastic relation
  elseif self:overElasticRelation() then
    argptr.bounds[0].lo = 0
    argptr.bounds[0].hi = self._relation:ConcreteSize() - 1

  -- Case 3: generic staticly sized relation
  else
    local dims = self._relation:Dims()
    for d=1,#dims do
      argptr.bounds[d-1].lo = 0
      argptr.bounds[d-1].hi = dims[d] - 1
    end

  end

  -- set field and global pointers
  for field, _ in pairs(self._field_ids) do
    self:_setFieldPtr(field)
  end
  for globl, _ in pairs(self._global_ids) do
    self:_setGlobalPtr(globl)
  end
end

--                  ---------------------------------------                  --
--[[ UFVersion Launch                                                      ]]--
--                  ---------------------------------------                  --

function UFVersion:_Launch()
  if VERBOSE then
    local data_deps = "Ebb LOG: function " .. self._ufunc._name .. " accesses"
    for field, use in pairs(self._field_use) do
      data_deps = data_deps .. " relation " .. field:Relation():Name()
      data_deps = data_deps .. " field " .. field:Name() .. " in phase "
      data_deps = data_deps .. tostring(use) .. " ,"
    end
    for global, use in pairs(self._global_use) do
      data_deps = data_deps .. " global " .. tostring(global) .. " in phase "
      data_deps = data_deps .. tostring(use) .. " ,"
    end
    print(data_deps)
  end
  if use_legion then
    self._executable({ ctx = legion_env.ctx, runtime = legion_env.runtime })
  else
    self._executable(self._args:_raw_ptr())
  end
end

--                  ---------------------------------------                  --
--[[ UFVersion Postprocess / Cleanup                                       ]]--
--                  ---------------------------------------                  --

function UFVersion:_PostLaunchCleanup()
  -- GPU Reduction finishing and cleanup
  --if self:isOnGPU() then
  --  if self:UsesGlobalReduce() then  self:postprocessGPUReduction()  end
  --end

  -- Handle post execution Insertion and Deletion Behaviors
  if self:UsesInsert()         then   self:_postprocessInsertions()    end
  if self:UsesDelete()         then   self:_postprocessDeletions()     end
end



-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Insert / Delete Extensions                                            ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

--                  ---------------------------------------                  --
--[[ Insert Processing ; all 4 stages (-launch)                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_CompileInserts(inserts)
  local ufv = self
  --ufv._inserts = inserts

  -- max 1 insert allowed
  local rel, ast_nodes = next(inserts)
  -- stash some useful data
  ufv._insert_data = {
    relation    = rel, -- relation we're going to insert into, not map over
    record_type = ast_nodes[1].record_type,
    write_idx   = EbbGlobal(uint64T, 0),
  }
  -- register the global variable
  ufv:_getGlobalId(ufv._insert_data.write_idx)

  -- prep all the fields we want to be able to write to.
  for _,field in ipairs(rel._fields) do
    ufv:_getFieldId(field)
  end
  ufv:_getFieldId(rel._is_live_mask)
  ufv._arg_layout:addInsertion()
end

function UFVersion:_DynamicInsertChecks()
  if use_legion then error('INSERT unsupported on legion currently', 4) end

  local rel = self._insert_data.relation
  local unsafe_msg = rel:UnsafeToInsert(self._insert_data.record_type)
  if unsafe_msg then error(unsafe_msg, 4) end
end

function UFVersion:_bindInsertData()
  local insert_rel                    = self._insert_data.relation
  local center_size_logical           = self._relation:Size()
  local insert_size_concrete          = insert_rel:ConcreteSize()
  local insert_size_logical           = insert_rel:Size()
  --print('INSERT BIND',
  --  center_size_logical, insert_size_concrete, insert_size_logical)

  -- point the write index at the first entry after the end of the
  -- used portion of the data arrays
  self._insert_data.write_idx:set(insert_size_concrete)
  -- cache the old sizes
  self._insert_data.last_concrete_size = insert_size_concrete
  self._insert_data.last_logical_size  = insert_size_logical

  -- then make sure to reserve enough space to perform the insertion
  -- don't worry about updating logical size here
  insert_rel:_INTERNAL_Resize(insert_size_concrete + center_size_logical)
end

function UFVersion:_postprocessInsertions()
  local insert_rel        = self._insert_data.relation
  local old_concrete_size = self._insert_data.last_concrete_size
  local old_logical_size  = self._insert_data.last_logical_size

  local new_concrete_size = tonumber(self._insert_data.write_idx:get())
  local n_inserted        = new_concrete_size - old_concrete_size
  local new_logical_size  = old_logical_size + n_inserted
  --print("POST INSERT",
  --  old_concrete_size, old_logical_size, new_concrete_size,
  --  n_inserted, new_logical_size)

  -- shrink array back to fit how much we actually wrote
  insert_rel:_INTERNAL_Resize(new_concrete_size, new_logical_size)

  -- NOTE that this relation is now considered fragmented
  -- (change this?)
  insert_rel:_INTERNAL_MarkFragmented()
end

--                  ---------------------------------------                  --
--[[ Delete Processing ; all 4 stages (-launch)                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_CompileDeletes(deletes)
  local ufv = self
  --ufv._deletes = deletes

  local rel = next(deletes)
  ufv._delete_data = {
    relation  = rel,
    n_deleted = EbbGlobal(uint64T, 0)
  }
  -- register global variable
  ufv:_getGlobalId(ufv._delete_data.n_deleted)
end

function UFVersion:_DynamicDeleteChecks()
  if use_legion then error('DELETE unsupported on legion currently', 4) end

  local unsafe_msg = self._delete_data.relation:UnsafeToDelete()
  if unsafe_msg then error(unsafe_msg, 4) end
end

function UFVersion:_bindDeleteData()
  local relsize = tonumber(self._delete_data.relation._logical_size)
  self._delete_data.n_deleted:set(0)
end

function UFVersion:_postprocessDeletions()
  -- WARNING UNSAFE CONVERSION FROM UINT64 TO DOUBLE
  local rel = self._delete_data.relation
  local n_deleted     = tonumber(self._delete_data.n_deleted:get())
  local updated_size  = rel:Size() - n_deleted
  local concrete_size = rel:ConcreteSize()
  rel:_INTERNAL_Resize(concrete_size, updated_size)
  rel:_INTERNAL_MarkFragmented()

  -- if we have too low an occupancy
  if updated_size < 0.5 * concrete_size then
    rel:Defrag()
  end
end






-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ GPU Extensions     (Mainly Global Reductions)                         ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- The following are mainly support routines related to the GPU
-- A lot of them (identified in their names) are
-- strictly related to reductions, and may be used both
-- within the codegen compilation and the compilation of a secondary
-- CUDA Kernel (below)

function UFVersion:_numGPUBlocks(argptr)
  if self:overElasticRelation() then
    local size    = `argptr.bounds[0].hi - argptr.bounds[0].lo + 1
    local nblocks = `[uint64]( C.ceil( [double](size) /
                                       [double](self._blocksize) ))
    return nblocks
  else
    if self:isOverSubset() and self:isIndexSubset() then
      return math.ceil(self._subset._index:Size() / self._blocksize)
    else
      local size = `1
      for d = 1, self._relation:nDims() do
          size = `((size) * (argptr.bounds[d-1].hi - argptr.bounds[d-1].lo + 1))
      end
      return `[uint64](C.ceil( [double](size) / [double](self._blocksize)))
    end
  end
end

function UFVersion:_nBytesSharedMem()
  return self._sharedmem_size or 0
end

function UFVersion:_getBlockSize()
  return self._blocksize
end

function UFVersion:_getTerraReduceGlobalMemPtr(args_sym, global)
  local data = self:_getReduceData(global)
  return `[args_sym].[data.id]
end

function UFVersion:_getTerraReduceSharedMemPtr(global)
  local data = self:_getReduceData(global)

  if self._useTreeReduce then
    return data.sharedmem
  else
    return data.reduceobj:getSharedMemPtr()
  end
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Compilation                                             ]]--
--                  ---------------------------------------                  --

function UFVersion:_CompileGPUReduction()
  self._useTreeReduce = true
  -- NOTE: because GPU memory is idiosyncratic, we need to handle
  --    GPU global memory and
  --    GPU shared memory differently.
  --  Specifically,
  --    * we handle the global memory in the same way we handle
  --      field and global data; by adding an entry into
  --      the argument structure, binding appropriate allocated data, etc.
  --    * we handle the shared memory via a mechanism that looks more
  --      like Terra globals.  As such, these "shared memory pointers"
  --      get inlined directly into the Terra code.  This is safe because
  --      the CUDA kernel launch, not the client CPU code, is responsible
  --      for allocating and deallocating shared memory on function launch/exit

  -- Find all the global variables in this function that are being reduced
  for globl, data in pairs(self._global_reductions) do
    local ttype             = globl._type:terratype()
    if self._useTreeReduce then
      data.sharedmem          = cudalib.sharedmemory(ttype, self._blocksize)
  
      self._sharedmem_size    = self._sharedmem_size +
                                  sizeof(ttype) * self._blocksize
    else
      local op      = data.phase.reduceop
      local lz_type = globl._type
      local reduceobj = G.ReductionObj.New {
        ttype             = ttype,
        blocksize         = self._blocksize,
        reduce_ident      = codesupport.reduction_identity(lz_type, op),
        reduce_binop      = function(lval, rhs)
          return codesupport.reduction_binop(lz_type, op, lval, rhs)
        end,
        gpu_reduce_atomic = function(lval, rhs)
          return codesupport.gpu_atomic_exp(op, lz_type, lval, rhs, lz_type)
        end,
      }
      data.reduceobj = reduceobj
      self._sharedmem_size = self._sharedmem_size + reduceobj:sharedMemSize()
    end
  end

  if self._useTreeReduce then
    self:_CompileGlobalMemReductionKernel()
  end
end

-- The following routine is also used inside the primary compile CUDA kernel
function UFVersion:_GenerateSharedMemInitialization(tid_sym)
  local code = quote end
  for globl, data in pairs(self._global_reductions) do
    local op        = data.phase.reduceop
    local lz_type   = globl._type
    local sharedmem = data.sharedmem

    if self._useTreeReduce then
      code = quote
        [code]
        [sharedmem][tid_sym] = [codesupport.reduction_identity(lz_type, op)]
      end
    else
      code = quote
        [code]
        [data.reduceobj:sharedMemInitCode(tid_sym)]
      end
    end
  end
  return code
end

-- The following routine is also used inside the primary compile CUDA kernel
function UFVersion:_GenerateSharedMemReduceTree(
  args_sym, tid_sym, bid_sym, is_final
)
  is_final = is_final or false
  local code = quote end
  for globl, data in pairs(self._global_reductions) do
    local op          = data.phase.reduceop
    local lz_type     = globl._type
    local sharedmem   = data.sharedmem
    local finalptr    = self:_getTerraGlobalPtr(args_sym, globl)
    local globalmem   = self:_getTerraReduceGlobalMemPtr(args_sym, globl)

    -- Insert an unrolled reduction tree here
    if self._useTreeReduce then
      local step = self._blocksize
      while step > 1 do
        step = step/2
        code = quote
          [code]
          if tid_sym < step then
            var exp = [codesupport.reduction_binop(
                        lz_type, op, `[sharedmem][tid_sym],
                                     `[sharedmem][tid_sym + step])]
            terralib.attrstore(&[sharedmem][tid_sym], exp, {isvolatile=true})
          end
          G.barrier()
        end
      end

      -- Finally, reduce into the actual global value
      code = quote
        [code]
        if [tid_sym] == 0 then
          if is_final then
            @[finalptr] = [codesupport.reduction_binop(lz_type, op,
                                                       `@[finalptr],
                                                       `[sharedmem][0])]
          else
            [globalmem][bid_sym] = [sharedmem][0]
          end
        end
      end
    else
      code = quote
        [code]
        [data.reduceobj:sharedMemReductionCode(tid_sym, finalptr)]
      end
    end
  end
  return code
end

-- The full secondary CUDA kernel to reduce the contents of the
-- global mem array.  See comment inside function for sketch of algorithm
function UFVersion:_CompileGlobalMemReductionKernel()
  local ufv       = self
  local fn_name   = ufv._ufunc._name .. '_globalmem_reduction'

  -- Let N be the number of rows in the original relation
  -- and B be the block size for both the primary and this (the secondary)
  --          cuda kernels
  -- Let M = CEIL(N/B) be the number of blocks launched in the primary
  --          cuda kernel
  -- Then note that there are M entries in the globalmem array that
  --  need to be reduced.  We assume that the primary cuda kernel filled
  --  in a correct value for each of these.
  -- The secondary kernel will launch exactly one block with B threads.
  --  First we'll reduce all of the M entries in the globalmem array in
  --  chunks of B values into a sharedmem buffer.  Then we'll do a local
  --  tree reduction on those B values.
  -- NOTE EDGE CASE: What if M < B?  Then we'll initialize the shared
  --  buffer to an identity value and fail to execute the loop iteration
  --  for the trailing B-M threads of the block.  (This is memory safe)
  --  We will get the correct values b/c reducing identities has no effect.
  local args      = symbol(ufv:_argsType())
  local array_len = symbol(uint64)
  local tid       = symbol(uint32)
  local bid       = symbol(uint32)

  local cuda_kernel =
  terra([array_len], [args])
    var [tid]             = G.thread_id()
    var [bid]             = G.block_id()
    var n_blocks : uint32 = G.num_blocks()
    var gt                = tid + [ufv._blocksize] * bid
    
    -- INITIALIZE the shared memory
    [ufv:_GenerateSharedMemInitialization(tid)]
    
    -- REDUCE the global memory into the provided shared memory
    -- count from (gt) till (array_len) by step sizes of (blocksize)
    for gi = gt, array_len, n_blocks * [ufv._blocksize] do
      escape for globl, data in pairs(ufv._global_reductions) do
        local op          = data.phase.reduceop
        local lz_type     = globl._type
        local sharedmem   = data.sharedmem
        local globalmem   = ufv:_getTerraReduceGlobalMemPtr(args, globl)

        emit quote
          [sharedmem][tid]  = [codesupport.reduction_binop(lz_type, op,
                                                           `[sharedmem][tid],
                                                           `[globalmem][gi])]
        end
      end end
    end

    G.barrier()
  
    -- REDUCE the shared memory using a tree
    [ufv:_GenerateSharedMemReduceTree(args, tid, bid, true)]
  end
  cuda_kernel:setname(fn_name)
  cuda_kernel = G.kernelwrap(cuda_kernel, _INTERNAL_DEV_OUTPUT_PTX)

  -- the globalmem array has an entry for every block in the primary kernel
  local terra launcher( argptr : &(ufv:_argsType()) )
    var globalmem_array_len = [ ufv:_numGPUBlocks(argptr) ]
    var launch_params = terralib.CUDAParams {
      1,1,1, [ufv._blocksize],1,1, [ufv._sharedmem_size], nil
    }
    cuda_kernel(&launch_params, globalmem_array_len, @argptr )
  end
  launcher:setname(fn_name..'_launcher')

  ufv._global_reduction_pass = launcher
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Dynamic Checks                                          ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicGPUReductionChecks()
  if self._proc ~= GPU then
    error("INTERNAL ERROR: Should only try to run GPUReduction on the GPU...")
  end
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Data Binding                                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_generateGPUReductionPreProcess(argptrsym)
  if not self._useTreeReduce then return quote end end
  if not self:UsesGlobalReduce() then return quote end end

  -- allocate GPU global memory for the reduction
  local n_blocks = symbol()
  local code = quote
    var [n_blocks] = [self:_numGPUBlocks(argptrsym)]
  end
  for globl, _ in pairs(self._global_reductions) do
    local ttype = globl._type:terratype()
    local id    = self:_getReduceData(globl).id
    code = quote code
      [argptrsym].[id] = [&ttype](G.malloc(sizeof(ttype) * n_blocks))
    end
  end
  return code
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Postprocessing                                          ]]--
--                  ---------------------------------------                  --

function UFVersion:_generateGPUReductionPostProcess(argptrsym)
  if not self._useTreeReduce then return quote end end
  if not self:UsesGlobalReduce() then return quote end end
  
  -- perform inter-block reduction step (secondary kernel launch)
  local second_pass = self._global_reduction_pass
  local code = quote
    second_pass(argptrsym)
  end

  -- free GPU global memory allocated for the reduction
  for globl, _ in pairs(self._global_reductions) do
    local id    = self:_getReduceData(globl).id
    code = quote code
      G.free( [argptrsym].[id] )
      [argptrsym].[id] = nil -- just to be safe
    end
  end
  return code
end



-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Legion Extensions                                                     ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------




local function pairs_val_sorted(tbl)
  local list = {}
  for k,v in pairs(tbl) do table.insert(list, {k,v}) end
  table.sort(list, function(p1,p2)
    return p1[2] < p2[2]
  end)

  local i = 0
  return function() -- iterator
    i = i+1
    if list[i] == nil then return nil
                      else return list[i][1], list[i][2] end
  end
end



-- Creates a task launcher with task region requirements.
function UFVersion:_CreateLegionTaskLauncher(task_func)
  local prim_reg   = self:_getPrimaryRegionData()
  local prim_partn = prim_reg.partition

  local task_launcher = LW.NewTaskLauncher {
    taskfunc  = task_func,
    gpu       = self:isOnGPU(),
    task_ids  = self._task_ids,
    use_index_launch = use_partitioning,
    domain           = use_partitioning and prim_partn:Domain()
  }

  -- ADD EACH REGION to the launcher as a requirement
  -- WITH THE appropriate permissions set
  -- NOTE: Need to make sure to do this in the right order
  for ri, datum in pairs(self._sorted_region_data) do
    local reg_parent = datum.wrapper
    local reg_partn  = datum.partition
    local reg_req = task_launcher:AddRegionReq(reg_partn,
                                               reg_parent,
                                               datum.privilege,
                                               datum.coherence,
                                               datum.redoptyp)
    assert(reg_req == ri)
  end

  -- ADD EACH FIELD to the launcher as a requirement
  -- as part of the correct, corresponding region
  for field, _ in pairs(self._field_ids) do
    task_launcher:AddField( self:_getRegionData(field).num, field._fid )
  end

  -- ADD EACH GLOBAL to the launcher as a future being passed to the task
  -- NOTE: Need to make sure to do this in the right order
  for globl, gi in pairs_val_sorted(self._future_nums) do
    task_launcher:AddFuture( globl._data )
  end

  return task_launcher
end

-- Launches Legion task and returns.
function UFVersion:_CreateLegionLauncher(task_func)
  local ufv = self
  ufv._task_ids = {}

  -- NOTE: Instead of creating Legion task launcher every time
  -- within the returned function, why not create it once and then reuse the
  -- task launcher?
  if ufv:UsesGlobalReduce() then
    return function(leg_args)
      local task_launcher = ufv:_CreateLegionTaskLauncher(task_func)
      local global  = next(ufv._global_reductions)
      local reduce_data = ufv:_getReduceData(global)
      if LW.reduction_ops[reduce_data.phase:reductionOp()] == nil or
        T.typenames[global:Type()] == nil then
        error('Reduction operation ' .. reduce_data.phase:reductionOp() ..
              ' on '.. tostring(global:Type()) ..
              ' currently unspported with Legion')
      end
      local redoptyp =
        'global_' .. LW.reduction_ops[reduce_data.phase:reductionOp()] ..
        '_' .. T.typenames[global:Type()]
      local future  = task_launcher:Execute(leg_args.runtime, leg_args.ctx, redoptyp)
      if global._data then
        LW.legion_future_destroy(global._data)
      end
      global._data = future
      task_launcher:Destroy()
    end
  else
    return function(leg_args)
      local task_launcher = ufv:_CreateLegionTaskLauncher(task_func)
      task_launcher:Execute(leg_args.runtime, leg_args.ctx)
      task_launcher:Destroy()
    end
  end
end

-- Here we translate the Legion task arguments into our
-- custom argument layout structure.  This allows us to write
-- the body of generated code in a way that's agnostic to whether
-- the code is being executed in a Legion task or not.

function UFVersion:_GenerateUnpackLegionTaskArgs(argsym, task_args)
  local ufv = self

  -- temporary collection of symbols from unpacking the regions
  local region_temporaries = {}

  local code = quote
    do -- close after unpacking the fields
    -- UNPACK REGIONS
    escape for ri, datum in pairs(ufv._sorted_region_data) do
      local reg_dim       = datum.wrapper.dimensions
      local physical_reg  = symbol(LW.legion_physical_region_t)
      local domain        = symbol(LW.legion_domain_t)

      local rect          = reg_dim and symbol(LW.LegionRect[reg_dim]) or nil
      local rectFromDom   = reg_dim and LW.LegionRectFromDom[reg_dim] or nil

      region_temporaries[ri] = {
        physical_reg  = physical_reg,
        reg_dim       = reg_dim,  -- nil for unstructured
        rect          = rect      -- nil for unstructured
      }

      emit quote
        var [physical_reg]  = [task_args].regions[ri]
      end

      -- structured case
      if reg_dim then emit quote
        var index_space     =
          LW.legion_physical_region_get_logical_region(
                                           physical_reg).index_space
        var [domain]        =
          LW.legion_index_space_get_domain([task_args].lg_runtime,
                                           [task_args].lg_ctx,
                                           index_space)
        var [rect]          = rectFromDom([domain])
      end end
    end end

    -- UNPACK FIELDS
    escape for field, farg_name in pairs(ufv._field_ids) do
      local rtemp         = region_temporaries[ufv:_getRegionData(field).num]
      local physical_reg  = rtemp.physical_reg
      local reg_dim       = rtemp.reg_dim
      local rect          = rtemp.rect

      -- structured
      if reg_dim then emit quote
        var field_accessor =
          LW.legion_physical_region_get_accessor_generic(physical_reg)
        var subrect : LW.LegionRect[reg_dim]
        var strides : LW.legion_byte_offset_t[reg_dim]
        var base = [&uint8](
          [ LW.LegionRawPtrFromAcc[reg_dim] ](
                              field_accessor, rect, &subrect, strides))
        var offset : int = 0
        for d = 0, reg_dim do
          offset = offset + [rect].lo.x[d] * strides[d].offset 
        end
        -- C.printf("Pointer %p, rect %i, %i, %i, %i, offset %i\n", base, [rect].lo.x[0], [rect].lo.x[1],
        --   [rect].hi.x[0], [rect].hi.x[1], offset)
        base = base - offset
        [argsym].[farg_name] = [ LW.FieldAccessor[reg_dim] ] { base, strides, field_accessor }
      end
      -- unstructured
      else emit quote
        var field_accessor =
          LW.legion_physical_region_get_accessor_generic(physical_reg)
        var base : &opaque = nil
        var stride_val : C.size_t = 0
        var ok = LW.legion_accessor_generic_get_soa_parameters(
          field_accessor, &base, &stride_val)
        var strides : LW.legion_byte_offset_t[1]
        strides[0].offset = (stride_val)
        [argsym].[farg_name] = [ LW.FieldAccessor[1] ] { [&uint8](base), strides, field_accessor }
      end end
    end end

    -- UNPACK PRIMARY REGION BOUNDS RECTANGLE FOR STRUCTURED
    -- FOR UNSTRUCTURED, CORRECT INITIALIZATION IS POSPONED TO LATER
    -- FOR UNSRRUCTURED, BOUNDS INITIALIZED TO TOTAL ROWS HERE
    escape
      local ri    = ufv:_getPrimaryRegionData().num
      local rect  = region_temporaries[ri].rect
      -- structured
      if rect then
        local ndims = region_temporaries[ri].reg_dim
        for i=1,ndims do emit quote
          [argsym].bounds[i-1].lo = rect.lo.x[i-1]
          [argsym].bounds[i-1].hi = rect.hi.x[i-1]
        end end
      -- unstructured
      else emit quote
        -- initialize to total relation rows here, which would work without
        -- partitions
        [argsym].bounds[0].lo = 0
        [argsym].bounds[0].hi = [ufv:_getPrimaryRegionData().wrapper.live_rows] - 1 -- bound is 1 off: the actual highest index value
      end end
    end
    
    end -- closing do started before unpacking the regions

    -- UNPACK FUTURES
    -- DO NOT WRAP THIS IN A LOCAL SCOPE or IN A DO BLOCK (SEE BELOW)
    escape for globl, garg_name in pairs(ufv._global_ids) do
      -- position in the Legion task arguments
      local fut_i   = ufv:_getFutureNum(globl) 
      local gtyp    = globl._type:terratype()
      local gptr    = ufv:_getLegionGlobalTempSymbol(globl)

      if ufv:isOnGPU() then
        emit quote
          -- TODO: check if this global is being reduced and if it is first
          -- partition. if yes, initialize datum to identity.
          var fut     = LW.legion_task_get_future([task_args].task, fut_i)
          var result  = LW.legion_future_get_result(fut)
          var datum   = @[&gtyp](result.value)
          var [gptr]  = [&gtyp](G.malloc(sizeof(gtyp)))
          G.memcpy_gpu_from_cpu(gptr, &datum, sizeof(gtyp))
          --var [gptr] = &datum

          [argsym].[garg_name] = gptr
          LW.legion_task_result_destroy(result)
        end
      else
        emit quote
          -- TODO: check if this global is being reduced and if it is first
          -- partition. if yes, initialize datum to identity.
          var fut     = LW.legion_task_get_future([task_args].task, fut_i)
          var result  = LW.legion_future_get_result(fut)
          var datum   = @[&gtyp](result.value)
          var [gptr]  = &datum
          -- note that we're going to rely on this variable
          -- being stably allocated on the stack
          -- for the remainder of this function scope
          [argsym].[garg_name] = gptr
          LW.legion_task_result_destroy(result)
        end
      end
    end end
  end -- end quote

  return code
end

function UFVersion:_CleanLegionTask(argsym)
  local ufv = self

  local stmts = {}
  for field, farg_name in pairs(ufv._field_ids) do
    table.insert(stmts, quote
      LW.legion_accessor_generic_destroy([argsym].[farg_name].handle)
    end)
  end  -- escape
  return stmts
end

function UFVersion:_CompileLegion(typed_ast)
  local task_function     = codegen.codegen(typed_ast, self)
  self._executable        = self:_CreateLegionLauncher(task_function)
end


--                  ---------------------------------------                  --
--[[ Legion Dynamic Checks                                                 ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicLegionChecks()
end

--                  ---------------------------------------                  --
--[[ Legion Data Binding                                                   ]]--
--                  ---------------------------------------                  --

function UFVersion:_bindLegionData()
  -- meh
end

--                  ---------------------------------------                  --
--[[ Legion Postprocessing                                                 ]]--
--                  ---------------------------------------                  --

function UFVersion:_postprocessLegion()
  -- meh for now
end










-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ ArgLayout                                                             ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


function ArgLayout.New()
  return setmetatable({
    fields            = terralib.newlist(),
    globals           = terralib.newlist(),
    reduce            = terralib.newlist()
  }, ArgLayout)
end

function ArgLayout:setRelation(rel)
  self._key_type  = keyT(rel):terratype()
  self.n_dims     = #rel:Dims()
end

function ArgLayout:addField(name, field)
  if self:isCompiled() then
    error('INTERNAL ERROR: cannot add new fields to compiled layout')
  end
  if use_single then
    local typ = field:Type():terratype()
    table.insert(self.fields, { field=name, type=&typ })
  elseif use_legion then
    local ndims = #field:Relation():Dims()
    table.insert(self.fields, { field=name, type=LW.FieldAccessor[ndims] })
  end
end

function ArgLayout:addGlobal(name, global)
  if self:isCompiled() then
    error('INTERNAL ERROR: cannot add new globals to compiled layout')
  end
  local typ = global._type:terratype()
  table.insert(self.globals, { field=name, type=&typ })
end

function ArgLayout:addReduce(name, typ)
  if self:isCompiled() then
    error('INTERNAL ERROR: cannot add new reductions to compiled layout')
  end
  table.insert(self.reduce, { field=name, type=&typ})
end

function ArgLayout:turnSubsetOn()
  if self:isCompiled() then
    error('INTERNAL ERROR: cannot add a subset to compiled layout')
  end
  self.subset_on = true
end

function ArgLayout:addInsertion()
  if self:isCompiled() then
    error('INTERNAL ERROR: cannot add insertions to compiled layout')
  end
  self.insert_on = true
end

function ArgLayout:TerraStruct()
  if not self:isCompiled() then self:Compile() end
  return self.terrastruct
end

local struct bounds_struct { lo : uint64, hi : uint64 }

function ArgLayout:Compile()
  local terrastruct = terralib.types.newstruct(self.name)

  -- add counter
  table.insert(terrastruct.entries,
               {field='bounds', type=(bounds_struct[self.n_dims])})
  -- add subset data
  local taddr = self._key_type
  if self.subset_on then
    table.insert(terrastruct.entries, {field='index',        type=&taddr})
    table.insert(terrastruct.entries, {field='index_size',   type=uint64})
  end
  --if self.insert_on then
  --end
  -- add fields
  for _,v in ipairs(self.fields) do table.insert(terrastruct.entries, v) end
  -- add globals
  for _,v in ipairs(self.globals) do table.insert(terrastruct.entries, v) end
  -- add global reduction space
  for _,v in ipairs(self.reduce) do table.insert(terrastruct.entries, v) end

  self.terrastruct = terrastruct
end

function ArgLayout:isCompiled()
  return self.terrastruct ~= nil
end


-------------------------------------------------------------------------------
--[[  UFVersion Interface for Partitions                                   ]]--
--[[  Should run only when running over partitioned data in Legion         ]]--
-------------------------------------------------------------------------------

-- NOTE: partitions include boundary regions. Partitioning is not subset
-- specific right now, but it is a partitioning over the entire logical region.

function UFVersion:_addPrimaryPartition()
  local prim_rel = self._relation
  local sig = tostring(prim_rel:_INTERNAL_UID())
  local datum = self._region_data[sig]
  if not datum.partition then
    -- once partitioning works, change this to single partition and remove the
    -- branch
    local prim_partn = datum.wrapper
    if use_partitioning then
      -- set number of partitions on the relation to number of cpus
      if not prim_rel:IsPartitioningSet() then
        prim_rel:SetPartitions(run_config.num_partitions)
      end
      -- create a disjoint partition on the relation
      prim_partn = prim_rel:GetOrCreateDisjointPartitioning()
    end
    datum.partition = prim_partn
  end
end

function UFVersion:_addRegionPartition(field, boolmask)
  local rel = field:Relation()
  local sig = tostring(rel:_INTERNAL_UID()) .. '_' .. tostring(field._fid)
  local datum = self._region_data[sig]
  if not datum.partition then
    -- Grid ghost partitions are made using specified ghost width. Stencil
    -- analysis (to automatically determine ghost partitions) to come yet.
    -- If we are not using partitions over a region, we use logical region instead
    -- of logical partition in region requirement (hack around stencil
    -- analysis) for non-centered. Once we have stencil analysis in
    -- place, we should instead pass the partition that includes halo, instead
    -- of the logical region wrapper.
    -- Once stencil analysis works, we can also remove 'use_partitioning' from
    -- the condition clauses, and treat non-partitioned cases as 1 partition.
    local prim_partn = datum.wrapper
    -- remove branches once partitions and stencil analysis are correctly set up for all cases
    if use_partitioning then
      -- The three cases are read only, centered (read/ write) and reduce.
      -- Read is handle by above initialization.
      if boolmask or self._field_use[field]:isCentered() then
        assert(rel == self._relation)
        prim_partn = rel:GetOrCreateDisjointPartitioning()
      -- (not is centered) and (requires exclusive) is a phase error
      -- Grid ghost partitions using specified ghost width
      elseif rel:isGrid() and rel:IsGhostWidthValid() then
        prim_partn = rel:GetOrCreateGhostPartitioning()
      end
    end
    datum.partition = prim_partn
  end
end
