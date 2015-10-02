import "ebb"

local test = require('tests.test')

local ioOff = require 'ebb.domains.ioOff'
local mesh  = ioOff.LoadTrimesh('tests/octa.off')

mesh.vertices:NewField('field', L.float)
mesh.vertices.field:Load(1)
local count = L.Global(L.float, 0)

local test_for = ebb (v : mesh.vertices)
	for e in v.edges do
	  count += 1
	end
end

mesh.vertices:foreach(test_for)

test.eq(count:get(), 24)
