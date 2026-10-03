-- ugens.lua: find duplicate UGen plugins and class files on the SC class path.
--
-- sclang refuses to compile when the same class is defined twice, and
-- scsynth warns about duplicate plugins. This is easy to cause by installing
-- a UGen pack by hand and from a script. We look for the same file name in
-- more than one place under the directories sclang searches.

local req = ...
local platform = req("platform")
local q = platform.shell_quote

local M = {}

local function sclang_include_paths(home)
  local paths = {}
  local f = io.open(home .. "/.config/SuperCollider/sclang_conf.yaml", "r")
  if not f then return paths end
  local inside
  for line in f:lines() do
    if line:match("^%S") then inside = line:match("^includePaths:") ~= nil end
    local path = inside and line:match("^%s*%-%s*(.-)%s*$")
    if path then paths[#paths + 1] = path end
  end
  f:close()
  return paths
end

function M.roots(p)
  local roots = {
    p.home .. "/.local/share/SuperCollider/Extensions",
    "/usr/local/share/SuperCollider/Extensions",
    "/usr/share/SuperCollider/Extensions",
  }
  for _, path in ipairs(sclang_include_paths(p.home)) do
    roots[#roots + 1] = path
  end
  return roots
end

-- { ["MiPlaits.scx"] = { "/a/MiPlaits.scx", "/b/MiPlaits.scx" }, ... }
-- Only names found in more than one place. `names` limits the search.
function M.duplicates(p, names)
  local dirs = {}
  for _, root in ipairs(M.roots(p)) do
    if platform.run("test -d " .. q(root)) then dirs[#dirs + 1] = q(root) end
  end
  if #dirs == 0 then return {} end

  local found, seen = {}, {}
  local out = platform.capture(
    "find " .. table.concat(dirs, " ")
    .. " \\( -name '*.scx' -o -name '[A-Z]*.sc' \\)"
    .. " -not -path '*/.git/*' -type f")
  for path in out:gmatch("[^\n]+") do
    if not seen[path] then
      seen[path] = true
      local name = path:match("([^/]+)$")
      found[name] = found[name] or {}
      table.insert(found[name], path)
    end
  end

  local dups = {}
  for name, paths in pairs(found) do
    local wanted = true
    if names then
      wanted = false
      for _, n in ipairs(names) do if n == name then wanted = true end end
    end
    if wanted and #paths > 1 then dups[name] = paths end
  end
  return dups
end

-- is a named plugin/class file installed anywhere on the path?
function M.installed(p, name)
  local roots = {}
  for _, root in ipairs(M.roots(p)) do roots[#roots + 1] = q(root) end
  local out = platform.capture("find " .. table.concat(roots, " ")
    .. " -name " .. q(name) .. " -type f 2>/dev/null | head -n 1")
  return out ~= ""
end

return M
