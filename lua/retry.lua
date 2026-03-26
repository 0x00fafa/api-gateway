--- OpenResty API Proxy Gateway - 重试模块
-- 实现请求重试策略，支持指数退避
--

local cjson = require "cjson"
local config = require "config"

local _M = {
    _VERSION = '1.0.0'
}

--幂等HTTP方法（可以安全重试）
_M.idempotent_methods = {
    ["GET"] = true,
    ["HEAD"] = true,
    ["OPTIONS"] = true,
    ["PUT"] = true,
    ["DELETE"] = true
}

-- 可重试的HTTP状态码
_M.retryable_status_codes = {
    [502] = true,  -- Bad Gateway
    [503] = true,  -- Service Unavailable
    [504] = true,  -- Gateway Timeout
    [429] = true   -- Too Many Requests
}

-- 可重试的错误类型
_M.retryable_errors = {
    ["timeout"] = true,
    ["connection refused"] = true,
    ["closed"] = true,
    ["connection reset"] = true,
    ["no resolver defined"] = true,  -- DNS解析错误
    ["resolver"] = true,             -- DNS相关错误
    ["dns"] = true,                  -- DNS相关错误
    ["connect"] = true,              -- 连接错误
    ["socket"] = true                -- Socket错误
}

--- 获取重试配置
-- @return table 重试配置
function _M.get_config()
    -- 使用 config模块获取配置（支持热更新）
    local retry_config = config.get_retry_config()
    if retry_config then
        return retry_config
    end
    
    -- 回退到默认值
    return {
        enabled = true,
        max_attempts = 3,
        initial_delay = 3000,
        max_delay = 30000,
        multiplier = 2
    }
end

--- 检查方法是否幂等（可安全重试）
-- @param method string HTTP方法
-- @return boolean 是否幂等
function _M.is_idempotent(method)
    if not method then
        return false
    end
    return _M.idempotent_methods[string.upper(method)] == true
end

--- 检查状态码是否可重试
-- @param status number HTTP状态码
-- @return boolean 是否可重试
function _M.is_retryable_status(status)
    return _M.retryable_status_codes[status] == true
end

--- 检查错误是否可重试
-- @param err string 错误信息
-- @return boolean 是否可重试
function _M.is_retryable_error(err)
    if not err or type(err) ~= "string" then
        ngx.log(ngx.DEBUG, "[Retry] is_retryable_error: err is nil or not string")
        return false
    end
    
    local lower_err = string.lower(err)
    ngx.log(ngx.INFO, "[Retry] is_retryable_error: checking error='", lower_err, "'")
    
    for pattern, _ in pairs(_M.retryable_errors) do
        if string.find(lower_err, pattern, 1, true) then
            ngx.log(ngx.INFO, "[Retry] Error matches pattern: ", pattern, " -> retryable")
            return true
        end
    end
    
    ngx.log(ngx.INFO, "[Retry] Error does not match any pattern -> not retryable")
    return false
end

--- 计算重试延迟（指数退避）
-- @param attempt number 当前尝试次数（从1开始）
-- @param retry_config table 重试配置
-- @return number 延迟时间（毫秒）
function _M.calculate_delay(attempt, retry_config)
    local config = retry_config or _M.get_config()
    local delay = config.initial_delay * math.pow(config.multiplier, attempt - 1)
    return math.min(delay, config.max_delay)
end

--- 执行带重试的请求
-- @param request_fn function 请求函数，返回 response, err
-- @param method string HTTP方法
-- @param provider_name string Provider名称（用于日志）
-- @param ctx table 请求上下文
-- @return table|nil response 响应对象, string|nil err 错误信息
function _M.do_with_retry(request_fn, method, provider_name, ctx)
    local retry_config = _M.get_config()
    local request_id = ctx and ctx.request_id or ""
    
    ngx.log(ngx.INFO, "[Retry] Config: enabled=", tostring(retry_config.enabled),
            ", max_attempts=", retry_config.max_attempts,
            ", method=", method or "nil",
            ", is_idempotent=", tostring(_M.is_idempotent(method)))
    
    -- 检查是否启用重试
    if not retry_config.enabled then
        ngx.log(ngx.INFO, "[Retry] Retry disabled, executing request directly")
        return request_fn()
    end
    
    -- 检查方法是否幂等
    if not _M.is_idempotent(method) then
        ngx.log(ngx.WARN, "[", request_id, "] Method ", method, " is not idempotent, skip retry")
        return request_fn()
    end
    
    local last_response = nil
    local last_err = nil
    local max_attempts = retry_config.max_attempts
    
    for attempt = 1, max_attempts do
        -- 执行请求
        local response, err = request_fn()
        
        -- 请求成功
        if response then
            -- 检查状态码是否需要重试
            if not _M.is_retryable_status(response.status) then
                -- 成功响应，直接返回
                if attempt > 1 then
                    ngx.log(ngx.INFO, "[", request_id, "] Retry succeeded on attempt ", attempt, 
                            ", provider: ", provider_name, ", status: ", response.status)
                end
                return response, nil
            end
            
            -- 状态码可重试，但需要检查是否还有重试次数
            last_response = response
            last_err = "retryable_status:" .. response.status
            
            if attempt < max_attempts then
                local delay = _M.calculate_delay(attempt, retry_config)
                ngx.log(ngx.WARN, "[", request_id, "] Retryable status ", response.status, 
                        ", attempt ", attempt, "/", max_attempts, 
                        ", retrying in ", delay, "ms, provider: ", provider_name)
                ngx.sleep(delay / 1000)  -- 转换为秒
            end
        else
            -- 请求失败（网络错误等）
            last_response = nil
            last_err = err
            
            if _M.is_retryable_error(err) then
                if attempt < max_attempts then
                    local delay = _M.calculate_delay(attempt, retry_config)
                    ngx.log(ngx.WARN, "[", request_id, "] Retryable error: ", err, 
                            ", attempt ", attempt, "/", max_attempts, 
                            ", retrying in ", delay, "ms, provider: ", provider_name)
                    ngx.sleep(delay / 1000)  -- 转换为秒
                end
            else
                -- 不可重试的错误，直接返回
                ngx.log(ngx.ERR, "[", request_id, "] Non-retryable error: ", err, ", provider: ", provider_name)
                return nil, err
            end
        end
    end
    
    -- 所有重试都失败
    ngx.log(ngx.ERR, "[", request_id, "] All ", max_attempts, " attempts failed, provider: ", provider_name)
    return last_response, last_err
end

return _M
