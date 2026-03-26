--- OpenResty API Proxy Gateway - 熔断器模块
-- 基于 Circuit Breaker 模式实现服务熔断保护

local config = require "config"
local cjson = require "cjson"

local _M = {}

-- 熔断器状态常量
local STATE_CLOSED = "closed"      -- 正常状态
local STATE_OPEN = "open"          -- 熔断状态
local STATE_HALF_OPEN = "half_open" -- 半开状态

--- 获取共享内存字典
local function get_dict()
    return ngx.shared.circuit_breaker
end

--- 检查是否允许请求
-- @param provider_name string Provider名称
-- @return boolean 是否允许
-- @return string|nil 原因
function _M.allow_request(provider_name)
    local cb_config = config.get_circuit_breaker_config()
    
    -- 未启用熔断器，允许请求
    if not cb_config.enabled then
        return true
    end
    
    local dict = get_dict()
    if not dict then
        ngx.log(ngx.ERR, "[CircuitBreaker] Shared dict not found")
        return true
    end
    
    local state = dict:get(provider_name .. ":state") or STATE_CLOSED
    
    if state == STATE_OPEN then
        -- 检查是否可以进入半开状态
        local open_time = dict:get(provider_name .. ":open_time") or 0
        local now = ngx.now()
        
        if (now - open_time) >= cb_config.timeout then
            -- 进入半开状态
            dict:set(provider_name .. ":state", STATE_HALF_OPEN)
            dict:set(provider_name .. ":half_open_count", 0)
            ngx.log(ngx.INFO, "[CircuitBreaker] ", provider_name, " entering HALF_OPEN state")
            return true
        end
        
        -- 仍在熔断中
        local retry_after = math.ceil(cb_config.timeout - (now - open_time))
        return false, "circuit_open", retry_after
    end
    
    if state == STATE_HALF_OPEN then
        -- 半开状态限制请求数
        local count = dict:get(provider_name .. ":half_open_count") or 0
        if count >= cb_config.half_open_requests then
            return false, "circuit_half_open"
        end
        dict:incr(provider_name .. ":half_open_count", 1)
    end
    
    return true
end

--- 记录成功
-- @param provider_name string Provider名称
function _M.record_success(provider_name)
    local cb_config = config.get_circuit_breaker_config()
    if not cb_config.enabled then
        return
    end
    
    local dict = get_dict()
    if not dict then
        return
    end
    
    local state = dict:get(provider_name .. ":state") or STATE_CLOSED
    
    if state == STATE_HALF_OPEN then
        local success_count = dict:incr(provider_name .. ":success_count", 1) or 1
        if success_count >= cb_config.success_threshold then
            -- 恢复正常
            dict:set(provider_name .. ":state", STATE_CLOSED)
            dict:set(provider_name .. ":failure_count", 0)
            dict:set(provider_name .. ":success_count", 0)
            dict:set(provider_name .. ":half_open_count", 0)
            ngx.log(ngx.INFO, "[CircuitBreaker] ", provider_name, " recovered to CLOSED state")
        end
    else
        -- 重置失败计数
        dict:set(provider_name .. ":failure_count", 0)
    end
end

--- 记录失败
-- @param provider_name string Provider名称
function _M.record_failure(provider_name)
    local cb_config = config.get_circuit_breaker_config()
    if not cb_config.enabled then
        return
    end
    
    local dict = get_dict()
    if not dict then
        return
    end
    
    local state = dict:get(provider_name .. ":state") or STATE_CLOSED
    
    if state == STATE_HALF_OPEN then
        -- 半开状态失败，立即熔断
        dict:set(provider_name .. ":state", STATE_OPEN)
        dict:set(provider_name .. ":open_time", ngx.now())
        dict:set(provider_name .. ":success_count", 0)
        ngx.log(ngx.WARN, "[CircuitBreaker] ", provider_name, " back to OPEN state from HALF_OPEN")
    elseif state == STATE_CLOSED then
        -- 累加失败计数
        local failure_count = dict:incr(provider_name .. ":failure_count", 1) or 1
        if failure_count >= cb_config.failure_threshold then
            -- 触发熔断
            dict:set(provider_name .. ":state", STATE_OPEN)
            dict:set(provider_name .. ":open_time", ngx.now())
            ngx.log(ngx.WARN, "[CircuitBreaker] ", provider_name, " tripped to OPEN state after ", 
                    failure_count, " consecutive failures")
        end
    end
end

--- 生成 UUID（内部函数，需在使用前定义）
local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

--- 获取熔断器状态
-- @param provider_name string Provider名称
-- @return string 状态
function _M.get_state(provider_name)
    local dict = get_dict()
    if not dict then
        return STATE_CLOSED
    end
    return dict:get(provider_name .. ":state") or STATE_CLOSED
end

--- 获取熔断器完整状态信息
-- @param provider_name string Provider名称
-- @return table 状态信息
function _M.get_state_info(provider_name)
    local dict = get_dict()
    if not dict then
        return {
            state = STATE_CLOSED,
            failure_count = 0,
            success_count = 0,
            open_time = nil,
            half_open_count = 0
        }
    end
    
    local state = dict:get(provider_name .. ":state") or STATE_CLOSED
    local open_time = dict:get(provider_name .. ":open_time")
    
    return {
        state = state,
        failure_count = dict:get(provider_name .. ":failure_count") or 0,
        success_count = dict:get(provider_name .. ":success_count") or 0,
        open_time = open_time,
        open_time_ago = open_time and (ngx.now() - open_time) or nil,
        half_open_count = dict:get(provider_name .. ":half_open_count") or 0
    }
end

--- 手动触发熔断（用于测试）
-- @param provider_name string Provider名称
function _M.trip(provider_name)
    local cb_config = config.get_circuit_breaker_config()
    if not cb_config.enabled then
        return false, "Circuit breaker is disabled"
    end
    
    local dict = get_dict()
    if not dict then
        return false, "Shared dict not found"
    end
    
    dict:set(provider_name .. ":state", STATE_OPEN)
    dict:set(provider_name .. ":open_time", ngx.now())
    dict:set(provider_name .. ":failure_count", cb_config.failure_threshold)
    ngx.log(ngx.WARN, "[CircuitBreaker] ", provider_name, " manually tripped to OPEN state")
    return true
end

--- 手动恢复熔断器（用于测试）
-- @param provider_name string Provider名称
function _M.reset(provider_name)
    local cb_config = config.get_circuit_breaker_config()
    if not cb_config.enabled then
        return false, "Circuit breaker is disabled"
    end
    
    local dict = get_dict()
    if not dict then
        return false, "Shared dict not found"
    end
    
    dict:set(provider_name .. ":state", STATE_CLOSED)
    dict:set(provider_name .. ":failure_count", 0)
    dict:set(provider_name .. ":success_count", 0)
    dict:set(provider_name .. ":half_open_count", 0)
    dict:set(provider_name .. ":open_time", nil)
    ngx.log(ngx.INFO, "[CircuitBreaker] ", provider_name, " manually reset to CLOSED state")
    return true
end

--- 发送熔断响应
-- @param provider_name string Provider名称
-- @param retry_after number 重试等待时间（秒）
function _M.send_open_response(provider_name, retry_after)
    local request_id = ngx.var.http_x_onekey_request_id or generate_uuid()
    
    ngx.status = 503
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = request_id
    if retry_after then
        ngx.header["Retry-After"] = tostring(retry_after)
    end
    ngx.say(cjson.encode({
        error = "Service Unavailable",
        message = "Provider temporarily unavailable due to errors",
        provider = provider_name,
        retry_after = retry_after or 30,
        request_id = request_id
    }))
end

return _M
