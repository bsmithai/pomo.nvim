local log = require "pomo.log"
local todo = require "pomo.todo"

return function(data)
  local date = data.args
  if date == nil or date == "" then
    date = todo.today()
  elseif not todo.is_valid_date(date) then
    return log.error("invalid date '%s', expected YYYY-MM-DD.\nUsage: TimerDay [DATE]", date)
  end

  require("pomo.todo_view").open(date)
end
