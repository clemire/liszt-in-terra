local B = {}
package.loaded["compiler.builtins"] = B

local L = require "compiler.lisztlib"
local T = require "compiler.types"
local C = require "compiler.c"
local G = require "compiler.gpu_util"
local AST = require "compiler.ast"

---------------------------------------------
--[[ Builtin functions                   ]]--
---------------------------------------------
local Builtin = {}
Builtin.__index = Builtin
Builtin.__call = function(self,...)
    return self.luafunc(...)
end

function Builtin.new(luafunc)
    local check = function(ast, ctxt)
        error('unimplemented builtin function typechecking')
    end
    local codegen = function(ast, ctxt)
        error('unimplemented builtin function codegen')
    end
    return setmetatable({check=check, codegen=codegen, luafunc = luafunc},
                        Builtin)
end
function B.isBuiltin(f)
    return getmetatable(f) == Builtin
end


-- internal macro style built-in
B.Where = Builtin.new(function ()
                        error("Where cannot be called in Lua code") end)
function B.Where.check(call_ast, ctxt)
    if #(call_ast.params) ~= 2 then
        ctxt:error(ast, "Where expects exactly 2 arguments")
        return L.error
    end

    local w = AST.Where:DeriveFrom(call_ast)
    w.field = call_ast.params[1]
    w.key   = call_ast.params[2]
    return w:check(ctxt)
end


local id = function () error("id expects a relation row") end
B.id = Builtin.new(id)

function B.id.check(ast, ctxt)
    local args = ast.params
    if #args ~= 1 then 
        ctxt:error(ast, "id expects exactly 1 argument (instead got " .. tostring(#args) .. ")")
        return L.error
    end

    if not args[1].node_type:isScalarRow() then
        ctxt:error(ast, "expected a relational row as the argument for id()")
        return L.error
    end

    return L.addr
end

function B.id.codegen(ast, ctxt)
    return ast.params[1]:codegen(ctxt)
end


local UNSAFE_ROW = function()
    error('UNSAFE_ROW cannot be called in Lua code') end
B.UNSAFE_ROW = Builtin.new(UNSAFE_ROW)

function B.UNSAFE_ROW.check(ast, ctxt)
    local args = ast.params
    if #args ~= 2 then
        ctxt:error(ast, "UNSAFE_ROW expects exactly 2 arguments "..
                        "(instead got " .. #args .. ")")
        return
    end

    local ret_type = nil

    local addr_type = args[1].node_type
    local rel_type = args[2].node_type
    if addr_type ~= L.addr then
        ctxt:error(ast, "UNSAFE_ROW expected an address as the first arg")
        ret_type = L.error
    end
    if not rel_type:isInternal() or not L.is_relation(rel_type.value) then
        ctxt:error(ast, "UNSAFE_ROW expected a relation as the second arg")
        ret_type = L.error
    end

    -- actual typing
    if not ret_type then
        ret_type = L.row(rel_type.value)
    end

    return ret_type
end
function B.UNSAFE_ROW.codegen(ast, ctxt)
    return ast.params[1]:codegen(ctxt)
end


B.assert = Builtin.new(assert)

function B.assert.check(ast, ctxt)
    local args = ast.params
    if #args ~= 1 then
        ctxt:error(ast, "assert expects exactly 1 argument (instead got " .. #args .. ")")
        return
    end

    local test = args[1]
    local test_type = test.node_type
    if test_type:isVector() then test_type = test_type:baseType() end
    if test_type ~= L.error and test_type ~= L.bool then
        ctxt:error(ast, "expected a boolean or vector of booleans as the test for assert statement")
    end
end

local terra lisztAssert(test : bool, file : rawstring, line : int)
    if not test then
        C.fprintf(C.get_stderr(), "%s:%d: assertion failed!\n", file, line)
        assert(false)
    end
end

-- NADA FOR NOW
local terra gpuAssert(test : bool, file : rawstring, line : int) end

function B.assert.codegen(ast, ctxt)
    local test = ast.params[1]
    local code = test:codegen(ctxt)
    
    local tassert = lisztAssert
    if ctxt:onGPU() then tassert = gpuAssert end

    if test.node_type:isVector() then
        local N      = test.node_type.N
        local vec    = symbol(test.node_type:terraType())

        local all    = `true
        for i = 0, N-1 do
            all = `all and vec.d[i]
        end

        return quote
            var [vec] = [code]
        in
            tassert(all, ast.filename, ast.linenumber)
        end
    else
        return quote tassert(code, ast.filename, ast.linenumber) end
    end
end

B.print = Builtin.new(print)

function B.print.check(ast, ctxt)
    local args = ast.params
    
    for i,output in ipairs(args) do
        local outtype = output.node_type
        if outtype ~= L.error and
           not outtype:isValueType() and not outtype:isRow()
        then
            ctxt:error(ast, "only numbers, bools, vectors, matrices and rows can be printed")
        end
    end
end

local function printSingle (bt, exp, elemQuotes)
    if bt == L.float or bt == L.double then
        table.insert(elemQuotes, `[double]([exp]))
        return "%f"
    elseif bt == L.int then
        table.insert(elemQuotes, exp)
        return "%d"
    elseif bt == L.uint64 or bt:isScalarRow() then
        table.insert(elemQuotes, exp)
        return "%lu"
    elseif bt == L.bool then
        table.insert(elemQuotes, `terralib.select([exp], "true", "false"))
        return "%s"
    else
        error('Unrecognized type in print: ' .. bt:toString() .. ' ' .. tostring(bt:terraType()))
    end
end

local function buildPrintSpec(ctxt, output, printSpec, elemQuotes, definitions)
    local lt   = output.node_type
    local tt   = lt:terraType()
    local code = output:codegen(ctxt)

    if lt:isVector() then
        printSpec = printSpec .. "{"
        local sym = symbol()
        local bt = lt:baseType()
        definitions = quote
            [definitions]
            var [sym] : tt = [code]
        end
        for i = 0, lt.N - 1 do
            printSpec = printSpec .. ' ' .. printSingle(bt, `sym.d[i], elemQuotes)
        end
        printSpec = printSpec .. " }"

    elseif lt:isSmallMatrix() then
        printSpec = printSpec .. '{'
        local sym = symbol()
        local bt = lt:baseType()
        definitions = quote
            [definitions]
            var [sym] : tt = [code]
        end
        for i = 0, lt.Nrow - 1 do
            printSpec = printSpec .. ' {'
            for j = 0, lt.Ncol - 1 do
                printSpec = printSpec .. ' ' .. printSingle(bt, `sym.d[i][j], elemQuotes)
            end
            printSpec = printSpec .. ' }'
        end
        printSpec = printSpec .. ' }'

    elseif lt:isValueType() or lt:isRow() then
        printSpec = printSpec .. printSingle(lt, code, elemQuotes)
    else
        assert(false and "printed object should always be number, bool, or vector")
    end
    return printSpec, elemQuotes, definitions

end

function B.print.codegen(ast, ctxt)
    local printSpec   = ''
    local elemQuotes  = {}
    local definitions = quote end

    for i,output in ipairs(ast.params) do
        printSpec, elemQuotes, definitions = buildPrintSpec(ctxt, output, printSpec, elemQuotes, definitions)
        local t = ast.params[i+1] and " " or ""
        printSpec = printSpec .. t
    end
    printSpec = printSpec .. "\n"

    local printf = C.printf
    if (ctxt:onGPU()) then
        printf = G.printf
    end
	return quote [definitions] in printf(printSpec, elemQuotes) end
end


local function dot(a, b)
    if not a.type:isVector() then
        error("first argument to dot must be a vector", 2)
    end
    if not b.type:isVector() then
        error("second argument to dot must be a vector", 2)
    end
    if #a.data ~= #b.data then
        error("cannot dot vectors of differing lengths (" ..
                #a.data .. " and " .. #b.data .. ")")
    end
    local sum = 0
    for i = 1, #a.data do
        sum = sum + a.data[i] * b.data[i]
    end
    return sum
end

B.dot = Builtin.new(dot)

function B.dot.check(ast, ctxt)
    local args = ast.params
    if #args ~= 2 then
        ctxt:error(ast, "dot product expects exactly 2 arguments "..
                        "(instead got " .. #args .. ")")
        return L.error
    end

    local lt1 = args[1].node_type
    local lt2 = args[2].node_type

    local numvec_err = 'arguments to dot product must be numeric vectors'
    local veclen_err = 'vectors in dot product must have equal dimensions'
    if not lt1:isVector()  or not lt2:isVector() or
       not lt1:isNumeric() or not lt2:isNumeric()
    then
        ctxt:error(ast, numvec_err)
    elseif lt1.N ~= lt2.N then
        ctxt:error(ast, veclen_err)
    else
        return T.type_meet(lt1:baseType(), lt2:baseType())
    end

    return L.error
end

function B.dot.codegen(ast, ctxt)
    local args = ast.params

    local N     = args[1].node_type.N
    local lhtyp = args[1].node_type:terraType()
    local rhtyp = args[2].node_type:terraType()
    local lhe   = args[1]:codegen(ctxt)
    local rhe   = args[2]:codegen(ctxt)

    local lhval = symbol(lhtyp)
    local rhval = symbol(rhtyp)

    local exp = `0
    for i = 0, N-1 do
        exp = `exp + lhval.d[i] * rhval.d[i]
    end

    return quote
        var [lhval] = [lhe]
        var [rhval] = [rhe]
    in
        exp
    end
end


local function cross(a, b)
    if not a.type:isVector() then
        error("first argument to cross must be a vector", 2)
    end
    if not b.type:isVector() then
        error("second argument to cross must be a vector", 2)
    end
    local av = a.data
    if #av ~= 3 then
        error("arguments to cross must be vectors of length 3 (first argument is length " ..
                #av .. ")")
    end
    local bv = b.data
    if #bv ~= 3 then
        error("arguments to cross must be vectors of length 3 (second argument is length " ..
                #bv .. ")")
    end
    return L.NewVector(T.type_meet(a.type:baseType(), b.type:baseType()), {
        av[2] * bv[3] - av[3] * bv[2],
        av[3] * bv[1] - av[1] * bv[3],
        av[1] * bv[2] - av[2] * bv[1]
    })
end 

B.cross = Builtin.new(cross)

function B.cross.check(ast, ctxt)
    local args = ast.params

    if #args ~= 2 then
        ctxt:error(ast, "cross product expects exactly 2 arguments "..
                        "(instead got " .. #args .. ")")
        return L.error
    end

    local lt1 = args[1].node_type
    local lt2 = args[2].node_type

    local numvec_err = 'arguments to cross product must be numeric vectors'
    local veclen_err = 'vectors in cross product must be 3 dimensional'
    if not lt1:isVector()  or not lt2:isVector() or
       not lt1:isNumeric() or not lt2:isNumeric()
    then
        ctxt:error(ast, numvec_err)
    elseif lt1.N ~= 3 or lt2.N ~= 3 then
        ctxt:error(ast, veclen_err)
    else
        return T.type_meet(lt1, lt2)
    end

    return L.error
end

function B.cross.codegen(ast, ctxt)
    local args = ast.params

    local lhtyp = args[1].node_type:terraType()
    local rhtyp = args[2].node_type:terraType()
    local lhe   = args[1]:codegen(ctxt)
    local rhe   = args[2]:codegen(ctxt)

    local typ = T.type_meet(args[1].node_type, args[2].node_type)

    return quote
        var lhval : lhtyp = [lhe]
        var rhval : rhtyp = [rhe]
    in 
        [typ:terraType()]({ arrayof( [typ:terraBaseType()],
            lhval.d[1] * rhval.d[2] - lhval.d[2] * rhval.d[1],
            lhval.d[2] * rhval.d[0] - lhval.d[0] * rhval.d[2],
            lhval.d[0] * rhval.d[1] - lhval.d[1] * rhval.d[0]
        )})
    end
end


local function length(v)
    if not v.type:isVector() then
        error("argument to length must be a vector", 2)
    end
    return C.sqrt(dot(v, v))
end

B.length = Builtin.new(length)

function B.length.check(ast, ctxt)
    local args = ast.params
    if #args ~= 1 then
        ctxt:error(ast, "length expects exactly 1 argument (instead got " .. #args .. ")")
        return L.error
    end
    local lt = args[1].node_type
    if not lt:isVector() then
        ctxt:error(args[1], "argument to length must be a vector")
        return L.error
    end
    if not lt:baseType():isNumeric() then
        ctxt:error(args[1], "length expects vectors of numeric type")
    end
    return L.float
end

function B.length.codegen(ast, ctxt)
    local args = ast.params

    local N      = args[1].node_type.N
    local typ    = args[1].node_type:terraType()
    local exp    = args[1]:codegen(ctxt)

    local vec    = symbol(typ)

    local len2 = `0
    for i = 0, N-1 do
        len2 = `len2 + vec.d[i] * vec.d[i]
    end

    local sqrt = C.sqrt
    if ctxt:onGPU() then sqrt = G.sqrt end
    return quote
        var [vec] = [exp]
    in
        sqrt( len2 )
    end
end

function Builtin.newDoubleFunction(name)
    local cpu_fn = C[name]
    local gpu_fn = G[name]
    local lua_fn = function (arg) return cpu_fn(arg) end

    local b = Builtin.new(lua_fn)

    function b.check (ast, ctxt)
        local args = ast.params
        if #args ~= 1 then
            ctxt:error(ast, name.." expects exactly 1 argument (instead got " .. #args .. ")")
            return L.error
        end
        local lt = args[1].node_type
        if not lt:isNumeric() then
            ctxt:error(args[1], "argument to "..name.." must be numeric")
        end
        if lt:isVector() then
            ctxt:error(args[1], "argument to "..name.." must be a scalar")
            return L.error
        end
        return L.double
    end

    function b.codegen (ast, ctxt)
        local exp = ast.params[1]:codegen(ctxt)
        if ctxt:onGPU() then
            return `gpu_fn([exp])
        else
            return `cpu_fn([exp])
        end
    end
    return b
end

L.cos   = Builtin.newDoubleFunction('cos')
L.acos  = Builtin.newDoubleFunction('acos')
L.sin   = Builtin.newDoubleFunction('sin')
L.asin  = Builtin.newDoubleFunction('asin')
L.tan   = Builtin.newDoubleFunction('tan')
L.atan  = Builtin.newDoubleFunction('atan')
L.sqrt  = Builtin.newDoubleFunction('sqrt')
L.cbrt  = Builtin.newDoubleFunction('cbrt')
L.floor = Builtin.newDoubleFunction('floor')
L.ceil  = Builtin.newDoubleFunction('ceil')
L.fabs  = Builtin.newDoubleFunction('fabs')

terra b_and (a : int, b : int)
    return a and b
end

L.band = Builtin.new(b_and)
function L.band.check (ast, ctxt)
    local args = ast.params
    if #args ~= 2 then ctxt:error(ast, "binary_and expects 2 arguments (instead got " .. #args .. ")")
        return L.error
    end
    for i = 1, #args do
        local lt = args[i].node_type
        if lt ~= L.int then
            ctxt:error(args[i], "argument "..i.."to binary_and must be numeric")
            return L.error
        end
    end
    return L.int
end
function L.band.codegen(ast, ctxt)
    local exp1 = ast.params[1]:codegen(ctxt)
    local exp2 = ast.params[2]:codegen(ctxt)
    return `b_and([exp1], [exp2])
end

L.pow = Builtin.new(C.pow)
function L.pow.check (ast, ctxt)
    local args = ast.params
    if #args ~= 2 then ctxt:error(ast, "pow expects 2 arguments (instead got " .. #args .. ")")
        return L.error
    end
    for i = 1, #args do
        local lt = args[i].node_type
        if not lt:isNumeric() then
            ctxt:error(args[i], "argument "..i.." to pow must be numeric")
            return L.error
        end
    end
    for i = 1, #args do
        local lt = args[i].node_type
        if not lt:isScalar() then
            ctxt:error(args[i], "argument "..i.." to pow must be a scalar")
            return L.error
        end
    end
    return L.double
end
function L.pow.codegen(ast, ctxt)
    local exp1 = ast.params[1]:codegen(ctxt)
    local exp2 = ast.params[2]:codegen(ctxt)
    if ctxt:onGPU() then
        return `G.pow([exp1], [exp2])
    else
        return `C.pow([exp1], [exp2])
    end
end

L.fmod = Builtin.new(C.fmod)
function L.fmod.check (ast, ctxt)
    local args = ast.params
    if #args ~= 2 then ctxt:error(ast, "fmod expects 2 arguments (instead got " .. #args .. ")")
        return L.error
    end
    for i = 1, #args do
        local lt = args[i].node_type
        if not lt:isNumeric() then
            ctxt:error(args[i], "argument "..i.." to fmod must be numeric")
            return L.error
        end
    end
    for i = 1, #args do
        local lt = args[i].node_type
        if not lt:isScalar() then
            ctxt:error(args[i], "argument "..i.." to fmod must be a scalar")
            return L.error
        end
    end
    return L.double
end
function L.fmod.codegen(ast, ctxt)
    local exp1 = ast.params[1]:codegen(ctxt)
    local exp2 = ast.params[2]:codegen(ctxt)
    if ctxt:onGPU() then
        return `G.fmod([exp1], [exp2])
    else
        return `C.fmod([exp1], [exp2])
    end
end

local function all(v)
    if not v.type:isVector() then
        error("argument to length must be a vector", 2)
    end
    for _,d in ipairs(v.data) do
        if not d then return false end
    end
    return true
end

B.all = Builtin.new(all)

function B.all.check(ast, ctxt)
    local args = ast.params
    if #args ~= 1 then
        ctxt:error(ast, "all expects exactly 1 argument (instead got " .. #args .. ")")
        return L.error
    end
    local lt = args[1].node_type
    if not lt:isVector() then
        ctxt:error(args[1], "argument to all must be a vector")
        return L.error
    end
    return L.bool
end

function B.all.codegen(ast, ctxt)
    local args = ast.params

    local N      = args[1].node_type.N
    local typ    = args[1].node_type:terraType()
    local exp    = args[1]:codegen(ctxt)

    local val    = symbol(typ)

    local outexp = `true
    for i = 0, N-1 do
        outexp = `outexp and val.d[i]
    end

    return quote
        var [val] = [exp]
    in
        outexp
    end
end


local function any(v)
    if not v.type:isVector() then
        error("argument to length must be a vector", 2)
    end
    for _,d in ipairs(v.data) do
        if d then return true end
    end
    return false
end

B.any = Builtin.new(any)

function B.any.check(ast, ctxt)
    local args = ast.params
    if #args ~= 1 then
        ctxt:error(ast, "any expects exactly 1 argument (instead got " .. #args .. ")")
        return L.error
    end
    local lt = args[1].node_type
    if not lt:isVector() then
        ctxt:error(args[1], "argument to any must be a vector")
        return L.error
    end
    return L.bool
end

function B.any.codegen(ast, ctxt)
    local args   = ast.params

    local N      = args[1].node_type.N
    local typ    = args[1].node_type:terraType()
    local exp    = args[1]:codegen(ctxt)

    local val    = symbol(typ)

    local outexp = `false
    for i = 0, N-1 do
        outexp = `outexp or val.d[i]
    end

    return quote
        var [val] = [exp]
    in
        outexp
    end
end


local function map(fn, list)
    local result = {}
    for i = 1, #list do
        table.insert(result, fn(list[i]))
    end
    return result
end

local function GetTypedSymbol(arg)
    
    return symbol(arg.node_type:terraType())
end

local function TerraCheck(func)
    return function (ast, ctxt)
        local args = ast.params
        local argsyms = map(GetTypedSymbol, args)
        local rettype = nil
        local try = function()
            local terrafunc = terra([argsyms]) return func([argsyms]) end
            rettype = terrafunc:getdefinitions()[1]:gettype().returntype
        end
        local success, retval = pcall(try)
        if not success then
            ctxt:error(ast, "couldn't fit parameters to signature of terra function")
            ctxt:error(ast, retval)
            return L.error
        end
        -- Kinda terrible hack due to flux in Terra inteface here
        if rettype:isstruct() and terralib.sizeof(rettype) == 0 then
            -- case of no return value, no type is needed
            return
        end
        if not T.terraToLisztType(rettype) then
            ctxt:error(ast, "unable to use return type '" .. tostring(rettype) .. "' of terra function in Liszt")
            return L.error
        end
        return T.terraToLisztType(rettype)
    end
end

local function TerraCodegen(func)
    return function (ast, ctxt)
        local args = ast.params
        local argsyms = map(GetTypedSymbol, args)
        local init_params = quote end
        for i = 1, #args do
            local code = args[i]:codegen(ctxt)
            init_params = quote
                init_params
                var [argsyms[i]] = code
            end
        end
        return quote init_params in func(argsyms) end
    end 
end


function B.terra_to_func(terrafn)
    local newfunc = Builtin.new()
    newfunc.is_a_terra_func = true
    newfunc.check, newfunc.codegen = TerraCheck(terrafn), TerraCodegen(terrafn)
    return newfunc
end

L.Where  = B.Where
L.print  = B.print
L.assert = B.assert
L.dot    = B.dot
L.cross  = B.cross
L.length = B.length
L.id     = B.id
L.UNSAFE_ROW = B.UNSAFE_ROW
L.any    = B.any
L.all    = B.all
L.is_builtin = B.isBuiltin
