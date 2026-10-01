---Sets your Slack status to the todo you're actively running a pomodoro for, and restores your previous
---status when no todo timer is running (or they're all paused).
---
---Requires a Slack user token (xoxp-...) with the `users.profile:read` and `users.profile:write` scopes.
local log = require "pomo.log"
local todo = require "pomo.todo"

local M = {}

---@class pomo.SlackConfig
---@field enabled boolean
---@field token string|(fun(): string)|? A user token, or a function returning one (e.g. from a password manager).
---@field token_env string Environment variable to read the token from when `token` isn't set.
---@field emoji string Status emoji to use while a todo is running.
---@field format string Format string for the status text, given the todo's title.
---@field restore boolean Restore the status you had before the pomodoro started, instead of clearing it.

---@class pomo.SlackStatus
---@field status_text string
---@field status_emoji string
---@field status_expiration integer

---@type pomo.SlackConfig
local config

---Key identifying the session currently reflected in Slack, or `nil` if we haven't changed the status.
---@type string|?
local applied
---The status from before we changed it.
---@type pomo.SlackStatus|?
local saved
local in_flight = false
local dirty = false
local exiting = false

---@return string|?
local function get_token()
  local token = config.token
  if type(token) == "function" then
    local ok, result = pcall(token)
    if not ok then
      log.error("slack: failed to get token: %s", result)
      return nil
    end
    token = result
  end
  if token == nil or token == "" then
    token = os.getenv(config.token_env)
  end
  if token == nil or token == "" then
    return nil
  end
  return vim.trim(token)
end

---Call a Slack Web API method. The token is passed to curl over stdin so it doesn't show up in `ps`.
---@param method string
---@param body table|? JSON body to POST, otherwise it's a GET.
---@param callback fun(resp: table|?)
---@param sync boolean|? Block until the request finishes (used when Neovim is exiting).
M._request = function(method, body, callback, sync)
  local token = get_token()
  if token == nil then
    log.error("slack: no token found, set 'slack.token' or the %s environment variable", config.token_env)
    return callback(nil)
  end

  local args = { "curl", "-sS", "--max-time", "10", "--config", "-" }
  if body ~= nil then
    vim.list_extend(args, { "-H", "Content-Type: application/json; charset=utf-8", "--data", vim.json.encode(body) })
  end
  args[#args + 1] = "https://slack.com/api/" .. method

  local function handle(res)
    local ok, resp = pcall(vim.json.decode, res.stdout or "")
    if res.code ~= 0 or not ok or type(resp) ~= "table" then
      log.error("slack: %s request failed: %s", method, vim.trim(res.stderr or ""))
      return callback(nil)
    end
    if not resp.ok then
      local detail = resp.needed and string.format(" (token needs the '%s' scope)", resp.needed) or ""
      log.error("slack: %s failed: %s%s", method, tostring(resp.error), detail)
      return callback(nil)
    end
    callback(resp)
  end

  local stdin = string.format('header = "Authorization: Bearer %s"\n', token)
  if sync then
    local ok, obj = pcall(vim.system, args, { stdin = stdin, text = true })
    if ok then
      handle(obj:wait(3000))
    end
  else
    vim.system(args, { stdin = stdin, text = true }, function(res)
      vim.schedule(function()
        handle(res)
      end)
    end)
  end
end

---@param status pomo.SlackStatus
---@param callback fun(ok: boolean)
---@param sync boolean|?
local function set_status(status, callback, sync)
  M._request("users.profile.set", { profile = status }, function(resp)
    callback(resp ~= nil)
  end, sync)
end

---@return pomo.SlackStatus
local function status_to_restore()
  local status = saved
  if
    not config.restore
    or status == nil
    or (status.status_expiration ~= 0 and status.status_expiration <= todo.now())
  then
    return { status_text = "", status_emoji = "", status_expiration = 0 }
  end
  return status
end

---Bring the Slack status in line with the todo that's currently running.
M.sync = function()
  if exiting then
    return
  end
  if in_flight then
    dirty = true
    return
  end

  local current = todo.current()
  local key = current and string.format("%s:%d:%d:%s", current.date, current.todo.id, current.session.start, current.todo.title)
  if key == applied then
    return
  end

  local function finish(ok)
    in_flight = false
    if ok then
      applied = key
      if key == nil then
        saved = nil
      end
    end
    if dirty then
      dirty = false
      M.sync()
    end
  end

  in_flight = true
  if current == nil then
    return set_status(status_to_restore(), finish)
  end

  local remaining = math.ceil(current.timer:time_remaining() or current.timer.time_limit)
  local status = {
    status_text = vim.fn.strcharpart(string.format(config.format, current.todo.title), 0, 100),
    status_emoji = config.emoji,
    -- Let Slack clear the status on its own if Neovim dies without cleaning up.
    status_expiration = todo.now() + remaining + 60,
  }

  if applied ~= nil or not config.restore then
    return set_status(status, finish)
  end

  -- Remember what the status was before we take it over.
  M._request("users.profile.get", nil, function(resp)
    if resp == nil then
      return finish(false)
    end
    local profile = resp.profile or {}
    saved = {
      status_text = profile.status_text or "",
      status_emoji = profile.status_emoji or "",
      status_expiration = profile.status_expiration or 0,
    }
    set_status(status, finish)
  end)
end

---Restore the previous status synchronously, so it happens before Neovim exits.
M.on_exit = function()
  exiting = true
  if applied ~= nil then
    set_status(status_to_restore(), function() end, true)
    applied = nil
  end
end

---Reset internal state. Only used for tests.
M._reset = function()
  applied, saved, in_flight, dirty, exiting = nil, nil, false, false, false
end

---@param cfg pomo.SlackConfig
M.setup = function(cfg)
  config = cfg
  local group = vim.api.nvim_create_augroup("PomoSlack", { clear = true })
  if not config.enabled then
    return
  end

  if vim.fn.executable "curl" == 0 then
    return log.error "slack: 'curl' is required for the Slack integration"
  end

  vim.api.nvim_create_autocmd("User", { group = group, pattern = "PomoTodoChanged", callback = M.sync })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.on_exit })
end

return M
