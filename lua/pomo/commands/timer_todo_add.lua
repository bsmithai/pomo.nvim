local log = require "pomo.log"
local todo = require "pomo.todo"

return function(data)
  local title = vim.trim(data.args or "")
  if title == "" then
    return log.error "missing task title.\nUsage: TimerTodoAdd TITLE"
  end

  todo.add(todo.load(), title)
  log.info("Added '%s' to today's tasks", title)
end
