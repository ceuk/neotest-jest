---@diagnostic disable: undefined-field
local lib = require('neotest.lib')
local async = require("neotest.async")
local logger = require('neotest.logging')

---@type neotest.Adapter
local adapter = { name = 'neotest-jest' }

adapter.root = lib.files.match_root_pattern('package.json')

function adapter.is_test_file(file_path)
  if file_path == nil then
    return false
  end
  if string.match(file_path, '__tests__') then
    return true
  end
  for _, x in ipairs({ 'spec', 'test' }) do
    for _, ext in ipairs({ 'js', 'jsx', 'coffee', 'ts', 'tsx' }) do
      if string.match(file_path, x .. '%.' .. ext .. '$') then
        return true
      end
    end
  end
  return false
end

---@async
---@return neotest.Tree | nil
function adapter.discover_positions(path)
  local query = [[
  ((call_expression
      function: (identifier) @func_name (#match? @func_name "^describe")
      arguments: (arguments (string) @namespace.name (arrow_function))
  )) @namespace.definition


  ((call_expression
      function: (identifier) @func_name (#match? @func_name "^(it|test)")
      arguments: (arguments (string) @test.name (arrow_function))
  ) ) @test.definition
  ((call_expression
      function: (member_expression) @func_name (#match? @func_name "^(it|test)")
      arguments: (arguments (string) @test.name (arrow_function))
  ) ) @test.definition
    ]]
  return lib.treesitter.parse_positions(path, query, { nested_tests = true })
end

local function getJestCommand()
  if vim.fn.filereadable('node_modules/.bin/jest') then
    return 'node_modules/.bin/jest'
  end
  return 'jest'
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function adapter.build_spec(args)
  local results_path = vim.fn.tempname() .. '.json'
  local tree = args.tree
  if not tree then
    return
  end
  local pos = args.tree:data()
  -- if pos.type == "dir" then
  --   return
  --roots
  -- A list of paths to directories that Jest should use to search for files in.
  -- end
  local testNamePattern = '.*'
  if pos.type == 'test' then
    testNamePattern = pos.name
  end

  local binary = getJestCommand() or 'jest'

  local command = {}
  -- split by whitespace
  for w in binary:gmatch('%S+') do
    table.insert(command, w)
  end
  for _, value in ipairs({
    '--no-coverage',
    '--testLocationInResults',
    '--verbose',
    '--json',
    '--outputFile=' .. results_path,
    '--testNamePattern=' .. testNamePattern,
    '--runTestsByPath',
    pos.path,
  }) do
    table.insert(command, value)
  end
  return {
    command = command,
    context = {
      results_path = results_path,
      file = pos.path,
    },
  }
end

local function cleanAnsi(s)
  return s
      :gsub('\x1b%[%d+;%d+;%d+;%d+;%d+m', '')
      :gsub('\x1b%[%d+;%d+;%d+;%d+m', '')
      :gsub('\x1b%[%d+;%d+;%d+m', '')
      :gsub('\x1b%[%d+;%d+m', '')
      :gsub('\x1b%[%d+m', '')
end

local function findErrorLine(line, errStr)
  local _, _, errLine = string.find(errStr, '(%d+)%:%d+')
  if errLine then
    return errLine - 1
  end
  return line
end

local function parsed_json_to_results(data, output_file)
  local tests = {}
  local error = false

  local testFn = data.testResults[1].name
  for _, result in pairs(data.testResults[1].assertionResults) do
    local status, name = result.status, result.title
    if name == nil then
      logger.error('Failed to find parsed test result ', result)
      return {}, true
    end
    local keyid = testFn
    for _, value in ipairs(result.ancestorTitles) do
      keyid = keyid .. '::' .. '"' .. value .. '"'
    end
    keyid = keyid .. '::' .. '"' .. name .. '"'
    if status == 'pending' then
      status = 'skipped'
    end
    local test_output_path = async.fn.tempname()
    local test_output_file = assert(io.open(test_output_path, "w"))
    tests[keyid] = {
      status = status,
      short = name .. ': ' .. status,
      output = test_output_path,
      location = result.location,
    }
    if result.failureMessages and next(result.failureMessages) ~= nil then
      result.status = 'failed'
      local errors = {}
      for i, failMessage in ipairs(result.failureMessages) do
        local msg = cleanAnsi(failMessage)
        errors[i] = {
          line = findErrorLine(result.location.line - 1, msg),
          message = msg,
        }
        tests[keyid].short = tests[keyid].short .. '\n' .. msg
        test_output_file:write(failMessage)
      end
      tests[keyid].errors = errors
    else
      test_output_file:write(' \27[1;32m✔ \27[0m ' .. name)
    end
    test_output_file:close()
  end
  return tests, error
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function adapter.results(spec, _, tree)
  local output_file = spec.context.results_path
  local success, data = pcall(lib.files.read, output_file)
  if not success then
    logger.error('No test output file found ', output_file)
    return {}
  end
  local ok, parsed = pcall(vim.json.decode, data, { luanil = { object = true } })
  if not ok then
    logger.error('Failed to parse test output json ', output_file)
    return {}
  end

  local results, error = parsed_json_to_results(parsed, output_file)
  for _, value in tree:iter() do
    value.id = value.id:gsub("'", '"')
    results[value.id] = results[value.id] or value
    if results[value.id].status == nil then
      results[value.id].status = 'passed'
    end
    if error then
      results[value.id].status = 'failed'
    end
  end
  return results
end

local is_callable = function(obj)
  return type(obj) == 'function' or (type(obj) == 'table' and obj.__call)
end

setmetatable(adapter, {
  __call = function(_, opts)
    if is_callable(opts.jestCommand) then
      getJestCommand = opts.jestCommand
    elseif opts.jestCommand then
      getJestCommand = function()
        return opts.jestCommand
      end
    end
    return adapter
  end,
})

return adapter
