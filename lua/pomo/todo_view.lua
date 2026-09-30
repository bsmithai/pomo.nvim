---A floating window showing a day's todo list, a color-coded timeline of the pomodoros taken for each
---item, and a summary of time spent and gaps.
local todo = require "pomo.todo"
local log = require "pomo.log"

local M = {}

local ns = vim.api.nvim_create_namespace "pomo_todo_view"

---@class pomo.TodoViewState
---@field buf integer
---@field win integer
---@field date string
---@field rows table<integer, integer> 1-based buffer row -> todo ID
---@field refresh uv_timer_t|?
---@field focus_todo integer|? Put the cursor on this todo after the next render.

---@type pomo.TodoViewState|?
local state

---@return pomo.TodoConfig
local function get_config()
  return require("pomo").get_config().todo
end

---@param secs integer
---@return string
local function fmt_dur(secs)
  if secs <= 0 then
    return "0m"
  elseif secs < 60 then
    return "<1m"
  end
  local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dm", m)
end

---@param t integer
---@return string
local function fmt_clock(t)
  return os.date("%H:%M", t) ---@diagnostic disable-line: return-type-mismatch
end

---@param secs number
---@return string
local function fmt_countdown(secs)
  secs = math.floor(secs)
  if secs >= 3600 then
    return string.format("%d:%02d:%02d", math.floor(secs / 3600), math.floor((secs % 3600) / 60), secs % 60)
  end
  return string.format("%02d:%02d", math.floor(secs / 60), secs % 60)
end

---Pad or truncate a string to an exact display width.
---@param s string
---@param width integer
---@param align_right boolean|?
---@return string
local function fit(s, width, align_right)
  if vim.fn.strdisplaywidth(s) > width then
    s = vim.fn.strcharpart(s, 0, math.max(width - 1, 0)) .. "…"
    while vim.fn.strdisplaywidth(s) > width do
      s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 2) .. "…"
    end
  end
  local pad = string.rep(" ", width - vim.fn.strdisplaywidth(s))
  return align_right and (pad .. s) or (s .. pad)
end

local function setup_highlights()
  local links = {
    PomoTitle = "Title",
    PomoSection = "Special",
    PomoLabel = "Label",
    PomoMuted = "Comment",
    PomoGap = "NonText",
    PomoNow = "DiagnosticError",
    PomoRunning = "DiagnosticOk",
    PomoPaused = "DiagnosticWarn",
    PomoDone = "Comment",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  for i, color in ipairs(get_config().colors) do
    vim.api.nvim_set_hl(0, "PomoTodo" .. i, { fg = color, default = true })
  end
end

---@param t pomo.Todo|?
---@return string
local function todo_hl(t)
  return t and ("PomoTodo" .. t.color) or "PomoMuted"
end

---Accumulates lines along with their highlights.
---@class pomo.LineBuilder
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, hl: string }[]
---@field rows table<integer, integer>
local Builder = {}
Builder.__index = Builder

---@return pomo.LineBuilder
Builder.new = function()
  return setmetatable({ lines = {}, marks = {}, rows = {} }, Builder)
end

---@param chunks (string|{ [1]: string, [2]: string|? })[]
---@param todo_id integer|? Associate the line with a todo for the keymaps.
Builder.add = function(self, chunks, todo_id)
  local text = ""
  for _, chunk in ipairs(chunks) do
    if type(chunk) == "string" then
      chunk = { chunk }
    end
    if chunk[2] ~= nil and #chunk[1] > 0 then
      self.marks[#self.marks + 1] = { row = #self.lines, col = #text, end_col = #text + #chunk[1], hl = chunk[2] }
    end
    text = text .. chunk[1]
  end
  self.lines[#self.lines + 1] = text
  if todo_id ~= nil then
    self.rows[#self.lines] = todo_id
  end
end

Builder.blank = function(self)
  self:add {}
end

---@param width integer
Builder.separator = function(self, width)
  self:blank()
  self:add { { "  " .. string.rep("─", width - 4), "PomoGap" } }
  self:blank()
end

---@param b pomo.LineBuilder
---@param day pomo.Day
---@param stats pomo.DayStats
---@param width integer
local function render_tasks(b, day, stats, width)
  b:add { { "  Tasks", "PomoSection" } }
  b:blank()

  local todos = todo.visible_todos(day)
  if #todos == 0 then
    b:add { { "    No tasks yet, press 'a' to add one", "PomoMuted" } }
    return
  end

  local right_width = 30
  local title_width = math.max(width - 8 - right_width, 10)
  for _, t in ipairs(todos) do
    local chunks = {
      "    ",
      { "●", todo_hl(t) },
      " ",
      t.done and { "✔", "PomoRunning" } or { "☐", "PomoMuted" },
      " ",
      { fit(t.title, title_width), t.done and "PomoDone" or nil },
    }

    local timer = todo.get_timer(day.date, t.id)
    if timer ~= nil then
      local left = fmt_countdown(timer:time_remaining() or timer.time_limit)
      if timer.paused then
        chunks[#chunks + 1] = { fit("⏸ " .. left, 11, true), "PomoPaused" }
      else
        chunks[#chunks + 1] = { fit("▶ " .. left, 11, true), "PomoRunning" }
      end
    else
      chunks[#chunks + 1] = string.rep(" ", 11)
    end

    local secs = stats.per_todo[t.id] or 0
    chunks[#chunks + 1] = { fit(secs > 0 and fmt_dur(secs) or "–", 9, true), secs > 0 and "PomoLabel" or "PomoMuted" }

    local pomos = stats.pomos[t.id] or 0
    if pomos > 0 then
      local dots = string.rep("●", math.min(pomos, 6)) .. (pomos > 6 and "+" or "")
      chunks[#chunks + 1] = "  "
      chunks[#chunks + 1] = { dots, todo_hl(t) }
    end

    b:add(chunks, t.id)
  end
end

---@param b pomo.LineBuilder
---@param day pomo.Day
---@param stats pomo.DayStats
---@param width integer
local function render_timeline(b, day, stats, width)
  local cfg = get_config()
  local now = todo.now()
  local is_today = day.date == todo.today()
  local midnight = todo.time_at(day.date, 0)

  local function hour_of(t)
    return math.floor((t - midnight) / 3600)
  end

  local start_h, end_h = cfg.start_hour, cfg.end_hour
  if stats.first ~= nil then
    start_h = math.min(start_h, hour_of(stats.first))
    end_h = math.max(end_h, hour_of(stats.last - 1) + 1)
  end
  if is_today then
    end_h = math.max(end_h, hour_of(now) + 1)
  end
  start_h, end_h = math.max(start_h, 0), math.min(end_h, 48)

  -- One cell per minute if there's room, otherwise coarser.
  local n_cells = 12
  for _, n in ipairs { 60, 30, 20 } do
    if width - 18 >= n then
      n_cells = n
      break
    end
  end
  local cell_secs = 3600 / n_cells

  -- Header with quarter-hour tick labels.
  local header = vim.split(string.rep(" ", n_cells), "")
  for q = 0, 3 do
    local label = string.format(":%02d", q * 15)
    for i = 1, #label do
      header[math.floor(q * n_cells / 4) + i] = label:sub(i, i)
    end
  end
  b:add { { "  Timeline", "PomoSection" } }
  b:blank()
  b:add { "       ", { table.concat(header), "PomoMuted" } }

  local by_id = {}
  for _, t in ipairs(day.todos) do
    by_id[t.id] = t
  end

  for h = start_h, end_h - 1 do
    local row_start = todo.time_at(day.date, h)
    local cells = todo.timeline(day, row_start, n_cells, cell_secs)

    local chunks = { "  ", { string.format("%02d", h % 24), "PomoLabel" }, " ", { "│", "PomoGap" } }
    local covered = 0
    local run_text, run_hl = "", nil
    local function flush()
      if #run_text > 0 then
        chunks[#chunks + 1] = { run_text, run_hl }
      end
      run_text, run_hl = "", nil
    end

    for i, todo_id in ipairs(cells) do
      local c_start = row_start + (i - 1) * cell_secs
      local ch, hl
      if todo_id then
        covered = covered + 1
        ch, hl = "█", todo_hl(by_id[todo_id])
      elseif is_today and now >= c_start and now < c_start + cell_secs then
        ch, hl = "│", "PomoNow"
      elseif is_today and c_start > now then
        ch, hl = " ", nil
      else
        ch, hl = "·", "PomoGap"
      end
      if hl ~= run_hl then
        flush()
        run_hl = hl
      end
      run_text = run_text .. ch
    end
    flush()

    chunks[#chunks + 1] = { "│", "PomoGap" }
    if covered > 0 then
      chunks[#chunks + 1] = { fit(fmt_dur(covered * cell_secs), 8, true), "PomoMuted" }
    end
    b:add(chunks)
  end
end

---@param b pomo.LineBuilder
---@param day pomo.Day
---@param stats pomo.DayStats
local function render_summary(b, day, stats)
  b:add { { "  Summary", "PomoSection" } }
  b:blank()

  if stats.first == nil then
    b:add { { "    No pomodoros logged yet", "PomoMuted" } }
    return
  end

  local pomos = 0
  for _, n in pairs(stats.pomos) do
    pomos = pomos + n
  end

  b:add {
    { "    Focused   ", "PomoLabel" },
    { fit(fmt_dur(stats.focus), 8), "PomoRunning" },
    { string.format("%d pomodoro%s completed", pomos, pomos == 1 and "" or "s"), "PomoMuted" },
  }
  b:add {
    { "    Span      ", "PomoLabel" },
    fit(fmt_dur(stats.last - stats.first), 8),
    { string.format("%s – %s", fmt_clock(stats.first), fmt_clock(stats.last)), "PomoMuted" },
  }

  local min_gap = get_config().min_gap * 60
  local big_gaps = vim.tbl_filter(function(g)
    return g.stop - g.start >= min_gap
  end, stats.gaps)
  b:add {
    { "    Gaps      ", "PomoLabel" },
    { fit(fmt_dur(stats.gap_total), 8), stats.gap_total > 0 and "PomoPaused" or nil },
    {
      #big_gaps > 0 and string.format("%d longer than %dm", #big_gaps, get_config().min_gap) or "",
      "PomoMuted",
    },
  }
  for _, g in ipairs(big_gaps) do
    b:add {
      "              ",
      { fit(fmt_dur(g.stop - g.start), 8), "PomoPaused" },
      { string.format("%s – %s", fmt_clock(g.start), fmt_clock(g.stop)), "PomoMuted" },
    }
  end

  if day.date == todo.today() and not todo.has_active(day.date) then
    b:add {
      { "    Idle      ", "PomoLabel" },
      fit(fmt_dur(todo.now() - stats.last), 8),
      { "since the last session", "PomoMuted" },
    }
  end
end

local STATUS_ICONS = {
  running = { "▶ running", "PomoRunning" },
  done = { "✔ done", "PomoRunning" },
  stopped = { "■ stopped", "PomoMuted" },
  paused = { "⏸ paused", "PomoPaused" },
}

---@param b pomo.LineBuilder
---@param day pomo.Day
---@param width integer
local function render_sessions(b, day, width)
  if #day.sessions == 0 then
    return
  end
  b:add { { "  Sessions", "PomoSection" } }
  b:blank()

  local sessions = vim.deepcopy(day.sessions)
  table.sort(sessions, function(a, c)
    return a.start < c.start
  end)

  local title_width = math.max(width - 50, 10)
  for _, s in ipairs(sessions) do
    local t = todo.get_todo(day, s.todo_id)
    local title = t and t.title or "(unknown)"
    if t and t.deleted then
      title = title .. " (deleted)"
    end
    local status = STATUS_ICONS[s.status] or STATUS_ICONS.stopped
    if s.status == "running" and not todo.get_timer(day.date, s.todo_id) then
      -- Neovim exited without closing the session.
      status = STATUS_ICONS.stopped
    end
    b:add({
      "    ",
      { string.format("%s – %s", fmt_clock(s.start), fmt_clock(s.stop)), "PomoMuted" },
      "   ",
      { "●", todo_hl(t) },
      " ",
      fit(title, title_width),
      { fit(fmt_dur(s.stop - s.start), 8, true), "PomoLabel" },
      "   ",
      status,
    }, t and not t.deleted and t.id or nil)
  end
end

---@return integer width, integer height, integer row, integer col
local function get_dimensions(n_lines)
  local cols, lines = vim.o.columns, vim.o.lines
  local width = math.min(100, math.floor(cols * 0.9))
  local height = math.min(n_lines, math.floor(lines * 0.85))
  return width, height, math.floor((lines - height) / 2) - 1, math.floor((cols - width) / 2)
end

---@param date string
---@return string
local function window_title(date)
  local label = os.date("%A, %B %d %Y", todo.time_at(date, 12))
  if date == todo.today() then
    label = label .. " · today"
  end
  return " " .. label .. " "
end

local function render()
  if state == nil or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  setup_highlights()

  local day = todo.load(state.date)
  local stats = todo.stats(day)
  local width = get_dimensions(0)

  local b = Builder.new()
  b:blank()
  render_tasks(b, day, stats, width)
  b:separator(width)
  render_timeline(b, day, stats, width)
  b:separator(width)
  render_summary(b, day, stats)
  if #day.sessions > 0 then
    b:separator(width)
    render_sessions(b, day, width)
  end
  b:blank()
  b:blank()
  b:add {
    { "  a add · r rename · x done · d delete · J/K move · <CR>/s start · S start for… · p pause · X stop", "PomoMuted" },
  }
  b:add { { "  [ / ] prev/next day · t today · q close", "PomoMuted" } }

  -- Figure out where the cursor should go.
  local cursor_row
  if vim.api.nvim_win_is_valid(state.win) then
    cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
  end
  local focus = state.focus_todo
  state.focus_todo = nil

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, b.lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, m in ipairs(b.marks) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
  state.rows = b.rows

  if vim.api.nvim_win_is_valid(state.win) then
    local w, h, row, col = get_dimensions(#b.lines)
    vim.api.nvim_win_set_config(state.win, {
      relative = "editor",
      width = w,
      height = h,
      row = row,
      col = col,
      title = window_title(state.date),
      title_pos = "center",
    })

    -- Jump to the todo's row in the task list (it may also appear further down in the sessions list).
    local target = cursor_row
    if focus ~= nil then
      for r, id in pairs(b.rows) do
        if id == focus and (target == cursor_row or r < target) then
          target = r
        end
      end
    end
    target = math.max(1, math.min(target or 2, #b.lines))
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
  end
end

---@return integer|?
local function todo_under_cursor()
  if state == nil then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.rows[row]
end

---@param fn fun(day: pomo.Day, todo_id: integer)
---@return fun()
local function with_todo(fn)
  return function()
    local todo_id = todo_under_cursor()
    if todo_id == nil then
      return log.warn "no task under the cursor"
    end
    fn(todo.load(state.date), todo_id)
    render()
  end
end

---@return boolean
local function require_today()
  if state.date ~= todo.today() then
    log.warn "pomodoros can only be started from today's list, press 't' to jump to today"
    return false
  end
  return true
end

local function close()
  if state == nil then
    return
  end
  local current = state
  state = nil
  if current.refresh ~= nil and not current.refresh:is_closing() then
    current.refresh:close()
  end
  if vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_win_close(current.win, true)
  end
end

---@param date string
local function set_date(date)
  state.date = date
  todo.load(date, { refresh = true })
  state.focus_todo = nil
  render()
  local rows = vim.tbl_keys(state.rows)
  table.sort(rows)
  vim.api.nvim_win_set_cursor(state.win, { rows[1] or 2, 0 })
end

local function set_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = "pomo: " .. desc })
  end

  map("q", close, "close")
  map("<Esc>", close, "close")

  map("a", function()
    vim.ui.input({ prompt = "New task: " }, function(title)
      if title ~= nil and vim.trim(title) ~= "" then
        state.focus_todo = todo.add(todo.load(state.date), vim.trim(title)).id
        render()
      end
    end)
  end, "add task")

  map(
    "r",
    with_todo(function(day, todo_id)
      local t = assert(todo.get_todo(day, todo_id))
      vim.ui.input({ prompt = "Rename task: ", default = t.title }, function(title)
        if title ~= nil and vim.trim(title) ~= "" then
          todo.rename(day, todo_id, vim.trim(title))
          render()
        end
      end)
    end),
    "rename task"
  )

  map(
    "x",
    with_todo(function(day, todo_id)
      todo.toggle(day, todo_id)
    end),
    "toggle done"
  )

  map(
    "d",
    with_todo(function(day, todo_id)
      local t = assert(todo.get_todo(day, todo_id))
      if vim.fn.confirm(string.format("Delete '%s'?", t.title), "&Yes\n&No", 2) == 1 then
        todo.remove(day, todo_id)
      end
    end),
    "delete task"
  )

  map(
    "J",
    with_todo(function(day, todo_id)
      todo.move(day, todo_id, 1)
      state.focus_todo = todo_id
    end),
    "move task down"
  )
  map(
    "K",
    with_todo(function(day, todo_id)
      todo.move(day, todo_id, -1)
      state.focus_todo = todo_id
    end),
    "move task up"
  )

  local start = with_todo(function(day, todo_id)
    if todo.get_timer(day.date, todo_id) ~= nil then
      todo.toggle_pause(day.date, todo_id)
    elseif require_today() then
      todo.start(todo_id)
    end
  end)
  map("<CR>", start, "start / pause pomodoro")
  map("s", start, "start / pause pomodoro")

  map(
    "S",
    with_todo(function(day, todo_id)
      if not require_today() then
        return
      end
      vim.ui.input({ prompt = "Duration: ", default = get_config().duration }, function(input)
        if input == nil or input == "" then
          return
        end
        local time_limit = require("pomo.util").parse_time(input)
        if time_limit == nil then
          return log.error("invalid time limit '%s'", input)
        end
        todo.start(todo_id, time_limit)
        render()
      end)
      state.focus_todo = todo_id
    end),
    "start pomodoro with custom duration"
  )

  map(
    "p",
    with_todo(function(day, todo_id)
      if not todo.toggle_pause(day.date, todo_id) then
        log.warn "no timer running for this task"
      end
    end),
    "pause / resume pomodoro"
  )

  map(
    "X",
    with_todo(function(day, todo_id)
      if not todo.stop(day.date, todo_id) then
        log.warn "no timer running for this task"
      end
    end),
    "stop pomodoro"
  )

  map("[", function()
    set_date(todo.shift_date(state.date, -1))
  end, "previous day")
  map("]", function()
    set_date(todo.shift_date(state.date, 1))
  end, "next day")
  map("t", function()
    set_date(todo.today())
  end, "today")
  map("R", function()
    todo.load(state.date, { refresh = true })
    render()
  end, "refresh")
end

---Open the day view.
---@param date string|? YYYY-MM-DD, defaults to today.
M.open = function(date)
  date = date or todo.today()

  if state ~= nil and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    set_date(date)
    return
  end
  close()

  todo.load(date, { refresh = true })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pomo-day"

  local width, height, row, col = get_dimensions(10)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = window_title(date),
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  state = { buf = buf, win = win, date = date, rows = {} }
  set_keymaps(buf)

  local group = vim.api.nvim_create_augroup("PomoTodoView", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", { group = group, buffer = buf, callback = render })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if state ~= nil and state.buf == buf then
        if state.refresh ~= nil and not state.refresh:is_closing() then
          state.refresh:close()
        end
        state = nil
      end
    end,
  })

  -- Keep countdowns and the timeline live.
  state.refresh = vim.loop.new_timer() ---@diagnostic disable-line: undefined-field
  state.refresh:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if state ~= nil and state.date == todo.today() then
        render()
      end
    end)
  )

  set_date(date)
end

M.close = close

return M
