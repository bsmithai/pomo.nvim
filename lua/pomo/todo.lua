---Daily todo lists with pomodoro time tracking.
---
---Each day is stored as a JSON file in `todo.data_dir` (see `pomo.TodoConfig`) holding that day's todo
---items and a log of every pomodoro session (a contiguous stretch of wall-clock time spent on an item).
---Pausing a timer ends the current session and resuming it starts a new one, so pauses show up as gaps.
local M = {}

---@class pomo.Todo
---@field id integer
---@field title string
---@field done boolean
---@field deleted boolean|? Deleted todos are hidden, but their sessions are kept in the day's log.
---@field color integer Index into `todo.colors`.

---@alias pomo.TodoSessionStatus "running"|"done"|"stopped"|"paused"

---@class pomo.TodoSession
---@field todo_id integer
---@field start integer Unix timestamp (seconds).
---@field stop integer Unix timestamp (seconds). Kept up to date while the session is running.
---@field status pomo.TodoSessionStatus How the session ended.

---@class pomo.Day
---@field date string YYYY-MM-DD
---@field next_id integer
---@field todos pomo.Todo[]
---@field sessions pomo.TodoSession[]

---How often (in seconds) a running session's end time is flushed to disk.
local SAVE_INTERVAL = 30

---@type table<string, pomo.Day>
local days = {}

---Active timers keyed by "<date>:<todo_id>".
---@type table<string, { timer: pomo.Timer, tracker: table }>
local active = {}

---Let listeners (like the Slack integration) know that the set of running todo sessions changed.
local function emit_changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "PomoTodoChanged", modeline = false })
end

---@param date string
---@param todo_id integer
---@return string
local function active_key(date, todo_id)
  return date .. ":" .. todo_id
end

---@return pomo.TodoConfig
local function get_config()
  local ok, pomo = pcall(require, "pomo")
  if ok and pomo._config ~= nil then
    return pomo._config.todo
  end
  return require("pomo.config").default().todo
end

---Get the current Unix timestamp in seconds. Overridable for tests.
---@return integer
M.now = function()
  return os.time()
end

---@param t integer|?
---@return string
M.date_of = function(t)
  return os.date("%Y-%m-%d", t or M.now()) ---@diagnostic disable-line: return-type-mismatch
end

---@return string
M.today = function()
  return M.date_of()
end

---@param date string
---@return boolean
M.is_valid_date = function(date)
  return type(date) == "string" and date:match "^%d%d%d%d%-%d%d%-%d%d$" ~= nil
end

---Get the Unix timestamp for a given hour on a given date (in local time).
---@param date string
---@param hour integer|? Can be >= 24 to refer to the following day.
---@return integer
M.time_at = function(date, hour)
  local y, m, d = date:match "^(%d+)-(%d+)-(%d+)$"
  return os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = hour or 0 } ---@diagnostic disable-line: missing-fields
end

---@param date string
---@param delta integer days
---@return string
M.shift_date = function(date, delta)
  local y, m, d = date:match "^(%d+)-(%d+)-(%d+)$"
  ---@diagnostic disable-next-line: missing-fields
  return M.date_of(os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d) + delta, hour = 12 })
end

---@return string
local function days_dir()
  return get_config().data_dir .. "/days"
end

---@param date string
---@return string
local function day_path(date)
  return days_dir() .. "/" .. date .. ".json"
end

---List the dates that have a saved day file, sorted oldest first.
---@return string[]
M.list_dates = function()
  local dates = {}
  for _, path in ipairs(vim.fn.glob(days_dir() .. "/*.json", false, true)) do
    local date = vim.fn.fnamemodify(path, ":t:r")
    if M.is_valid_date(date) then
      dates[#dates + 1] = date
    end
  end
  table.sort(dates)
  return dates
end

---@param date string
---@return pomo.Day
local function new_day(date)
  return { date = date, next_id = 1, todos = {}, sessions = {} }
end

---@param date string
---@return pomo.Day|?
local function read_day(date)
  local path = day_path(date)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    require("pomo.log").error("failed to read pomo day file '%s'", path)
    return nil
  end
  local day = new_day(date)
  day.next_id = data.next_id or 1
  day.todos = data.todos or {}
  day.sessions = data.sessions or {}
  return day
end

---@param day pomo.Day
---@param date string
local function carry_over(day, date)
  local previous
  for _, d in ipairs(M.list_dates()) do
    if d < date then
      previous = d
    end
  end
  if previous == nil then
    return
  end

  local prev_day = M.load(previous)
  for _, todo in ipairs(prev_day.todos) do
    if not todo.done and not todo.deleted then
      day.todos[#day.todos + 1] = { id = day.next_id, title = todo.title, done = false, color = todo.color }
      day.next_id = day.next_id + 1
    end
  end
end

---Check if a day currently has any running timers attached to its todos.
---@param date string
---@return boolean
M.has_active = function(date)
  for key, _ in pairs(active) do
    if vim.startswith(key, date .. ":") then
      return true
    end
  end
  return false
end

---Load a day. Today's list is created (carrying over unfinished items if configured) the first time it's loaded.
---@param date string|?
---@param opts { refresh: boolean|? }|? With `refresh`, re-read from disk unless the day has running timers.
---@return pomo.Day
M.load = function(date, opts)
  date = date or M.today()
  opts = opts or {}

  if days[date] ~= nil and not (opts.refresh and not M.has_active(date)) then
    return days[date]
  end

  local day = read_day(date)
  if day == nil then
    day = new_day(date)
    if date == M.today() and get_config().carry_over then
      carry_over(day, date)
      if #day.todos > 0 then
        M.save(day)
      end
    end
  end

  days[date] = day
  return day
end

---@param day pomo.Day
M.save = function(day)
  vim.fn.mkdir(days_dir(), "p")
  local data = {
    date = day.date,
    next_id = day.next_id,
    todos = #day.todos > 0 and day.todos or vim.empty_dict(),
    sessions = #day.sessions > 0 and day.sessions or vim.empty_dict(),
  }
  vim.fn.writefile({ vim.json.encode(data) }, day_path(day.date))
end

---Forget all loaded days. Mostly useful for tests.
M._reset = function()
  days = {}
  active = {}
end

---@param day pomo.Day
---@param todo_id integer
---@return pomo.Todo|?
M.get_todo = function(day, todo_id)
  for _, todo in ipairs(day.todos) do
    if todo.id == todo_id then
      return todo
    end
  end
end

---Get the todos that haven't been deleted.
---@param day pomo.Day
---@return pomo.Todo[]
M.visible_todos = function(day)
  return vim.tbl_filter(function(t)
    return not t.deleted
  end, day.todos)
end

---@param day pomo.Day
---@param title string
---@return pomo.Todo
M.add = function(day, title)
  local todo = {
    id = day.next_id,
    title = title,
    done = false,
    color = (day.next_id - 1) % #get_config().colors + 1,
  }
  day.next_id = day.next_id + 1
  day.todos[#day.todos + 1] = todo
  M.save(day)
  return todo
end

---@param day pomo.Day
---@param todo_id integer
M.toggle = function(day, todo_id)
  local todo = assert(M.get_todo(day, todo_id))
  todo.done = not todo.done
  M.save(day)
end

---@param day pomo.Day
---@param todo_id integer
---@param title string
M.rename = function(day, todo_id, title)
  local todo = assert(M.get_todo(day, todo_id))
  todo.title = title
  M.save(day)
  emit_changed()
end

---Delete a todo. If it has any sessions logged it's only hidden so the time log stays intact.
---@param day pomo.Day
---@param todo_id integer
M.remove = function(day, todo_id)
  M.stop(day.date, todo_id)
  for i, todo in ipairs(day.todos) do
    if todo.id == todo_id then
      local has_sessions = false
      for _, s in ipairs(day.sessions) do
        has_sessions = has_sessions or s.todo_id == todo_id
      end
      if has_sessions then
        todo.deleted = true
      else
        table.remove(day.todos, i)
      end
      break
    end
  end
  M.save(day)
end

---Move a todo up (-1) or down (+1) among the visible todos.
---@param day pomo.Day
---@param todo_id integer
---@param delta integer
M.move = function(day, todo_id, delta)
  local visible = {}
  for i, todo in ipairs(day.todos) do
    if not todo.deleted then
      visible[#visible + 1] = i
    end
  end
  for vi, i in ipairs(visible) do
    if day.todos[i].id == todo_id then
      local j = visible[vi + delta]
      if j ~= nil then
        day.todos[i], day.todos[j] = day.todos[j], day.todos[i]
        M.save(day)
      end
      return
    end
  end
end

---Build a notifier that logs a timer's running time as sessions for a todo.
---@param date string
---@param todo_id integer
---@return fun(timer: pomo.Timer): table
local function tracker(date, todo_id)
  return function(timer)
    local self = { timer = timer }
    ---@type pomo.TodoSession|?
    local session
    local last_save = 0

    local function open()
      local day = M.load(date)
      local t = M.now()
      session = { todo_id = todo_id, start = t, stop = t, status = "running" }
      day.sessions[#day.sessions + 1] = session
      last_save = t
      M.save(day)
      emit_changed()
    end

    ---@param status pomo.TodoSessionStatus
    local function close(status)
      if session ~= nil then
        session.stop = M.now()
        session.status = status
        session = nil
        M.save(M.load(date))
        emit_changed()
      end
    end

    self.start = function()
      open()
    end
    self.resume = function()
      open()
    end
    self.tick = function()
      if session ~= nil then
        session.stop = M.now()
        if session.stop - last_save >= SAVE_INTERVAL then
          last_save = session.stop
          M.save(M.load(date))
        end
      end
    end
    self.done = function()
      close "done"
    end
    self.pause = function()
      close "paused"
    end
    self.stop = function()
      active[active_key(date, todo_id)] = nil
      close "stopped"
    end
    self._close = close
    ---@return pomo.TodoSession|?
    self.session = function()
      return session
    end

    return self
  end
end

---Get the running timer for a todo, if there is one.
---@param date string
---@param todo_id integer
---@return pomo.Timer|?
M.get_timer = function(date, todo_id)
  local entry = active[active_key(date, todo_id)]
  return entry and entry.timer or nil
end

---Get the todo that's actively being worked on, i.e. the one with the most recently started session among
---the running, unpaused timers.
---@return { date: string, todo: pomo.Todo, timer: pomo.Timer, session: pomo.TodoSession }|?
M.current = function()
  local best
  for key, entry in pairs(active) do
    local session = entry.tracker.session()
    if session ~= nil and (best == nil or session.start >= best.session.start) then
      local date, todo_id = key:match "^(.+):(%d+)$"
      local t = M.get_todo(M.load(date), tonumber(todo_id) --[[@as integer]])
      if t ~= nil then
        best = { date = date, todo = t, timer = entry.timer, session = session }
      end
    end
  end
  return best
end

---Start a pomodoro for a todo on today's list.
---@param todo_id integer
---@param time_limit integer|? seconds, defaults to `todo.duration`.
---@return pomo.Timer|?
M.start = function(todo_id, time_limit)
  local pomo = require "pomo"
  local log = require "pomo.log"

  local date = M.today()
  local day = M.load(date)
  local todo = M.get_todo(day, todo_id)
  if todo == nil then
    log.error("no todo with ID %d today", todo_id)
    return
  end
  if M.get_timer(date, todo_id) ~= nil then
    log.warn("'%s' already has a timer running", todo.title)
    return
  end

  time_limit = time_limit or require("pomo.util").parse_time(get_config().duration)
  local key = active_key(date, todo_id)
  local init = tracker(date, todo_id)
  local timer = pomo.start_timer(assert(time_limit), {
    name = todo.title,
    notifiers = {
      function(t)
        local tr = init(t)
        active[key] = { timer = t, tracker = tr }
        return tr
      end,
    },
    timer_done = function()
      active[key] = nil
    end,
  })
  return timer
end

---Stop the running timer for a todo.
---@param date string
---@param todo_id integer
---@return boolean stopped
M.stop = function(date, todo_id)
  local timer = M.get_timer(date, todo_id)
  if timer == nil then
    return false
  end
  return require("pomo").stop_timer(timer)
end

---Pause or resume the running timer for a todo.
---@param date string
---@param todo_id integer
---@return boolean toggled
M.toggle_pause = function(date, todo_id)
  local timer = M.get_timer(date, todo_id)
  if timer == nil then
    return false
  end
  if timer.paused then
    timer:resume()
  else
    timer:pause()
  end
  return true
end

---Close out any running sessions, e.g. when Neovim exits.
M.close_all = function()
  for _, entry in pairs(active) do
    entry.tracker._close "stopped"
  end
end

M.setup_autocmds = function()
  local group = vim.api.nvim_create_augroup("PomoTodo", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close_all })
end

---@class pomo.DayStats
---@field per_todo table<integer, integer> Seconds logged per todo ID.
---@field pomos table<integer, integer> Completed pomodoros per todo ID.
---@field focus integer Seconds covered by at least one session (overlapping timers aren't double counted).
---@field gaps { start: integer, stop: integer }[] Idle stretches between sessions.
---@field gap_total integer
---@field first integer|? Start of the first session.
---@field last integer|? End of the last session.

---@param day pomo.Day
---@return pomo.DayStats
M.stats = function(day)
  local stats = { per_todo = {}, pomos = {}, focus = 0, gaps = {}, gap_total = 0 }

  local sessions = vim.deepcopy(day.sessions)
  table.sort(sessions, function(a, b)
    return a.start < b.start
  end)

  local cur_start, cur_stop
  for _, s in ipairs(sessions) do
    local len = math.max(s.stop - s.start, 0)
    stats.per_todo[s.todo_id] = (stats.per_todo[s.todo_id] or 0) + len
    if s.status == "done" then
      stats.pomos[s.todo_id] = (stats.pomos[s.todo_id] or 0) + 1
    end

    if cur_stop == nil then
      cur_start, cur_stop = s.start, s.stop
      stats.first = s.start
    elseif s.start > cur_stop then
      stats.focus = stats.focus + (cur_stop - cur_start)
      stats.gaps[#stats.gaps + 1] = { start = cur_stop, stop = s.start }
      stats.gap_total = stats.gap_total + (s.start - cur_stop)
      cur_start, cur_stop = s.start, s.stop
    else
      cur_stop = math.max(cur_stop, s.stop)
    end
  end
  if cur_stop ~= nil then
    stats.focus = stats.focus + (cur_stop - cur_start)
    stats.last = cur_stop
  end

  return stats
end

---Split the time from `from` to `from + n * cell_secs` into cells and figure out which todo (if any) each
---cell belongs to. A cell belongs to the todo with the most time logged in it, as long as at least half the
---cell was spent on todos.
---@param day pomo.Day
---@param from integer Unix timestamp
---@param n integer Number of cells
---@param cell_secs integer
---@return (integer|false)[] cells Todo ID or `false` for each cell.
M.timeline = function(day, from, n, cell_secs)
  ---@type table<integer, table<integer, integer>>
  local coverage = {}
  local to = from + n * cell_secs

  for _, s in ipairs(day.sessions) do
    local s_start, s_stop = math.max(s.start, from), math.min(s.stop, to)
    if s_stop > s_start then
      local first = math.floor((s_start - from) / cell_secs)
      local last = math.min(math.floor((s_stop - 1 - from) / cell_secs), n - 1)
      for i = first, last do
        local c_start = from + i * cell_secs
        local overlap = math.min(s_stop, c_start + cell_secs) - math.max(s_start, c_start)
        coverage[i] = coverage[i] or {}
        coverage[i][s.todo_id] = (coverage[i][s.todo_id] or 0) + overlap
      end
    end
  end

  local cells = {}
  for i = 0, n - 1 do
    local best, best_secs, total = false, 0, 0
    for todo_id, secs in pairs(coverage[i] or {}) do
      total = total + secs
      if secs > best_secs or (secs == best_secs and best and todo_id < best) then
        best, best_secs = todo_id, secs
      end
    end
    cells[i + 1] = (total * 2 >= cell_secs) and best or false
  end
  return cells
end

return M
