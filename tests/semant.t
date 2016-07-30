--DISABLE-DISTRIBUTED
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
import 'ebb'
local L = require 'ebblib'
require "tests/test"

local lassert, lprint = L.assert, L.print


---------------------------
-- Field and Global objs --
---------------------------
local R = L.NewRelation { name="R", size=6 }
R:NewField('f1', L.float)
R:NewField('f2', L.vector(L.float, 3))
s1 = L.Global(L.int, 0)

-- used to check nominal constraints on relation types
local otherR = L.NewRelation { name="otherR", size=6 }
otherR:NewField('f1', L.float)
otherR:NewField('f2', L.vector(L.float, 3))


------------------------
-- Initialize fields: --
------------------------
R.f1:Load(0)
R.f2:Load({0,0,0})

otherR.f1:Load(0)
otherR.f2:Load({0,0,0})


---------------------
-- Global lua vars --
---------------------
checkthis1 = 1
local checkthis2 = 2

local a = {}
a.b     = {}
a.b.c   = {}
a.b.c.d = 4

-------------------------------
-- ...let the testing begin! --
-------------------------------
-- Should fail b/c checkthis1 is not a global
test.fail_function(function()
 	local ebb t(cell : R)
		checkthis1 = cell.f1
	end
	R:foreach(t)
end, "Illegal assignment: left hand side cannot be assigned")

-- Should fail when we re-assign a new value to x, since it originally
-- refers to a topological element
test.fail_function(function()
	local ebb t(cell : R)
		var x = cell
  	  	x = cell
	end
	R:foreach(t)
end, "Illegal assignment: variables of key type cannot be re%-assigned")

-- Should fail because we do not allow assignments to fields
-- (only to indexed fields, globals, and local vars)
test.fail_function(function()
	local fail3 = ebb(cell : R)
		R.f1 = 5
	end
	R:foreach(fail3)
end, "Illegal assignment: left hand side cannot be assigned")

-- Should fail because we do not allow the user to alias fields,
-- or any other entity that would confuse stencil generation, in the function
test.fail_function(function()
	local ebb t(cell : R)
		var z = R.f1
	end
	R:foreach(t)
end, "can only assign")

test.fail_function(function()
 	local ebb t(cell : R)
		undefined = 3
	end
	R:foreach(t)
end, "variable 'undefined' is not defined")

-- Can't assign a value of a different type to a variable that has already
-- been initialized
test.fail_function(function()
	local ebb t(cell : R)
		var floatvar = 2 + 3.3
		floatvar = true
	end
	R:foreach(t)
end, "Could not coerce expression of type 'bool' into type 'double'")

-- local8 is not in scope in the while loop
test.fail_function(function()
	local ebb t(cell : R)
		var local7 = 2.0
		do
			var local8 = 2
		end

		var cond = true
		while cond ~= cond do
			local8 = 3
			local7 = 4.5
		end
	end
	R:foreach(t)
end, "variable 'local8' is not defined")

test.fail_function(function()
	local ebb t(cell : R)
		if 4 < 2 then
			var local8 = true
		-- Should fail here, since local8 is not defined in this scope
		elseif local8 then
			var local9 = true
		elseif 4 < 3 then
			var local9 = 2
		else
			var local10 = local7
		end
	end
	R:foreach(t)
end, "variable 'local8' is not defined")

test.fail_function(function()
	local ebb t(cell : R)
		var local1 = 3.4
		do
			var local1 = true
			local1 = 2.0 -- should fail, local1 is of type bool
		end
	end
	R:foreach(t)
end, "Could not coerce expression of type 'double' into type 'bool'")

test.fail_function(function()
	local ebb t(cell : R)
		lassert(4 == true) -- binary op will fail here, type mismatch
	end
	R:foreach(t)
end, "incompatible types: int and bool")

local v = L.Constant(L.vec3f, {1, 1, 1})
test.fail_function(function()
	local ebb t(cell : R)
		lassert(v) -- assert fail, comparison returns a vector of bools
	end
	R:foreach(t)
end, "expected a boolean")

test.fail_function(function()
	local ebb t(cell : R)
		a.b = 12
	end
	R:foreach(t)
end, "Illegal assignment: left hand side cannot be assigned")

test.fail_function(function()
	local ebb t(cell : R)
		var v : L.bool
		if false then
			v = true
		end
		v = 5
	end
	R:foreach(t)
end, "Could not coerce expression of type 'int' into type 'bool'")

local tbl = {}
test.fail_function(function()
	local ebb t(cell : R)
		var x = 3 + tbl
	end
	R:foreach(t)
end, "invalid types")

test.fail_function(function()
	local ebb t(cell : R)
		var x = tbl
	end
	R:foreach(t)
end, "can only assign")

test.fail_function(function()
	local ebb t(cell : R)
		tbl.x = 4
	end
	R:foreach(t)
end, "lua table does not have member 'x'")

local tbl = {x={}}
test.fail_function(function()
	local ebb t(cell : R)
		tbl.x.y = 4
	end
	R:foreach(t)
end, "lua table does not have member 'y'")

tbl.x.z = 4
test.fail_function(function()
	local ebb t(cell : R)
		var x = tbl.x
	end
	R:foreach(t)
end, "can only assign")

test.fail_function(function()
	local ebb t(cell : R)
		for i = 1, 4, 1 do
			var x = 3
		end
		var g = i
	end
	R:foreach(t)
end, "variable 'i' is not defined")


test.fail_function(function()
	local ebb badrel( cell : R )
		cell.f1 = 2
	end
	otherR:foreach(badrel) -- should complain
end, "The supplied relation did not match the parameter annotation")

-- Nothing should fail in this function:
local good = ebb (cell : R)
    cell.f1 = 3
    var lc = 4.0

	var local1 = a.b.c.d
	var local2 = 2.0
	var local3 = local1 + local2
	var local5 = 2 + 3.3
	var local4 = checkthis1 + checkthis2
	var local7 = 8 <= 9

	3 + 4

	do
		var local1 = true
	end
	local1 = 3
	var local1 = false

	var local9 = 0
	for i = 1, 4, 1 do
		local9 += i * i
	end
	lassert(local9 == 14)
end
R:foreach(good)
