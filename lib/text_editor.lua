local textentry_kbd = require "lib/textentry_kbd"

local editor = {}

local function current_text()
  return table.concat(editor.chars)
end

local function split_chars(text)
  local chars = {}
  local valid = pcall(function()
    for _, codepoint in utf8.codes(text) do
      chars[#chars + 1] = utf8.char(codepoint)
    end
  end)
  if not valid then
    chars = {}
    for i = 1, #text do chars[i] = text:sub(i, i) end
  end
  return chars
end

local function update()
  if editor.check then editor.warning = editor.check(current_text()) end
  editor.redraw()
end

local function insert_char(char)
  table.insert(editor.chars, editor.cursor + 1, char)
  editor.cursor = editor.cursor + 1
  update()
end

local function backspace()
  if editor.cursor == 0 then return end
  table.remove(editor.chars, editor.cursor)
  editor.cursor = editor.cursor - 1
  update()
end

local function delete_char()
  if editor.cursor >= #editor.chars then return end
  table.remove(editor.chars, editor.cursor + 1)
  update()
end

local function wrapped_lines()
  local lines = {}
  local line = { chars = {}, start = 0, finish = 0 }

  for i, char in ipairs(editor.chars) do
    if char == "\n" then
      line.finish = i - 1
      lines[#lines + 1] = line
      line = { chars = {}, start = i, finish = i }
    else
      local candidate = table.concat(line.chars) .. char
      if #line.chars > 0 and screen.text_extents(candidate) > 127 then
        local break_at
        for j = #line.chars, 1, -1 do
          if line.chars[j]:match("%s") then
            break_at = j
            break
          end
        end

        if break_at then
          local next_chars = {}
          for j = break_at + 1, #line.chars do
            next_chars[#next_chars + 1] = line.chars[j]
          end
          next_chars[#next_chars + 1] = char
          if screen.text_extents(table.concat(next_chars)) <= 127 then
            for j = #line.chars, break_at + 1, -1 do
              table.remove(line.chars, j)
            end
            line.finish = line.start + break_at
            lines[#lines + 1] = line
            line = {
              chars = next_chars,
              start = line.start + break_at,
              finish = i,
            }
          else
            break_at = nil
          end
        end

        if not break_at then
          line.finish = i - 1
          lines[#lines + 1] = line
          line = { chars = { char }, start = i - 1, finish = i }
        end
      else
        line.chars[#line.chars + 1] = char
        line.finish = i
      end
    end
  end

  lines[#lines + 1] = line
  return lines
end

local function visible_lines(max_lines)
  local lines = wrapped_lines()
  local focus = 1
  for i = #lines, 1, -1 do
    if editor.cursor >= lines[i].start
        and editor.cursor <= lines[i].finish then
      focus = i
      break
    end
  end

  local first = math.max(1, focus - max_lines + 1)
  local last = math.min(#lines, first + max_lines - 1)
  return lines, first, last, focus
end

local function draw_text(max_lines, first_y, spacing)
  local lines, first, last, focus = visible_lines(max_lines)
  for i = first, last do
    local y = first_y + (i - first) * spacing
    local line = lines[i]
    screen.level(15)
    screen.move(0, y)
    screen.text(table.concat(line.chars))

    if i == focus then
      local count = math.max(0, editor.cursor - line.start)
      local prefix = {}
      for j = 1, math.min(count, #line.chars) do
        prefix[j] = line.chars[j]
      end
      local width = screen.text_extents(table.concat(prefix))
      local x = math.min(127, width)
      screen.move(x, y - 7)
      screen.line(x, y + 1)
      screen.stroke()
    end
  end
end

local function restore()
  if not editor.active then return end
  editor.active = false
  textentry_kbd.code = editor.previous_keyboard_code
  textentry_kbd.char = editor.previous_keyboard_char

  if editor.menu_active then
    norns.menu.set(editor.enc_restore, editor.key_restore,
      editor.redraw_restore, editor.refresh_restore)
  else
    key = editor.key_restore
    enc = editor.enc_restore
    redraw = editor.redraw_restore
    refresh = editor.refresh_restore
    norns.menu.init()
  end

end

local function finish(accepted)
  if not editor.active then return end
  local callback = editor.callback
  local result = accepted and current_text() or nil
  restore()
  callback(result)
end

local function keyboard_connected()
  if not hid or not hid.devices then return false end
  for _, device in pairs(hid.devices) do
    if device.is_ascii_keyboard then return true end
  end
  return false
end

local function keyboard_code(code, value)
  if value == 0 then return end

  if code == "ESC" then
    finish(false)
  elseif code == "ENTER" then
    finish(true)
  elseif code == "BACKSPACE" then
    editor.keyboard_mode = true
    backspace()
  elseif code == "DELETE" then
    editor.keyboard_mode = true
    delete_char()
  elseif code == "LEFT" then
    editor.keyboard_mode = true
    editor.cursor = math.max(0, editor.cursor - 1)
    editor.redraw()
  elseif code == "RIGHT" then
    editor.keyboard_mode = true
    editor.cursor = math.min(#editor.chars, editor.cursor + 1)
    editor.redraw()
  elseif code == "HOME" then
    editor.keyboard_mode = true
    editor.cursor = 0
    editor.redraw()
  elseif code == "END" then
    editor.keyboard_mode = true
    editor.cursor = #editor.chars
    editor.redraw()
  end
end

local function keyboard_char(char)
  editor.keyboard_mode = true
  insert_char(char)
end

function editor.enter(callback, default, heading, check)
  editor.callback = callback
  editor.chars = split_chars(default or "")
  editor.cursor = #editor.chars
  editor.heading = heading or ""
  editor.check = check
  editor.warning = check and check(current_text()) or nil
  editor.picker_pos = 28
  editor.row = 0
  editor.delete_selected = false
  editor.pending = false
  editor.keyboard_mode = keyboard_connected()
  editor.active = true

  editor.previous_keyboard_code = textentry_kbd.code
  editor.previous_keyboard_char = textentry_kbd.char
  textentry_kbd.code = keyboard_code
  textentry_kbd.char = keyboard_char

  editor.menu_active = norns.menu.status()
  if editor.menu_active then
    editor.key_restore = norns.menu.get_key()
    editor.enc_restore = norns.menu.get_enc()
    editor.redraw_restore = norns.menu.get_redraw()
    editor.refresh_restore = norns.menu.get_refresh()
    norns.menu.set(editor.enc, editor.key, editor.redraw, editor.refresh)
  else
    editor.key_restore = key
    editor.enc_restore = enc
    editor.redraw_restore = redraw
    editor.refresh_restore = refresh
    key = editor.key
    enc = editor.enc
    redraw = norns.none
    refresh = norns.none
    norns.menu.init()
  end
  editor.redraw()
end

function editor.key(n, z)
  if editor.keyboard_mode then
    if n == 2 and z == 0 then
      finish(false)
    elseif n == 3 and z == 1 then
      editor.pending = true
    elseif n == 3 and z == 0 and editor.pending then
      editor.pending = false
      finish(true)
    end
    return
  end

  if n == 2 and z == 0 then
    finish(false)
  elseif n == 3 and z == 1 then
    if editor.row == 0 then
      insert_char(utf8.char(((5 + editor.picker_pos) % 95) + 32))
    elseif editor.delete_selected then
      backspace()
    else
      editor.pending = true
    end
  elseif n == 3 and z == 0 and editor.pending then
    editor.pending = false
    finish(true)
  end
end

function editor.enc(n, delta)
  editor.keyboard_mode = false
  if n == 2 then
    if editor.row == 0 then
      editor.picker_pos = (editor.picker_pos + delta) % 95
    else
      editor.delete_selected = delta < 0
    end
  elseif n == 3 then
    editor.row = delta > 0 and 1 or 0
  end
  editor.redraw()
end

function editor.redraw()
  screen.clear()
  screen.level(8)
  screen.move(0, 7)
  screen.text(util.trim_string_to_width(editor.heading, 127))

  if editor.keyboard_mode then
    draw_text(5, 16, 11)
  else
    draw_text(3, 17, 10)
    for x = 0, 15 do
      screen.level(x == 5 and editor.row == 0 and 15 or 2)
      screen.move(x * 8, 49)
      screen.text(utf8.char((x + editor.picker_pos) % 95 + 32))
    end

    screen.level(editor.row == 1 and editor.delete_selected and 15 or 2)
    screen.move(0, 62)
    screen.text("DEL")
    screen.level(editor.row == 1 and not editor.delete_selected and 15 or 2)
    screen.move(127, 62)
    screen.text_right("OK")
  end
  screen.update()
end

function editor.refresh()
  editor.redraw()
end

function editor.cleanup()
  restore()
end

return editor
