local pomo = require "pomo"
local todo = require "pomo.todo"

local data_dir = vim.fn.tempname()
pomo.setup { notifiers = {}, todo = { data_dir = data_dir } }

---@param date string
---@param h integer
---@param m integer
local function at(date, h, m)
  return todo.time_at(date, h) + m * 60
end

describe("todo", function()
  before_each(function()
    vim.fn.delete(data_dir, "rf")
    todo._reset()
  end)

  it("should add, toggle, rename, and persist todos", function()
    local day = todo.load "2026-01-05"
    local a = todo.add(day, "Write docs")
    local b = todo.add(day, "Fix bug")
    assert.are_not.equals(a.color, b.color)

    todo.toggle(day, b.id)
    todo.rename(day, a.id, "Write more docs")

    todo._reset()
    day = todo.load "2026-01-05"
    assert.equals(2, #day.todos)
    assert.equals("Write more docs", day.todos[1].title)
    assert.is_true(day.todos[2].done)
  end)

  it("should only hide deleted todos that have sessions", function()
    local day = todo.load "2026-01-05"
    local a = todo.add(day, "A")
    local b = todo.add(day, "B")
    day.sessions = { { todo_id = a.id, start = 0, stop = 60, status = "done" } }

    todo.remove(day, a.id)
    todo.remove(day, b.id)
    assert.equals(1, #day.todos)
    assert.is_true(day.todos[1].deleted)
    assert.equals(0, #todo.visible_todos(day))
  end)

  it("should compute totals, focus time, and gaps", function()
    local date = "2026-01-05"
    local day = todo.load(date)
    local a = todo.add(day, "A")
    local b = todo.add(day, "B")
    day.sessions = {
      { todo_id = a.id, start = at(date, 9, 0), stop = at(date, 9, 25), status = "done" },
      { todo_id = b.id, start = at(date, 9, 30), stop = at(date, 9, 40), status = "stopped" },
      -- Overlaps with the previous session, shouldn't be double counted in focus time.
      { todo_id = a.id, start = at(date, 9, 35), stop = at(date, 9, 45), status = "done" },
      { todo_id = a.id, start = at(date, 11, 0), stop = at(date, 11, 25), status = "done" },
    }

    local stats = todo.stats(day)
    assert.equals(60 * 60, stats.per_todo[a.id])
    assert.equals(10 * 60, stats.per_todo[b.id])
    assert.equals(3, stats.pomos[a.id])
    assert.is_nil(stats.pomos[b.id])
    assert.equals((25 + 15 + 25) * 60, stats.focus)
    assert.equals(2, #stats.gaps)
    assert.equals((5 + 75) * 60, stats.gap_total)
    assert.equals(at(date, 9, 0), stats.first)
    assert.equals(at(date, 11, 25), stats.last)
  end)

  it("should assign timeline cells to the todo with the most time", function()
    local date = "2026-01-05"
    local day = todo.load(date)
    day.sessions = {
      { todo_id = 1, start = at(date, 9, 0), stop = at(date, 9, 2) + 40, status = "stopped" },
      { todo_id = 2, start = at(date, 9, 2) + 40, stop = at(date, 9, 4), status = "stopped" },
      { todo_id = 2, start = at(date, 9, 5), stop = at(date, 9, 5) + 10, status = "stopped" },
    }

    local cells = todo.timeline(day, at(date, 9, 0), 6, 60)
    assert.are.same({ 1, 1, 1, 2, false, false }, cells)
  end)

  it("should carry over unfinished todos into a new day", function()
    local yesterday = todo.shift_date(todo.today(), -1)
    local prev = todo.load(yesterday)
    todo.add(prev, "Unfinished")
    local finished = todo.add(prev, "Finished")
    todo.toggle(prev, finished.id)

    local today = todo.load()
    assert.equals(1, #today.todos)
    assert.equals("Unfinished", today.todos[1].title)
  end)

  it("should log timer runs as sessions", function()
    local day = todo.load()
    local t = todo.add(day, "Focus")

    local base = todo.time_at(day.date, 12)
    local clock = base
    local orig_now = todo.now
    todo.now = function()
      return clock
    end

    local timer = assert(todo.start(t.id, 60))
    assert.equals(timer, todo.get_timer(day.date, t.id))
    assert.equals(1, #day.sessions)
    assert.equals("running", day.sessions[1].status)

    clock = base + 100
    timer:pause()
    assert.equals("paused", day.sessions[1].status)
    assert.equals(100, day.sessions[1].stop - day.sessions[1].start)

    clock = base + 200
    timer:resume()
    clock = base + 250
    pomo.stop_timer(timer)
    assert.equals(2, #day.sessions)
    assert.equals("stopped", day.sessions[2].status)
    assert.equals(50, day.sessions[2].stop - day.sessions[2].start)
    assert.is_nil(todo.get_timer(day.date, t.id))

    todo.now = orig_now
  end)
end)
