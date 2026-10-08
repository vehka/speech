-- speech
-- v0.5.0 @vehka
-- Design spoken phrases with eSpeak NG, flite, or Piper and save them.
--
-- E1: select phrase
-- E2: select synthesis parameter
-- E3: adjust synthesis parameter
-- K2: render and preview
-- K3: save WAV to dust/audio/speech

local PARAM_PREFIX = "speech_"
local DATA_DIR = _path.data .. "speech/"
local OUTPUT_DIR = _path.audio .. "speech/"
local PREVIEW_FILE = DATA_DIR .. "speech-preview.wav"
local LOG_FILE = DATA_DIR .. "speech.log"
local PREVIEW_NAME = "speech-preview.wav"
local PREVIEW_TAIL_SECONDS = 0.5
local DEFAULT_PHRASE = "I am Norns."
local PHRASE_COUNT = 9
local ACTIVE_PHRASE_PARAM = PARAM_PREFIX .. "phrase_number"
local BACKENDS = { "eSpeak NG", "flite", "Piper" }
local ESPEAK_VOICE_PARAM = PARAM_PREFIX .. "espeak_voice_option"
local FLITE_VOICE_PARAM = PARAM_PREFIX .. "flite_voice_option"
local PIPER_MODEL_PARAM = PARAM_PREFIX .. "piper_model"
local DEFAULT_PIPER_MODEL = (os.getenv("HOME") or "")
  .. "/.local/share/piper/voices/en_GB-alan-low.onnx"
-- monotone speech: a private eSpeak data directory holding a flat variant
local ESPEAK_DIR = DATA_DIR .. "espeak"
local MONOTONE_VARIANT = "speechmono"
-- a variant "pitch N N" line speaks at N - 9 Hz when -p is 50
local MONOTONE_PITCH_OFFSET = 9
local MONOTONE_PARAM = PARAM_PREFIX .. "monotone"
local NOTE_PARAM = PARAM_PREFIX .. "note"
local TAPE_READY = 1
local TAPE_PLAYING = 2
local TAPE_PAUSED = 3

local musicutil = require "musicutil"
local text_editor = include("lib/text_editor")
local deps = include("lib/deps")

local PIPER_VOICE_URL = "https://huggingface.co/rhasspy/piper-voices"
  .. "/resolve/main/en/en_GB/alan/low/en_GB-alan-low.onnx"
local PIPER_ARMV7_URL = "https://github.com/rhasspy/piper/releases/download"
  .. "/2023.11.14-2/piper_linux_armv7l.tar.gz"
local PIPER_RUNTIME_DIR = (os.getenv("HOME") or "")
  .. "/.local/share/piper/runtime"
local system_textentry = require "textentry"
local original_textentry_enter
local custom_textentry_enter

local EDITABLE_TEXT_HEADINGS = {
  ["PARAM: output name"] = true,
}
for i = 1, PHRASE_COUNT do
  EDITABLE_TEXT_HEADINGS["PARAM: " .. i] = true
end

local ESPEAK_CONTROLS = {
  { id = PARAM_PREFIX .. "speed", name = "speed" },
  { id = PARAM_PREFIX .. "pitch", name = "pitch" },
  { id = PARAM_PREFIX .. "range", name = "pitch range" },
  { id = MONOTONE_PARAM, name = "monotone" },
  { id = NOTE_PARAM, name = "monotone note" },
  { id = PARAM_PREFIX .. "amplitude", name = "amplitude" },
  { id = PARAM_PREFIX .. "word_gap", name = "word gap" },
}

local FLITE_CONTROLS = {
  { id = PARAM_PREFIX .. "flite_duration", name = "duration stretch" },
  { id = PARAM_PREFIX .. "flite_pitch", name = "pitch shift" },
}

local PIPER_CONTROLS = {
  { id = PARAM_PREFIX .. "piper_length", name = "length scale" },
  { id = PARAM_PREFIX .. "piper_noise", name = "noise scale" },
  { id = PARAM_PREFIX .. "piper_noise_w", name = "noise width" },
}

local ESPEAK_PARAM_IDS = {
  ESPEAK_VOICE_PARAM,
  PARAM_PREFIX .. "speed",
  PARAM_PREFIX .. "pitch",
  PARAM_PREFIX .. "range",
  MONOTONE_PARAM,
  NOTE_PARAM,
  PARAM_PREFIX .. "amplitude",
  PARAM_PREFIX .. "word_gap",
}

local FLITE_PARAM_IDS = {
  FLITE_VOICE_PARAM,
  PARAM_PREFIX .. "flite_duration",
  PARAM_PREFIX .. "flite_pitch",
}

local PIPER_PARAM_IDS = {
  PIPER_MODEL_PARAM,
  PARAM_PREFIX .. "piper_length",
  PARAM_PREFIX .. "piper_noise",
  PARAM_PREFIX .. "piper_noise_w",
}

local controls = ESPEAK_CONTROLS
local selected_control = 1
local status = "K2 preview  K3 save"
local busy = false
local job_clock = nil
local espeak_available = false
local espeak_data_linked = false
local flite_available = false
local piper_available = false
local sox_available = false
local espeak_voices = { "en" }
local flite_voices = { "kal" }

-- what the script needs installed; see lib/deps for the spec format
local speech_deps = deps.new { name = "speech", dir = DATA_DIR .. "deps" }
speech_deps:add { id = "sox", label = "SoX", check = "sox", pkg = "sox",
  size = "1 MB", why = "converts renders to 48 kHz WAV" }
speech_deps:add { id = "espeak", label = "eSpeak NG", check = "espeak-ng",
  pkg = "espeak-ng", size = "3 MB", why = "formant speech backend" }
speech_deps:add { id = "flite", label = "flite", check = "flite",
  pkg = "flite", size = "5 MB", why = "small speech backend" }
speech_deps:add { id = "pipx", label = "pipx", check = "pipx",
  pkg = { apt = "pipx", pacman = "python-pipx", dnf = "pipx" },
  size = "2 MB", why = "installs Python tools" }
speech_deps:add { id = "piper", label = "Piper", check = "piper",
  size = "25 MB", why = "neural speech backend",
  install = {
    -- the Python wheels do not support 32-bit ARM (norns shield)
    { when = { arch = "armv7l" }, steps = {
      { url = PIPER_ARMV7_URL, extract = PIPER_RUNTIME_DIR,
        sha256 = "c6946fcd57c705ed1d4666ea880f80ba0bbbd14de62ecbdd13460baf3bac8e37",
        label = "download Piper" },
      { cmd = "ln -sfn " .. PIPER_RUNTIME_DIR
          .. "/piper/piper /usr/local/bin/piper",
        priv = true, label = "link piper" },
    } },
    { needs = { "pipx" }, steps = { { pipx = "piper-tts" } } },
  } }
speech_deps:add { id = "piper_voice", label = "Piper voice (Alan)",
  check_file = { DEFAULT_PIPER_MODEL, DEFAULT_PIPER_MODEL .. ".json" },
  size = "63 MB", why = "default Piper model", install = { { steps = {
    { url = PIPER_VOICE_URL .. ".json", dest = DEFAULT_PIPER_MODEL .. ".json",
      sha256 = "c8164cc04b6ce102c651ce4a1e788e8429fa638501fca0723860718d4b44637e",
      label = "download voice config" },
    { url = PIPER_VOICE_URL, dest = DEFAULT_PIPER_MODEL,
      sha256 = "a1f60584620a2bed203de823d08f5abb336fb15f3d6f33f8c341e3e2cabf5dde",
      label = "download Alan voice" },
  } } } }

local function install_deps(ids)
  speech_deps:ensure(ids, { on_done = function(ok, _, did_install)
    -- availability, voice lists and params are built at init: start over
    if did_install then
      clock.run(function()
        clock.sleep(0.2)
        norns.script.load(norns.state.script)
      end)
    end
  end })
end

local function phrase_param_id(index)
  if index == 1 then return PARAM_PREFIX .. "phrase" end
  return PARAM_PREFIX .. "phrase_" .. index
end

local function active_phrase_number()
  return params:get(ACTIVE_PHRASE_PARAM)
end

local function active_phrase()
  return params:get(phrase_param_id(active_phrase_number())) or ""
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function add_unique(list, seen, value)
  if value and value ~= "" and not seen[value] then
    list[#list + 1] = value
    seen[value] = true
  end
end

local function discover_espeak_voices()
  local voices = {}
  local seen = {}
  add_unique(voices, seen, "en")
  if not espeak_available then return voices end

  local output = util.os_capture(
    deps.PATH_EXPORT .. "espeak-ng --voices 2>/dev/null", true)
  for line in (output or ""):gmatch("[^\r\n]+") do
    add_unique(voices, seen, line:match("^%s*%d+%s+(%S+)"))
  end
  return voices
end

local function discover_flite_voices()
  if not flite_available then return { "kal" } end

  local voices = {}
  local seen = {}
  local found_header = false
  local output = util.os_capture(
    deps.PATH_EXPORT .. "flite -lv 2>/dev/null", true)
  for token in (output or ""):gmatch("%S+") do
    if found_header then
      add_unique(voices, seen, token)
    elseif token == "available:" then
      found_header = true
    end
  end
  if #voices == 0 then voices[1] = "kal" end
  return voices
end

local function set_status(message)
  status = message
  redraw()
end

local function install_text_editor()
  original_textentry_enter = system_textentry.enter
  custom_textentry_enter = function(callback, default, heading, check)
    if EDITABLE_TEXT_HEADINGS[heading] then
      text_editor.enter(function(text)
        callback(text == nil and "cancel" or text)
      end, default, heading, check)
    else
      original_textentry_enter(callback, default, heading, check)
    end
  end
  system_textentry.enter = custom_textentry_enter
end

local function output_filename()
  local name = params:get(PARAM_PREFIX .. "filename") or ""
  if name:lower():sub(-4) == ".wav" then
    name = name:sub(1, -5)
  end
  name = name:gsub("[^%w_-]+", "_")
  name = name:gsub("^_+", ""):gsub("_+$", "")
  if name == "" then
    name = os.date("speech_%Y%m%d_%H%M%S")
  end
  return name .. ".wav"
end

local function backend_error()
  if not sox_available then return "sox not found" end
  local backend = params:get(PARAM_PREFIX .. "backend")
  if backend == 1 and not espeak_available then
    return "espeak-ng not found"
  elseif backend == 2 and not flite_available then
    return "flite not found"
  elseif backend == 3 then
    if not piper_available then return "piper not found" end
    local model = params:get(PIPER_MODEL_PARAM)
    if model == "-" or not util.file_exists(model) then
      return "Piper model not found"
    elseif not util.file_exists(model .. ".json") then
      return "Piper config not found"
    end
  end
end

-- eSpeak loads voice variants only from its data directory, so the flat
-- variant goes into a copy of the system one made of symlinks
local function prepare_monotone_voice(pitch)
  local data = ESPEAK_DIR .. "/espeak-ng-data"
  if not espeak_data_linked then
    local version = util.os_capture(
      deps.PATH_EXPORT .. "espeak-ng --version 2>/dev/null", true)
    local system_data = (version or ""):match("Data at:%s*([^\r\n]+)")
    if not system_data then return false, "eSpeak data not found" end
    local source = shell_quote((system_data:gsub("%s+$", "")))
    local target = shell_quote(data)
    espeak_data_linked = os.execute(string.format(
      "{ mkdir -p %s/voices/'!v'"
        .. " && for f in %s/*; do [ \"${f##*/}\" = voices ]"
        .. " || ln -sfn \"$f\" %s/; done"
        .. " && for f in %s/voices/*; do [ \"${f##*/}\" = '!v' ]"
        .. " || ln -sfn \"$f\" %s/voices/; done"
        .. " && ln -sfn %s/voices/'!v'/* %s/voices/'!v'/; } >>%s 2>&1",
      target, source, target, source, target, source, target,
      shell_quote(LOG_FILE))) == true
    if not espeak_data_linked then
      return false, "monotone setup failed; see data log"
    end
  end

  local file, open_error = io.open(
    data .. "/voices/!v/" .. MONOTONE_VARIANT, "w")
  if not file then
    return false, open_error or "could not write monotone voice"
  end
  file:write(string.format(
    "language variant\nname %s\nflutter 0\npitch %d %d\n",
    MONOTONE_VARIANT, pitch, pitch))
  file:close()
  return true
end

local function render_wav(path, tail_seconds)
  local unavailable = backend_error()
  if unavailable then return false, unavailable end

  local phrase = active_phrase()
  if phrase:match("^%s*$") then
    return false, "phrase is empty"
  end

  local backend = params:get(PARAM_PREFIX .. "backend")
  local espeak_voice = params:string(ESPEAK_VOICE_PARAM)
  local espeak_pitch = params:get(PARAM_PREFIX .. "pitch")
  local espeak_path = ""
  local tune_effect = ""
  if backend == 1 and params:get(MONOTONE_PARAM) == 2 then
    if not espeak_voice:match("^en") then
      return false, "monotone: English voices only"
    end
    local hz = musicutil.note_num_to_freq(params:get(NOTE_PARAM))
    local variant_pitch = util.round(hz) + MONOTONE_PITCH_OFFSET
    local prepared, prepare_error = prepare_monotone_voice(variant_pitch)
    if not prepared then return false, prepare_error end
    espeak_voice = espeak_voice .. "+" .. MONOTONE_VARIANT
    espeak_pitch = 50
    espeak_path = " --path=" .. shell_quote(ESPEAK_DIR)
    -- the variant pitch is in whole Hz; retune the remainder
    tune_effect = string.format(" speed %.2fc",
      1200 * math.log(hz / util.round(hz)) / math.log(2))
  elseif backend == 1 then
    -- embedded pitch range command; unlike -P it works in eSpeak NG 1.50
    phrase = string.format("\1%dR", params:get(PARAM_PREFIX .. "range"))
      .. phrase
  end

  local path_stem = path:gsub("%.wav$", "")
  local source_path = path_stem .. ".source.wav"
  local text_path = path_stem .. ".source.txt"
  local temp_path = path_stem .. ".tmp.wav"
  os.remove(source_path)
  os.remove(text_path)
  os.remove(temp_path)

  local text_file, open_error = io.open(text_path, "wb")
  if not text_file then
    return false, open_error or "could not create text input"
  end
  local written, write_error = text_file:write(phrase)
  text_file:close()
  if not written then
    os.remove(text_path)
    return false, write_error or "could not write text input"
  end

  local command
  if backend == 1 then
    command = string.format(
      "espeak-ng --stdin%s -v %s -s %d -p %d"
        .. " -a %d -g %d -w %s < %s",
      espeak_path,
      shell_quote(espeak_voice),
      params:get(PARAM_PREFIX .. "speed"),
      espeak_pitch,
      params:get(PARAM_PREFIX .. "amplitude"),
      params:get(PARAM_PREFIX .. "word_gap"),
      shell_quote(source_path),
      shell_quote(text_path)
    )
  elseif backend == 2 then
    local voice = params:string(FLITE_VOICE_PARAM)
    command = string.format(
      "flite --setf duration_stretch=%.2f --setf f0_shift=%.4f"
        .. " -voice %s -f %s -o %s",
      params:get(PARAM_PREFIX .. "flite_duration") / 100,
      2 ^ (params:get(PARAM_PREFIX .. "flite_pitch") / 12),
      shell_quote(voice),
      shell_quote(text_path),
      shell_quote(source_path)
    )
  else
    command = string.format(
      "piper --model %s --output_file %s"
        .. " --length_scale %.2f --noise_scale %.2f --noise_w %.2f < %s",
      shell_quote(params:get(PIPER_MODEL_PARAM)),
      shell_quote(source_path),
      params:get(PARAM_PREFIX .. "piper_length") / 100,
      params:get(PARAM_PREFIX .. "piper_noise") / 100,
      params:get(PARAM_PREFIX .. "piper_noise_w") / 100,
      shell_quote(text_path)
    )
  end
  local tail_effect = tail_seconds
      and string.format(" pad 0 %.2f", tail_seconds) or ""
  command = command .. string.format(
    " >>%s 2>&1 && sox -G %s -r 48000 %s%s%s >>%s 2>&1",
    shell_quote(LOG_FILE),
    shell_quote(source_path),
    shell_quote(temp_path),
    tune_effect,
    tail_effect,
    shell_quote(LOG_FILE)
  )

  local rendered = os.execute(deps.PATH_EXPORT .. command) == true
  os.remove(text_path)
  if not rendered or not util.file_exists(temp_path) then
    os.remove(source_path)
    os.remove(temp_path)
    return false, "render failed; see data log"
  end
  os.remove(source_path)

  local renamed, rename_error = os.rename(temp_path, path)
  if not renamed then
    os.remove(temp_path)
    return false, rename_error or "could not save WAV"
  end
  return true
end

local function tape_state()
  if audio.tape and audio.tape.get_state then
    return audio.tape.get_state().play
  end
end

local function tape_is_active(state)
  return state and
    (state.state == TAPE_PLAYING or state.state == TAPE_PAUSED)
end

local function wait_for_tape(test, attempts)
  for _ = 1, attempts do
    local state = tape_state()
    if state and test(state) then return true end
    clock.sleep(0.05)
  end
  return false
end

local function stop_tape()
  local state = tape_state()
  if not tape_is_active(state) then return true end
  audio.tape_play_stop()
  return wait_for_tape(function(current)
    return not tape_is_active(current)
  end, 60)
end

local function run_job(action)
  if busy then return end
  busy = true
  job_clock = clock.run(function()
    clock.sleep(0.01)
    local ok, err = pcall(action)
    busy = false
    job_clock = nil
    if not ok then
      print("speech: " .. err)
      set_status("error; see maiden")
    end
  end)
end

local function preview()
  local current = tape_state()
  if tape_is_active(current) and current.file == PREVIEW_NAME then
    run_job(function()
      set_status("stopping preview...")
      if stop_tape() then
        set_status("preview stopped")
      else
        set_status("tape stuck; restart norns")
      end
    end)
    return
  end

  run_job(function()
    set_status("rendering preview...")
    local ok, err = render_wav(PREVIEW_FILE, PREVIEW_TAIL_SECONDS)
    if not ok then
      set_status(err)
      return
    end

    set_status("starting preview...")
    if not stop_tape() then
      set_status("tape stuck; restart norns")
      return
    end

    audio.tape_play_open(PREVIEW_FILE)
    local ready = wait_for_tape(function(state)
      return state.file == PREVIEW_NAME and state.state == TAPE_READY
    end, 20)
    if not ready then
      set_status("tape did not open")
      return
    end

    audio.tape_play_start()
    local started = wait_for_tape(function(state)
      return state.file == PREVIEW_NAME and state.state == TAPE_PLAYING
    end, 20)
    if not started then
      set_status("tape did not start")
      return
    end

    -- crone chooses its loop default while opening, so set this after start.
    audio.tape_play_loop(false)
    set_status("playing once; K2 stops")
  end)
end

local function save_wav()
  run_job(function()
    local filename = output_filename()
    set_status("rendering " .. filename)
    local ok, err = render_wav(OUTPUT_DIR .. filename)
    if not ok then
      set_status(err)
      return
    end
    print("speech: saved " .. OUTPUT_DIR .. filename)
    set_status("saved " .. filename)
  end)
end

local function load_text_file(path)
  if path == "-" then return end
  local file, open_error = io.open(path, "rb")
  if not file then
    print("speech: " .. (open_error or "could not open text file"))
    set_status("could not open text file")
    return
  end

  local text, read_error = file:read("*a")
  file:close()
  if not text then
    print("speech: " .. (read_error or "could not read text file"))
    set_status("could not read text file")
    return
  end
  if text:find("\0", 1, true) then
    set_status("not a text file")
    return
  end

  text = text:gsub("^\239\187\191", "")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:match("^%s*$") then
    set_status("text file is empty")
    return
  end

  params:set(phrase_param_id(active_phrase_number()), text)
  set_status("loaded " .. (path:match("[^/]+$") or "text file"))
end

local function set_visible(ids, visible)
  for _, id in ipairs(ids) do
    if visible then params:show(id) else params:hide(id) end
  end
end

local function backend_changed(backend)
  if backend == 1 then
    controls = ESPEAK_CONTROLS
  elseif backend == 2 then
    controls = FLITE_CONTROLS
  else
    controls = PIPER_CONTROLS
  end
  selected_control = 1
  set_visible(ESPEAK_PARAM_IDS, backend == 1)
  set_visible(FLITE_PARAM_IDS, backend == 2)
  set_visible(PIPER_PARAM_IDS, backend == 3)
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end

  local unavailable = backend_error()
  if unavailable then
    status = unavailable
  else
    status = "K2 preview  K3 save"
  end
  redraw()
end

local function number_with_units(units)
  return function(param)
    return param:get() .. units
  end
end

local function add_params()
  params:add_group(PARAM_PREFIX .. "group", "SPEECH", 22)
  params:add_option(PARAM_PREFIX .. "backend", "backend", BACKENDS, 1)
  params:set_action(PARAM_PREFIX .. "backend", backend_changed)
  params:add_number(ACTIVE_PHRASE_PARAM, "phrase", 1, PHRASE_COUNT, 1)
  params:add_file(PARAM_PREFIX .. "text_file", "load text file")
  params:set_action(PARAM_PREFIX .. "text_file", load_text_file)
  params:set_save(PARAM_PREFIX .. "text_file", false)
  params:add_option(ESPEAK_VOICE_PARAM, "eSpeak voice", espeak_voices, 1)
  params:add_number(PARAM_PREFIX .. "speed", "speed", 80, 450, 120,
    number_with_units(" wpm"))
  params:add_number(PARAM_PREFIX .. "pitch", "pitch", 0, 99, 50)
  params:add_number(PARAM_PREFIX .. "range", "pitch range", 0, 99, 50)
  params:add_option(MONOTONE_PARAM, "monotone", { "off", "on" }, 1)
  params:add_number(NOTE_PARAM, "monotone note", 28, 76, 45,
    function(param) return musicutil.note_num_to_name(param:get(), true) end)
  params:add_number(PARAM_PREFIX .. "amplitude", "amplitude", 0, 200, 100)
  params:add_number(PARAM_PREFIX .. "word_gap", "word gap", 0, 100, 0,
    function(param) return (param:get() * 10) .. " ms" end)
  params:add_option(FLITE_VOICE_PARAM, "flite voice", flite_voices, 1)
  params:add_number(PARAM_PREFIX .. "flite_duration", "duration stretch",
    50, 300, 100,
    function(param) return string.format("%.2fx", param:get() / 100) end)
  params:add_number(PARAM_PREFIX .. "flite_pitch", "pitch shift",
    -12, 12, 0,
    function(param) return string.format("%+d st", param:get()) end)
  params:add_file(PIPER_MODEL_PARAM, "Piper model", DEFAULT_PIPER_MODEL)
  params:add_number(PARAM_PREFIX .. "piper_length", "length scale",
    50, 300, 100,
    function(param) return string.format("%.2fx", param:get() / 100) end)
  params:add_number(PARAM_PREFIX .. "piper_noise", "noise scale",
    0, 200, 67,
    function(param) return string.format("%.2f", param:get() / 100) end)
  params:add_number(PARAM_PREFIX .. "piper_noise_w", "noise width",
    0, 200, 80,
    function(param) return string.format("%.2f", param:get() / 100) end)
  params:add_text(PARAM_PREFIX .. "filename", "output name",
    "speech")
  params:add_trigger(PARAM_PREFIX .. "preview", "preview")
  params:set_action(PARAM_PREFIX .. "preview", preview)
  params:add_trigger(PARAM_PREFIX .. "save", "save WAV")
  params:set_action(PARAM_PREFIX .. "save", save_wav)
  params:add_trigger(PARAM_PREFIX .. "install", "install dependencies")
  params:set_action(PARAM_PREFIX .. "install", function()
    -- the params menu owns the screen; leave it so the installer is visible
    norns.menu.toggle(false)
    install_deps({ "sox", "espeak", "flite", "piper", "piper_voice" })
  end)

  params:add_group(PARAM_PREFIX .. "phrases_group", "PHRASES", PHRASE_COUNT)
  for i = 1, PHRASE_COUNT do
    local id = phrase_param_id(i)
    params:add_text(id, tostring(i), i == 1 and DEFAULT_PHRASE or "")
    local phrase_param = params:lookup_param(id)
    phrase_param.string = function(param)
      local preview = param:get():gsub("%s+", " ")
      return util.trim_string_to_width(preview, 116)
    end
  end

  backend_changed(params:get(PARAM_PREFIX .. "backend"))
end

local function phrase_lines(text)
  local lines = {}
  local line = ""
  local overflow = false

  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or line .. " " .. word
    if screen.text_extents(candidate) <= 126 then
      line = candidate
    elseif line ~= "" then
      table.insert(lines, line)
      line = word
      if #lines == 2 then
        overflow = true
        break
      end
    else
      table.insert(lines, util.trim_string_to_width(word, 126))
      line = ""
      if #lines == 2 then
        overflow = true
        break
      end
    end
  end

  if line ~= "" and #lines < 2 then table.insert(lines, line) end
  if #lines == 0 then lines[1] = "(empty phrase)" end
  if overflow then
    lines[2] = util.trim_string_to_width(lines[2] .. " ...", 126)
  end
  return lines
end

function init()
  util.make_dir(DATA_DIR)
  util.make_dir(OUTPUT_DIR)
  espeak_available = speech_deps:ok("espeak")
  flite_available = speech_deps:ok("flite")
  piper_available = speech_deps:ok("piper")
  sox_available = speech_deps:ok("sox")
  espeak_voices = discover_espeak_voices()
  flite_voices = discover_flite_voices()
  add_params()
  install_text_editor()
  redraw()
  -- offer to install what is needed to render anything at all
  local piper_voice_available = speech_deps:ok("piper_voice")
  local backend_available = espeak_available or flite_available
    or (piper_available and piper_voice_available)
  local missing = {}
  if not sox_available then missing[#missing + 1] = "sox" end
  if not backend_available then
    missing[#missing + 1] = piper_available and "piper_voice" or "espeak"
  end
  if #missing > 0 then
    install_deps(missing)
  end
end

function enc(n, delta)
  if n == 1 then
    params:delta(ACTIVE_PHRASE_PARAM, delta)
  elseif n == 2 then
    selected_control = util.clamp(
      selected_control + delta, 1, #controls)
  elseif n == 3 then
    params:delta(controls[selected_control].id, delta)
  end
  redraw()
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    preview()
  elseif n == 3 then
    save_wav()
  end
end

function redraw()
  screen.clear()
  screen.level(4)
  screen.move(0, 8)
  local backend = params and params.lookup[PARAM_PREFIX .. "backend"]
      and params:get(PARAM_PREFIX .. "backend") or 1
  local phrase_number = params and params.lookup[ACTIVE_PHRASE_PARAM]
      and active_phrase_number() or 1
  screen.text(string.format("SPEECH %d / %s", phrase_number,
    string.upper(BACKENDS[backend])))

  screen.level(15)
  local phrase = params and params.lookup[phrase_param_id(phrase_number)]
      and active_phrase() or DEFAULT_PHRASE
  for i, line in ipairs(phrase_lines(phrase)) do
    screen.move(0, 19 + (i - 1) * 10)
    screen.text(line)
  end

  local control = controls[selected_control]
  screen.level(8)
  screen.move(0, 46)
  screen.text(control.name)
  screen.move(127, 46)
  local value = params and params.lookup[control.id]
      and tostring(params:string(control.id)) or ""
  screen.text_right(value)

  screen.level(4)
  screen.move(0, 61)
  screen.text(util.trim_string_to_width(status, 127))
  screen.update()
end

function cleanup()
  text_editor.cleanup()
  if system_textentry.enter == custom_textentry_enter then
    system_textentry.enter = original_textentry_enter
  end
  if job_clock then clock.cancel(job_clock) end
  local tape = audio.tape and audio.tape.get_state
      and audio.tape.get_state() or nil
  if tape and tape.play.file == PREVIEW_NAME then
    audio.tape_play_stop()
  end
end
