import "ebb"
local L = require "ebblib" -- Every Ebb File should start with this command

-- Single line comments in Lua look like this

--[[

Multi
line
comments
look
like
this
!

]]--


-- PN (Pathname) is a convenience library for working with paths
local PN = require 'ebb.lib.pathname'

-- here's the path object for our .OFF file we want to read in.
-- Notice that the path is relative to this script's location on
-- disk rather than the present working directory, which varies
-- depending on where we invoke this script from.
local tri_mesh_filename = PN.scriptdir() .. 'bunny.off'

-- OFF files have the following format
--
--[[
OFF
#vertices #triangles 0
x0 y0 z0
  ...
  ...   #vertices rows of coordinate triples
  ...
3 vertex_1 vertex_2 vertex_3
  ...
  ...   #triangles rows of vertex index triples
  ...
]]--

-- In Lua, we can open files just like in C
local off_in = io.open(tostring(tri_mesh_filename), "r")
if not off_in then
  error('failed to open '..tostring(tri_mesh_filename))
end

-- we can read a line like so
local OFF_SIG = off_in:read('*line')

if OFF_SIG ~= 'OFF' then
  error('OFF file must begin with the first line "OFF"')
end

-- read the counts of vertices and triangles
local n_verts = off_in:read('*number')
local n_tris  = off_in:read('*number')
local zero    = off_in:read('*number')

-- now read in all the vertex coordinate data
-- set up an empty array/table
local position_data_array = {}
for i = 1, n_verts do
  local vec = {
    off_in:read('*number'),
    off_in:read('*number'),
    off_in:read('*number')
  }
  position_data_array[i] = vec
end

-- Then read in all the vertex index arrays
local v1_data_array = {}
local v2_data_array = {}
local v3_data_array = {}
for i = 1, n_tris do
  local three   = off_in:read('*number')
  if three ~= 3 then
    error('tried to read a triangle with '..three..' vertices')
  end
  v1_data_array[i] = off_in:read('*number')
  v2_data_array[i] = off_in:read('*number')
  v3_data_array[i] = off_in:read('*number')
end

-- don't forget to close the file when done
off_in:close()



------------------------------------------------------------------------------

-- Now We want to construct the Ebb relations

local triangles = L.NewRelation { size = n_tris, name = 'triangles' }
local vertices  = L.NewRelation { size = n_verts, name = 'vertices' }

-- The size parameter to the L.NewRelation call tells it how
-- many rows we'd like the relation to have.

-- The name parameter to the L.NewRelation call tells it what
-- name we're going to refer to the relation with.

------------------------------------------------------------------------------

-- Once we've constructed the relations, we can define
-- Fields over them.

vertices:NewField('pos', L.vector(L.double, 3))

-- The preceding line defines a new field over the vertices,
-- named 'pos'.  It stores vectors of 3 doubles each.
-- We can load the position data we read from the files into
-- this field.

vertices.pos:Load(position_data_array)


triangles:NewField('v1', L.row(vertices))
triangles:NewField('v2', vertices)
triangles:NewField('v3', vertices)

-- Now we've defined 3 new fields on the triangles, each of which
-- refers to one of the three vertices for a triangle.
-- We've explicitly typed the first field 'v1' with the type
--    L.row(vertices)
-- A Row type is similar to a pointer.  It means that field 'v1' refers
-- to a row from the relation 'vertices'.  As a shorthand, if you
-- type a field using a relation, then the type is automatically
-- inferred to be a Row type.  (We did this for 'v2' and 'v3')

triangles.v1:Load(v1_data_array)
triangles.v2:Load(v2_data_array)
triangles.v3:Load(v3_data_array)

-- Row data can be loaded just like the position data.
-- Let's look at the first call to load Field 'v1'.
-- 
-- 'v1_data_array' should be an array of length triangles:Size()
-- Each entry of 'v1_data_array' should be an integer identifying
-- some row of the 'vertices' relation to refer to.  So these integers
-- should be at least 0 and less than (vertices:Size() - 1).

-- WARNING: If you try to load Row fields with new data after the simulation
--    begins, you may get undefined behavior.  Ebb reserves the right
--    to arbitrarily re-order the rows during execution.  This may happen
--    to improve data access patterns, due to the creation or destruction
--    of data, or any other number of contingencies!

------------------------------------------------------------------------------

-- Having defined and loaded all of the data from file, we can now
-- go ahead and define the simulation specific Fields.

-- define a temperature field.  Initialize it using a callback.
-- The callback is written in Lua.
vertices:NewField('temperature', L.double)
vertices.temperature:Load(function(index)
  if index == 0 then return 3000.0 else return 0.0 end
end)

-- define a triangle area field.  Initialize it to '0'.
-- We'll compute the triangle areas soon!
triangles:NewField('area', L.double)
triangles.area:Load(0)

-- It'll also be useful for us to know how many triangles touch
-- each vertex later.  So let's record that too.
vertices:NewField('nTriangles', L.int)
vertices.nTriangles:Load(0)

------------------------------------------------------------------------------

-- In addition to Fields, we can also define Globals.
-- An Ebb Global is a kind of "global" variable that's useful for
-- controlling time-step behavior or computing simple summary statistics
-- Unlike Fields, which have a different value for each entry/row in the
-- relation, Globals have exactly one value visible to all rows.

local timestep = L.Global(L.double, 1.0)
-- The preceding line set up a Global named timestep of type L.double
-- and gave it initial value 1.0

timestep:set(0.45)
-- Then this line set the value using the method :set(...)

print( 'the timestep is ' .. tostring(timestep:get()) )
-- We can retreive the value of a global with the :get() method

-- NOTE: Globals have to be explicitly written and read from Lua code.

local avg_temp_change = L.Global(L.double, 0.0)
-- We'll use this second global to measure the average change in
-- temperature as we run our simulation.

------------------------------------------------------------------------------

-- Before we launch into the full computation, we'll take a second
-- here to compute the triangles' areas.  We can do this in Ebb.
-- Let's see how...

-- This first line declares that we're defining a new Ebb function.
--  (You can think of this function as the body of a parallel-for loop!)
local ebb compute_tri_area ( t : triangles )
-- We specify that the function will be mapped over rows from the 'triangles'
-- relation, and that we'll refer to rows using the variable name 't'.

  -- First, we'll go ahead and name the 3 vertices' position vectors
  var p1 : L.vector(L.double, 3) = t.v1.pos
  var p2 = t.v2.pos
  var p3 = t.v3.pos
  -- The first line declares a new variable 'p1' with type
  --    L.vector(L.double, 3)
  -- Then, we initialize it to value t.v1.pos,
  -- the position of the first vertex of triangle t
  -- We omit the explicit type from the following two declarations b/c
  -- it can be inferred automatically.

  -- Now, we'll go ahead and use a standard formula for the computation of
  -- triangle area
  var normal = L.cross((p2 - p1), (p3 - p1))
  var area   = 0.5 * L.length(normal)

  -- Finally, we'll store the result into the 'area' field on the triangle
  t.area = area

end

-- Once we've defined a function, then we can map it over the relation
-- it was designed for.  Here, that's triangles
triangles:map(compute_tri_area)

-- Now triangles.area has the values we want computed for it.

-- We can compute the number of triangles touching each vertex
-- using another function
local ebb compute_n_triangles ( t : triangles )
  t.v1.nTriangles += 1
  t.v2.nTriangles += 1
  t.v3.nTriangles += 1
end

triangles:map(compute_n_triangles)

------------------------------------------------------------------------------

-- We're going to simulate a heat diffusion on the triangle-mesh
-- So, let's go ahead and define a conduction constant
local conduction = L.Constant(L.double, 1.0)

-- Note that we didn't define conduction as a Global.  As a result, it will
-- be compiled into the Ebb function.  If we later change the value of
-- conduction, by assigning a different constant to the name 'conduction'
-- it will have no effect.  If we wanted to change the conduction over
-- the course of the simulation, then we should have created a Global.


-- In order to get access to trigonometric functions and other C code,
-- we include the C file like this
local cmath = terralib.includecstring [[
#include <math.h>
]]
-- notice the double square brackets.  In Lua, double square brackets
-- are used to write a multi-line string.



-- Let's first look at one way we could try writing heat diffusion
-- as a single Ebb function.  It turns out it will produce compiler
-- errors if we try to execute it.
-- ( TRY IT OUT!  Just uncomment the code below, and you should
--        get a compiler error when you try to execute this file. )

--[[
local ebb temp_update_fail ( t : triangles )
  -- We should compute edge coefficients to account for different
  -- geometries, but for simplicity right now, we'll just give
  -- each edge weight 1
  var e12coeff : L.double = 1.0
  var e23coeff : L.double = 1.0
  var e13coeff : L.double = 1.0

  -- get initial temperature values
  var temp1 = t.v1.temperature
  var temp2 = t.v2.temperature
  var temp3 = t.v3.temperature

  -- compute the changes in temperature at each vertex due to
  -- its neighbors in this triangle
  var d_temp_1 = (timestep * conduction / t.v1.nTriangles) *
                  ( e12coeff * (temp2 - temp1) +
                    e13coeff * (temp3 - temp1) )
  var d_temp_2 = (timestep * conduction / t.v2.nTriangles) *
                  ( e12coeff * (temp1 - temp2) +
                    e23coeff * (temp3 - temp2) )
  var d_temp_3 = (timestep * conduction / t.v3.nTriangles) *
                  ( e13coeff * (temp1 - temp3) +
                    e23coeff * (temp2 - temp3) )

  -- apply the changes to the temperature field:
  t.v1.temperature += d_temp_1
  t.v2.temperature += d_temp_2
  t.v3.temperature += d_temp_3
end
]]--

-- Why won't the code above work?

-- Remember when we said you can think of an Ebb function as the body of a
-- parallel-for loop?  Suppose we looped over the triangles in two different
-- ways: front-to-back and back-to-front.  Would the result of the loop be
-- the same?  No, because each loop iteration both READs from the
-- vertices.temperature Field and WRITEs to the vertices.temperature field
-- (via the += operator).

-- We can avoid this problem by storing intermediate results into
-- a "temporary" field.  Then once these temporaries have all been
-- computed, we can map a second function to update the original field

-- We'll define a d_temperature (change in temperature) field 
vertices:NewField('d_temperature', L.double)
vertices.d_temperature:Load(0.0)

-- Ok, this is mostly the same as above, except we're writing the
-- resutls to a temporary field
local ebb compute_diffusion ( t : triangles )
  -- We should compute edge coefficients to account for different
  -- geometries, but for simplicity right now, we'll just give
  -- each edge weight 1
  var e12coeff : L.double = 1.0
  var e23coeff : L.double = 1.0
  var e13coeff : L.double = 1.0

  -- get initial temperature values
  var temp1 = t.v1.temperature
  var temp2 = t.v2.temperature
  var temp3 = t.v3.temperature

  -- compute the changes in temperature at each vertex due to
  -- its neighbors in this triangle
  var d_temp_1 = (timestep * conduction / t.v1.nTriangles) *
                  ( e12coeff * (temp2 - temp1) +
                    e13coeff * (temp3 - temp1) )
  var d_temp_2 = (timestep * conduction / t.v2.nTriangles) *
                  ( e12coeff * (temp1 - temp2) +
                    e23coeff * (temp3 - temp2) )
  var d_temp_3 = (timestep * conduction / t.v3.nTriangles) *
                  ( e13coeff * (temp1 - temp3) +
                    e23coeff * (temp2 - temp3) )

  -- apply the changes to the temperature field:
  t.v1.d_temperature += d_temp_1
  t.v2.d_temperature += d_temp_2
  t.v3.d_temperature += d_temp_3
end

-- Now, we can actually apply the change
local ebb apply_diffusion ( v : vertices )
  var d_temp = v.d_temperature
  -- adjust the temperature by the computed change
  v.temperature += d_temp

  -- Also aggregate a summary statistic about how much the temperature
  -- changed in this iteration
  avg_temp_change += cmath.fabs(d_temp)
  -- notice that we've called a C function to compute the absolute value!
end

-- And we can clear out the temporary field once we've applied the change
local ebb clear_temporary ( v : vertices )
  v.d_temperature = 0.0
end

-- EXTRA: (This is optional.  It demonstrates the use of VDB,
--         a visual debugger)
local vdb = require('ebb.lib.vdb')
-- The idea here is that we're going to draw all of the triangles
-- in the mesh with a color proportional to their current
-- temperature.  When we view this data in VDB, we'll see the
-- heat diffusing across the surface of the bunny model.
local cold = L.Constant(L.vec3f,{0.5,0.5,0.5})
local hot  = L.Constant(L.vec3f,{1.0,0.0,0.0})
local ebb debug_tri_draw ( t : triangles )
  -- color a triangle with the average temperature of its vertices
  var avg_temp =
    (t.v1.temperature + t.v2.temperature + t.v3.temperature) / 3.0

  -- compute a display value in the range 0.0 to 1.0 from the temperature
  var scale = L.float(cmath.log(1.0 + avg_temp))
  if scale > 1.0 then scale = 1.0 end

  -- interpolate the hot and cold colors
  vdb.color((1.0-scale)*cold + scale*hot)
  -- and draw the triangle
  vdb.triangle(t.v1.pos, t.v2.pos, t.v3.pos)
end
-- END EXTRA VDB CODE

-- Finally, we can execute these three functions one after another in
-- a simulation loop as long as we wish.

for i = 1,300 do
  triangles:map(compute_diffusion)
  verticles:map(apply_diffusion)
  verticles:map(clear_temporary)

  -- EXTRA: VDB
  -- the vbegin/vend calls batch the rendering calls to prevent flickering
  vdb.vbegin()
    vdb.frame() -- this call clears the canvas for a new frame
    triangles:map(debug_tri_draw)
  vdb.vend()
  -- END EXTRA
end


------------------------------------------------------------------------------

-- We can also dump data out of the relational storage.
-- BEWARE: Ebb may re-order your data however it chooses.
-- This means that you need to dump out everything, not just
-- a single field.

-- EXAMPLE:
-- the vertices may not be in the same order, so if we dumped out
-- the temperature field and then read in the original OFF file along
-- with the dumped temperatures in another program, there's no guarantee
-- that the temperatures will be associated with the correct vertices.
-- To avoid this problem, we should dump out all of the fields and
-- construct a new version of the OFF file.


-- Dump({}) is the inverse of the way we loaded the OFF file data
local positions     = vertices.pos:Dump({})
local temperatures  = vertices.temperature:Dump({})

-- Let's open up a file to dump this temperature data to.
local output_temp_file = PN.scriptdir() ..
                         'simple_trimesh_diffusion_output/' ..
                         'result_temps.txt'
local out = io.open(tostring(output_temp_file), "w")

-- Let's just dump this output to a pretty useless output format
-- to demonstrate.
-- Notice that we've saved the position coordinates for the vertices too.
-- This ensures that we can align this temperature data with the original
-- mesh, even if the vertices got re-ordered.
for i = 1, #positions do
  local p = positions[i]
  out:write(string.format('%-8d%-16f%-16f%-16f\n', i, p[1], p[2], p[3]))
  out:write(string.format('        %-16f\n', temperatures[i]))
end

-- don't forget to close the file when done
out:close()




