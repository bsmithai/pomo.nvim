local NotifierType = require("pomo.notifiers").NotifierType

local Config = {}

---@class pomo.Config
---@field update_interval integer
---@field notifiers pomo.NotifierConfig[]
---@field timers table<string, pomo.NotifierConfig[]>
---@field sessions table<string, pomo.SessionConfig[]>  -- Add sessions field
---@field todo pomo.TodoConfig
---@field slack pomo.SlackConfig

---@class pomo.NotifierConfig
---@field name pomo.NotifierType|?
---@field init function|? function(timer_id, time_limit, name, opts)
---@field opts table|?

---@class pomo.SessionConfig  -- Define session config
---@field name string
---@field duration string

---@class pomo.TodoConfig
---@field duration string Default length of a pomodoro started on a todo item.
---@field carry_over boolean Copy unfinished todos from the most recent previous day into a new day.
---@field data_dir string Where the daily todo lists and pomodoro logs are stored.
---@field start_hour integer The day view's timeline always includes at least this hour...
---@field end_hour integer ...through this hour (exclusive).
---@field min_gap integer Gaps shorter than this many minutes are not listed individually.
---@field colors string[] Colors assigned to todo items, in order.

---@return pomo.Config
Config.default = function()
  return {
    update_interval = 1000,
    notifiers = {
      { name = NotifierType.Default },
    },
    timers = {},
    sessions = {}, -- Initialize sessions
    todo = {
      duration = "25m",
      carry_over = true,
      data_dir = vim.fn.stdpath "data" .. "/pomo",
      start_hour = 9,
      end_hour = 17,
      min_gap = 5,
      colors = {
        "#7aa2f7",
        "#9ece6a",
        "#e0af68",
        "#bb9af7",
        "#f7768e",
        "#7dcfff",
        "#ff9e64",
        "#73daca",
        "#c0caf5",
        "#db4b4b",
      },
    },
    slack = {
      enabled = false,
      token = nil,
      token_env = "SLACK_USER_TOKEN",
      emoji = ":tomato:",
      format = "%s",
      restore = true,
    },
  }
end

---@param opts table|pomo.Config
---@return pomo.Config
Config.normalize = function(opts)
  local default = Config.default()
  local config = vim.tbl_extend("force", default, opts)
  config.todo = vim.tbl_extend("force", default.todo, opts.todo or {})
  config.slack = vim.tbl_extend("force", default.slack, opts.slack or {})
  return config
end

return Config
