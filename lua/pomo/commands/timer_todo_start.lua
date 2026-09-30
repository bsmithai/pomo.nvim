local log = require "pomo.log"
local todo = require "pomo.todo"
local util = require "pomo.util"

return function(data)
  ---@type integer|?
  local time_limit
  if data.args and data.args ~= "" then
    time_limit = util.parse_time(data.args)
    if time_limit == nil then
      return log.error("invalid time limit '%s'", data.args)
    end
  end

  local date = todo.today()
  local choices = vim.tbl_filter(function(t)
    return not t.done and todo.get_timer(date, t.id) == nil
  end, todo.visible_todos(todo.load(date)))

  if #choices == 0 then
    return log.warn "no unfinished tasks without a running timer today, add one with ':TimerTodoAdd' or ':TimerDay'"
  end

  vim.ui.select(choices, {
    prompt = "Start a pomodoro for",
    format_item = function(t)
      return t.title
    end,
  }, function(choice)
    if choice ~= nil then
      todo.start(choice.id, time_limit)
    end
  end)
end
