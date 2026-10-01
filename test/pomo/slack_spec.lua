local pomo = require "pomo"
local todo = require "pomo.todo"
local slack = require "pomo.slack"

local data_dir = vim.fn.tempname()
pomo.setup { notifiers = {}, todo = { data_dir = data_dir }, slack = { enabled = true, token = "xoxp-test" } }

describe("slack", function()
  ---@type { method: string, body: table|? }[]
  local calls
  local orig_request = slack._request

  before_each(function()
    vim.fn.delete(data_dir, "rf")
    todo._reset()
    slack._reset()
    calls = {}
    slack._request = function(method, body, callback)
      calls[#calls + 1] = { method = method, body = body }
      if method == "users.profile.get" then
        callback { ok = true, profile = { status_text = "Lunch", status_emoji = ":taco:", status_expiration = 0 } }
      else
        callback { ok = true }
      end
    end
  end)

  after_each(function()
    slack._request = orig_request
  end)

  ---@return table|?
  local function last_status()
    for i = #calls, 1, -1 do
      if calls[i].method == "users.profile.set" then
        return calls[i].body.profile
      end
    end
  end

  it("should follow the running todo and restore the previous status", function()
    local day = todo.load()
    local a = todo.add(day, "Write docs")
    local b = todo.add(day, "Fix bug")

    local timer_a = assert(todo.start(a.id, 60))
    assert.equals("users.profile.get", calls[1].method)
    assert.equals("Write docs", last_status().status_text)
    assert.equals(":tomato:", last_status().status_emoji)
    assert.is_true(last_status().status_expiration > todo.now())

    -- Starting another todo takes over the status, without re-saving the previous status.
    local timer_b = assert(todo.start(b.id, 60))
    assert.equals("Fix bug", last_status().status_text)
    assert.equals(1, #vim.tbl_filter(function(c)
      return c.method == "users.profile.get"
    end, calls))

    -- Pausing b falls back to a, which is still running.
    timer_b:pause()
    assert.equals("Write docs", last_status().status_text)

    -- Renaming the running todo updates the status.
    todo.rename(day, a.id, "Write more docs")
    assert.equals("Write more docs", last_status().status_text)

    -- With nothing running, the original status comes back.
    timer_a:pause()
    assert.equals("Lunch", last_status().status_text)
    assert.equals(":taco:", last_status().status_emoji)

    local n = #calls
    timer_a:resume()
    assert.equals("Write more docs", last_status().status_text)
    pomo.stop_timer(timer_a)
    pomo.stop_timer(timer_b)
    assert.equals("Lunch", last_status().status_text)
    assert.is_true(#calls > n)
  end)

  it("should not send duplicate updates", function()
    local day = todo.load()
    local a = todo.add(day, "Write docs")
    local timer = assert(todo.start(a.id, 60))
    local n = #calls

    -- Unrelated changes don't touch Slack.
    todo.add(day, "Something else")
    slack.sync()
    assert.equals(n, #calls)

    pomo.stop_timer(timer)
  end)
end)
