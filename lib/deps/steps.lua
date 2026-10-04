-- steps.lua: turn a declarative step spec into a shell command.
--
-- A step spec is one of
--   { pkg = "name" | { apt = "...", pacman = "...", dnf = "..." } }
--   { pipx = "package" }
--   { url = "...", dest = "path", sha256 = "...", extract = "dir" }
--   { cmd = "shell", priv = true, label = "..." }
--
-- build() returns { label, cmd, progress, priv, hint } or nil, reason.

local req = ...
local platform = req("platform")
local q = platform.shell_quote

local M = {}

local function expand(p, s)
  return (s:gsub("^~/", p.home .. "/"):gsub("%$HOME", p.home))
end
M.expand = expand

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function pkg_names(spec, p)
  local pkgs = spec.pkg
  if type(pkgs) == "table" and pkgs[1] == nil then pkgs = pkgs[p.pm] end
  if type(pkgs) == "string" then pkgs = { pkgs } end
  return pkgs
end

local builders = {}

function builders.pkg(spec, p)
  if not p.pm then
    return nil, "no supported package manager found"
  end
  local pkgs = pkg_names(spec, p)
  if not pkgs then
    return nil, "no " .. p.pm .. " package listed"
  end
  local list = table.concat(pkgs, " ")
  local cmd, progress
  if p.pm == "apt" then
    -- status lines go to stdout, where the runner reads them from the log
    cmd = "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
      .. " && DEBIAN_FRONTEND=noninteractive apt-get install -y"
      .. " -o APT::Status-Fd=1 " .. list
    progress = "apt"
  elseif p.pm == "pacman" then
    cmd = "pacman -S --needed --noconfirm " .. list
  elseif p.pm == "dnf" then
    cmd = "dnf install -y " .. list
  end
  local manual = ({
    apt = "apt install ", pacman = "pacman -S ", dnf = "dnf install ",
  })[p.pm] .. list
  return { label = p.pm .. ": " .. list, cmd = cmd, priv = true,
           progress = progress, manual = manual }
end

function builders.pipx(spec, p)
  return { label = "pipx: " .. spec.pipx, cmd = "pipx install " .. spec.pipx }
end

function builders.url(spec, p, ctx)
  local dest = spec.dest and expand(p, spec.dest)
    or (ctx.dir .. "/downloads/" .. basename(spec.url))
  local part = dest .. ".part"
  local dir = dest:match("^(.*)/[^/]*$") or "."

  local dl
  if platform.have("wget") then
    dl = "wget -c -t 3 --timeout=20 --progress=dot:mega -O "
      .. q(part) .. " " .. q(spec.url)
  elseif platform.have("curl") then
    dl = "curl -fL --retry 3 --connect-timeout 20 -C - -# -o "
      .. q(part) .. " " .. q(spec.url)
  else
    return nil, "neither wget nor curl is installed"
  end

  local cmd = { "mkdir -p " .. q(dir), dl }
  if spec.sha256 then
    cmd[#cmd + 1] = "echo " .. q(spec.sha256 .. "  " .. part)
      .. " | sha256sum -c -"
  end
  cmd[#cmd + 1] = "mv " .. q(part) .. " " .. q(dest)
  if spec.extract then
    local out = expand(p, spec.extract)
    cmd[#cmd + 1] = "mkdir -p " .. q(out)
    if dest:match("%.zip$") then
      cmd[#cmd + 1] = "unzip -oq " .. q(dest) .. " -d " .. q(out)
    else
      cmd[#cmd + 1] = "tar -xf " .. q(dest) .. " -C " .. q(out)
    end
    if not spec.dest then cmd[#cmd + 1] = "rm -f " .. q(dest) end
  end
  return {
    label = spec.label or ("download " .. basename(spec.url)),
    cmd = table.concat(cmd, " && "),
    progress = "percent",
  }
end

function builders.cmd(spec, p)
  return { label = spec.step_label or "run command",
           cmd = expand(p, spec.cmd), priv = spec.priv,
           progress = spec.progress }
end

function M.build(spec, p, ctx)
  for _, kind in ipairs { "pkg", "pipx", "url", "cmd" } do
    if spec[kind] then
      local step, err = builders[kind](spec, p, ctx)
      if not step then return nil, err end
      if step.priv then
        step.hint = platform.manual_cmd(p, step.manual or step.cmd)
        if not p.priv then
          return nil, "needs root; sudo asks for a password", step.hint
        end
        step.run = platform.wrap_priv(p, step.cmd)
      else
        step.run = step.cmd
      end
      return step
    end
  end
  return nil, "unknown step"
end

-- does a recipe's `when` table match this platform?
local function match(want, have)
  if type(want) == "table" then
    for _, v in ipairs(want) do if v == have then return true end end
    return false
  end
  return want == have
end

function M.matches(when, p)
  for k, v in pairs(when or {}) do
    if not match(v, p[k]) then return false end
  end
  return true
end

-- first recipe whose `when` matches, compiled; nil, reason, hints otherwise
function M.plan(spec, p, ctx)
  for _, recipe in ipairs(spec.install or {}) do
    if M.matches(recipe.when, p) then
      local steps, hints = {}, {}
      for _, s in ipairs(recipe.steps) do
        local step, err, hint = M.build(s, p, ctx)
        if not step then return nil, err, hint end
        steps[#steps + 1] = step
      end
      return steps
    end
  end
  return nil, "no install recipe for " .. tostring(p.arch)
    .. "/" .. tostring(p.pm)
end

return M
