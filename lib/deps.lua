-- deps.lua: declare, check and install a norns script's dependencies.
--
--   local deps = include("lib/deps")
--   local d = deps.new { name = "myscript", dir = _path.data .. "myscript/deps" }
--   d:add { id = "sox", check = "sox", pkg = "sox", size = "1 MB",
--           why = "resamples rendered audio" }
--   if not d:ok("sox") then d:ensure({ "sox" }, { on_done = function(ok) end }) end
--
-- See README.md for the spec format.

-- Load with require or norns' include(): submodules are found next to this
-- file (lib/deps/), whatever name the script gave its directory.
local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local loaded = {}
local function req(name)
  if not loaded[name] then
    loaded[name] = assert(loadfile(dir .. "/deps/" .. name .. ".lua"))(req)
  end
  return loaded[name]
end
local platform = req("platform")
local steps = req("steps")
local ugens = req("ugens")
local session_mod = req("session")
local ui = req("ui")

local Deps = {}
Deps.__index = Deps

local M = {}
M.platform = platform
M.ugens = ugens
M.steps = steps
M.runner = req("runner")
-- prefix for shell commands that should see pipx / /usr/local binaries
M.PATH_EXPORT = platform.PATH_EXPORT

function M.new(opts)
  local self = setmetatable({
    name = opts.name or "script",
    dir = opts.dir,
    specs = {},
    order = {},
    platform = opts.platform or platform.detect(),
  }, Deps)
  assert(self.dir, "deps.new: dir is required")
  return self
end

local function normalize(spec)
  assert(spec.id, "dependency needs an id")
  if not spec.install then
    local step = {}
    for _, k in ipairs { "pkg", "pipx", "url", "dest", "sha256", "extract",
                         "cmd", "priv", "step_label", "progress" } do
      step[k] = spec[k]
    end
    if next(step) then spec.install = { { steps = { step } } } end
  end
  spec.install = spec.install or {}
  return spec
end

function Deps:add(spec)
  spec = normalize(spec)
  self.specs[spec.id] = spec
  self.order[#self.order + 1] = spec.id
  return spec
end

function Deps:spec(id)
  return assert(self.specs[id], "unknown dependency: " .. tostring(id))
end

local function as_list(v)
  if v == nil then return {} end
  if type(v) == "table" then return v end
  return { v }
end

-- is this dependency in place right now? cheap, synchronous
function Deps:check(spec)
  if type(spec) == "string" then spec = self:spec(spec) end
  if spec.check_fn then return spec.check_fn() and true or false end
  local checked = false
  for _, name in ipairs(as_list(spec.check)) do
    checked = true
    if not platform.have(name) then return false end
  end
  for _, path in ipairs(as_list(spec.check_file)) do
    checked = true
    local f = io.open(steps.expand(self.platform, path), "r")
    if not f then return false end
    f:close()
  end
  for _, name in ipairs(as_list(spec.check_ugens)) do
    checked = true
    if not ugens.installed(self.platform, name) then return false end
  end
  return checked
end

Deps.ok = Deps.check

-- { id = bool, ... } for ids (default: everything added)
function Deps:status(ids)
  local out = {}
  for _, id in ipairs(ids or self.order) do out[id] = self:check(id) end
  return out
end

function Deps:missing(ids)
  local out = {}
  for _, id in ipairs(ids or self.order) do
    if not self:check(id) then out[#out + 1] = id end
  end
  return out
end

-- duplicate UGen/class files on the SC class path: { name = { paths } }
function Deps:ugen_conflicts(names)
  return ugens.duplicates(self.platform, names)
end

-- ids plus everything they `need`, dependencies first, no repeats
function Deps:expand(ids)
  local out, seen = {}, {}
  local function visit(id)
    if seen[id] then return end
    seen[id] = true
    local spec = self:spec(id)
    for _, need in ipairs(as_list(spec.needs)) do visit(need) end
    for _, recipe in ipairs(spec.install or {}) do
      if steps.matches(recipe.when, self.platform) then
        for _, need in ipairs(as_list(recipe.needs)) do visit(need) end
        break
      end
    end
    out[#out + 1] = id
  end
  for _, id in ipairs(ids or self.order) do visit(id) end
  return out
end

-- headless session, for tests and custom UIs
function Deps:session(ids)
  return session_mod.new(self, self:expand(ids))
end

-- Open the install screen. Takes over key/enc/redraw until it closes, then
-- puts the script's own handlers back and calls
-- opts.on_done(ok, results, did_install).
-- Does nothing (calls on_done at once) when everything is already in place.
function Deps:ensure(ids, opts)
  opts = opts or {}
  local s = self:session(ids)
  local function finish()
    local ok = s:ok()
    if opts.on_done then opts.on_done(ok, s.results, s.did_install) end
  end
  if s.state == "done" then return finish() end

  local running = true
  local menu_active = norns.menu.status()
  local saved = {
    key = key, enc = enc, redraw = redraw, refresh = refresh,
    script_redraw = norns.script.redraw,
  }
  if menu_active then
    saved.menu = {
      enc = norns.menu.get_enc(), key = norns.menu.get_key(),
      redraw = norns.menu.get_redraw(), refresh = norns.menu.get_refresh(),
    }
  end

  local function installer_redraw() ui.draw(s) end
  local function installer_enc(n, d)
    ui.enc(s, n, d)
    installer_redraw()
  end
  local close
  local function installer_key(n, z)
    if ui.key(s, n, z) then close() else installer_redraw() end
  end

  -- norns restores `redraw` from norns.script.redraw, and `_menu.key` and
  -- the encoder callback from the globals, whenever the menu is left or
  -- norns.menu.init() runs, so all of them have to point at the installer.
  local function take_over()
    key, enc, redraw, refresh = installer_key, installer_enc,
      installer_redraw, installer_redraw
    norns.script.redraw = installer_redraw
    if menu_active then
      norns.menu.set(installer_enc, installer_key, installer_redraw,
        installer_redraw)
    else
      norns.menu.init()
      -- init() leaves the screen to the script; draw ours again
      redraw = installer_redraw
    end
  end

  function close()
    running = false
    key, enc, refresh = saved.key, saved.enc, saved.refresh
    norns.script.redraw = saved.script_redraw
    if menu_active then
      redraw = saved.redraw
      norns.menu.set(saved.menu.enc, saved.menu.key, saved.menu.redraw,
        saved.menu.refresh)
    else
      redraw = saved.script_redraw or saved.redraw
      norns.menu.init()
    end
    finish()
    if menu_active then
      if saved.menu.redraw then saved.menu.redraw() end
    elseif redraw then
      redraw()
    end
  end

  take_over()
  clock.run(function()
    while running do
      clock.sleep(0.25)
      if running then
        s:tick()
        if running then installer_redraw() end
      end
    end
  end)
  installer_redraw()
  return s
end

return M
