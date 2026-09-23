-- Shared ESE mod runtime for Lua 5.1.
ESE = ESE or {}
if ESE.core_loaded then return ESE end
ESE.core_loaded = true
ESE.version = ESE.version or '0.3'
ESE.notes, ESE.faults = ESE.notes or {}, ESE.faults or {}
ESE.handlers, ESE.bridges = ESE.handlers or {}, ESE.bridges or {}
ESE.mods, ESE.mod_status = ESE.mods or {}, ESE.mod_status or {}
ESE._sequence, ESE.max_handler_faults = ESE._sequence or 0, 3

local function corelog(s)
  if type(ESE_Log) == 'function' then ESE_Log('[core] ' .. tostring(s)) end
end
ESE.log = ESE.log or corelog

local function guarded(label, fn)
  if type(ESE_Protect) == 'function' then
    local result = ESE_Protect(fn)
    if result == 'true' then return true end
    ESE.faults[#ESE.faults + 1] = label .. ': ' .. tostring(result)
    return false, result
  end
  local ok, result = pcall(fn)
  if not ok then ESE.faults[#ESE.faults + 1] = label .. ': ' .. tostring(result) end
  return ok, result
end
ESE.guard = guarded
ESE.safe = ESE.safe or function(label, fn) return guarded(label, fn) end

local function before(a, b)
  if a.priority ~= b.priority then return a.priority < b.priority end
  return a.sequence < b.sequence
end

function ESE.on(event, id, fn, priority)
  assert(type(event) == 'string' and event ~= '', 'event name required')
  assert(type(id) == 'string' and id ~= '', 'handler id required')
  assert(type(fn) == 'function', 'handler function required')
  local list = ESE.handlers[event] or {}
  ESE.handlers[event] = list
  for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
  ESE._sequence = ESE._sequence + 1
  list[#list + 1] = { id=id, fn=fn, priority=tonumber(priority) or 100,
    sequence=ESE._sequence, faults=0, enabled=true }
  table.sort(list, before)
  return id
end

function ESE.off(event, id)
  local list = ESE.handlers[event]
  if not list then return false end
  for i = #list, 1, -1 do
    if list[i].id == id then table.remove(list, i); return true end
  end
  return false
end

function ESE.emit(event, ...)
  local list = ESE.handlers[event]
  if not list then return 0 end
  local args, called = {...}, 0
  for _, h in ipairs(list) do
    if h.enabled then
      local ok = guarded(event .. '/' .. h.id, function() h.fn(unpack(args)) end)
      if ok then h.faults = 0 else
        h.faults = h.faults + 1
        if h.faults >= ESE.max_handler_faults then
          h.enabled = false
          corelog('quarantined ' .. event .. '/' .. h.id .. ' after ' .. h.faults .. ' faults')
        end
      end
      called = called + 1
    end
  end
  return called
end

function ESE.on_event(event, id, fn, priority)
  ESE.on(event, id, fn, priority)
  if ESE.bridges[event] then return id end
  if type(events) ~= 'table' or type(events[event]) ~= 'table' then
    corelog('event unavailable in ' .. tostring(ESE.state) .. ': ' .. event)
    return id
  end
  events[event][#events[event] + 1] = function(context) ESE.emit(event, context) end
  ESE.bridges[event] = true
  return id
end

function ESE._run_tick() ESE.emit('tick') end
function ESE.on_tick(id, fn, priority)
  ESE.on('tick', id, fn, priority)
  if not ESE.bridges.tick and type(ESE_Tick) == 'function' then
    ESE_Tick('ms', '16')
    ESE_Tick('on', 'ESE._run_tick()')
    ESE.bridges.tick = true
  end
  return id
end

function ESE.runtime_status()
  local loaded, failed, handlers, quarantined = 0, 0, 0, 0
  for _, status in pairs(ESE.mod_status) do
    if status.state == 'loaded' then loaded = loaded + 1 end
    if status.state == 'failed' then failed = failed + 1 end
  end
  for _, list in pairs(ESE.handlers) do
    for _, h in ipairs(list) do
      handlers = handlers + 1
      if not h.enabled then quarantined = quarantined + 1 end
    end
  end
  return string.format('state=%s mods=%d failed=%d handlers=%d quarantined=%d',
    tostring(ESE.state), loaded, failed, handlers, quarantined)
end
function ESE_RuntimeStatus() return ESE.runtime_status() end

local function has_state(m, wanted)
  if type(m.states) ~= 'table' then return true end
  for _, state in ipairs(m.states) do if state == wanted or state == 'all' then return true end end
  return false
end

local function normalize(entry)
  if type(entry) == 'string' then return {id=entry, path=entry, enabled=true} end
  if type(entry) ~= 'table' then return nil end
  entry.id, entry.path = entry.id or entry.path, entry.path or entry.id
  if entry.enabled == nil then entry.enabled = true end
  return entry
end

local function read_manifest(root, entry)
  local dir = root .. entry.path .. '\\'
  local m = {id=entry.id, path=entry.path, entry='mod.lua', states={'all'}}
  local chunk = loadfile(dir .. 'manifest.lua')
  if chunk then
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= 'table' then return nil, 'invalid manifest: ' .. tostring(value) end
    for k, v in pairs(value) do m[k] = v end
  end
  m.id, m.path, m.enabled = entry.id or m.id, entry.path or m.path or m.id, entry.enabled
  m.priority, m.depends = tonumber(entry.priority or m.priority) or 100, m.depends or {}
  m.entry, m.dir = m.entry or 'mod.lua', root .. (entry.path or m.path) .. '\\'
  return m
end

local function order(manifests)
  local byid, result, visiting, visited = {}, {}, {}, {}
  for _, m in ipairs(manifests) do
    if byid[m.id] then return nil, 'duplicate mod id ' .. m.id end
    byid[m.id] = m
  end
  local function visit(m)
    if visited[m.id] then return true end
    if visiting[m.id] then return false, 'dependency cycle at ' .. m.id end
    visiting[m.id] = true
    for _, dep in ipairs(m.depends) do
      if not byid[dep] then return false, m.id .. ' needs missing mod ' .. dep end
      local ok, err = visit(byid[dep]); if not ok then return false, err end
    end
    visiting[m.id], visited[m.id] = nil, true
    result[#result + 1] = m
    return true
  end
  table.sort(manifests, function(a,b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    return a.id < b.id
  end)
  for _, m in ipairs(manifests) do local ok, err=visit(m); if not ok then return nil, err end end
  return result
end

function ESE.load_configured_mods(state)
  ESE.state, ESE.battle = state, state == 'battle'
  local root = os.getenv('ESE_MODS_DIR')
  if not root or root == '' then root = os.getenv('ESE_CHAIN_DIR') end
  if not root or root == '' then root = [[EmpireScriptExtender\lua\]] end
  root = root:gsub('/', '\\'); if root:sub(-1) ~= '\\' then root = root .. '\\' end
  ESE.mods_dir = root
  local listfn, lerr = loadfile(root .. 'ese_mods.lua')
  if not listfn then corelog('registry unavailable: ' .. tostring(lerr)); return false end
  local ok, entries = pcall(listfn)
  if not ok or type(entries) ~= 'table' then corelog('registry invalid: ' .. tostring(entries)); return false end
  local manifests = {}
  for _, raw in ipairs(entries) do
    local entry = normalize(raw)
    if entry and entry.id and entry.path then
      local m, err = read_manifest(root, entry)
      if m then manifests[#manifests + 1] = m
      else ESE.mod_status[entry.id]={state='failed',reason=err}; corelog(entry.id .. ': ' .. err) end
    end
  end
  local plan, perr = order(manifests)
  if not plan then corelog('load plan rejected: ' .. tostring(perr)); return false end
  for _, m in ipairs(plan) do
    if not m.enabled then ESE.mod_status[m.id] = {state='disabled'}
    elseif not has_state(m, state) then ESE.mod_status[m.id] = {state='skipped',reason='state '..state}
    else
      local blocked
      for _, dep in ipairs(m.depends) do
        if not ESE.mod_status[dep] or ESE.mod_status[dep].state ~= 'loaded' then
          blocked = dep
          break
        end
      end
      if blocked then
        ESE.mod_status[m.id] = {state='skipped',reason='dependency '..blocked..' is not loaded'}
        corelog(m.id .. ': skipped because dependency ' .. blocked .. ' is not loaded')
      else
      local entryfn, err = loadfile(m.dir .. m.entry)
      if not entryfn then
        ESE.mod_status[m.id]={state='failed',reason=tostring(err)}
        corelog(m.id .. ': entry failed to compile - ' .. tostring(err))
      else
        ESE.mod_dir, ESE.loading_mod = m.dir, m.id
        local loaded, result = guarded('load/' .. m.id, entryfn)
        ESE.mod_dir, ESE.loading_mod = nil, nil
        if loaded then
          ESE.mods[#ESE.mods+1]=m.id; ESE.mod_status[m.id]={state='loaded',version=m.version}
          corelog(m.id .. ': loaded')
        else
          ESE.mod_status[m.id]={state='failed',reason=tostring(result)}
          corelog(m.id .. ': failed - ' .. tostring(result))
        end
      end
      end
    end
  end
  corelog(#ESE.mods .. ' mod(s) loaded for ' .. state)
  return true
end

return ESE
