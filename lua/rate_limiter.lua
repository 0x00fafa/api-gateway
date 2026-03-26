--- OpenResty API Proxy Gateway - 限流器模块
-- 基于令牌桶算法实现多维度限流

local config = require "config"
local cjson = require "cjson"

local _M = {}

--- 获取共享内存字典
local function get_dict()
    return ngx.shared.rate_limiter
end

--- 令牌桶算法
-- @param key string 限流key
-- @param rate number 令牌生成速率（个/秒）
-- @param burst number 桶容量
-- @return boolean 是否允许
function _M.token_bucket(key, rate, burst)
    local dict = get_dict()
    if not dict then
        ngx.log(ngx.ERR, "[RateLimiter] Shared dict not found")
        return true
    end
    
    local now = ngx.now()
    local last_time_key = key .. ":last_time"
    local tokens_key = key .. ":tokens"
    
    local last_time = dict:get(last_time_key) or now
    local tokens = dict:get(tokens_key) or burst
    
    -- 计算新增令牌
    local elapsed = now - last_time
    local new_tokens = elapsed * rate
    tokens = math.min(tokens + new_tokens, burst)
    
    if tokens >= 1 then
        -- 消耗一个令牌
        dict:set(tokens_key, tokens - 1)
        dict:set(last_time_key, now)
        return true
    end
    
    return false
end

--- 检查限流
-- @param provider_name string Provider名称
-- @param client_ip string 客户端IP
-- @return boolean 是否允许
-- @return string|nil 限流类型
-- @return number|nil 重试等待时间
function _M.check_rate_limit(provider_name, client_ip)
    local rl_config = config.get_rate_limiter_config()
    
    -- 未启用限流器，允许请求
    if not rl_config.enabled then
        return true
    end
    
    -- 1. 全局限流
    if rl_config.global and rl_config.global > 0 then
        if not _M.token_bucket("global", rl_config.global, rl_config.global * 0.1) then
            ngx.log(ngx.WARN, "[RateLimiter] Global rate limit exceeded")
            return false, "global", 1
        end
    end
    
    -- 2. Provider限流
    local provider_limit = rl_config.providers and rl_config.providers[provider_name]
    if provider_limit and provider_limit > 0 then
        if not _M.token_bucket("provider:" .. provider_name, provider_limit, provider_limit * 0.1) then
            ngx.log(ngx.WARN, "[RateLimiter] Provider rate limit exceeded: ", provider_name)
            return false, "provider:" .. provider_name, 1
        end
    end
    
    -- 3. IP限流
    if rl_config.ip and rl_config.ip > 0 then
        local burst = rl_config.ip_burst or rl_config.ip * 0.2
        if not _M.token_bucket("ip:" .. client_ip, rl_config.ip, burst) then
            ngx.log(ngx.WARN, "[RateLimiter] IP rate limit exceeded: ", client_ip)
            return false, "ip", 1
        end
    end
    
    -- 4. API Key限流（从请求头获取）
    local api_key = ngx.var.http_x_api_key
    if api_key and api_key ~= "" and rl_config.api_key and rl_config.api_key > 0 then
        local burst = rl_config.api_key_burst or rl_config.api_key * 0.1
        if not _M.token_bucket("api_key:" .. api_key, rl_config.api_key, burst) then
            ngx.log(ngx.WARN, "[RateLimiter] API Key rate limit exceeded: ", string.sub(api_key, 1, 10) .. "...")
            return false, "api_key", 1
        end
    end
    
    -- 5. URI限流
    if rl_config.uri and rl_config.uri > 0 then
        local uri = ngx.var.uri
        local burst = rl_config.uri_burst or rl_config.uri * 0.2
        if not _M.token_bucket("uri:" .. uri, rl_config.uri, burst) then
            ngx.log(ngx.WARN, "[RateLimiter] URI rate limit exceeded: ", uri)
            return false, "uri", 1
        end
    end
    
    return true
end

--- 生成 UUID
local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

--- 获取或生成请求 ID
local function get_request_id()
    local request_id = ngx.var.http_x_onekey_request_id
    if not request_id or request_id == "" then
        request_id = generate_uuid()
    end
    return request_id
end

--- 发送限流响应
-- @param limit_type string 限流类型
-- @param retry_after number 重试等待时间（秒）
function _M.send_rate_limited_response(limit_type, retry_after)
    local request_id = get_request_id()
    
    ngx.status = 429
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = request_id
    ngx.header["Retry-After"] = retry_after or 1
    ngx.header["X-RateLimit-Limit"] = "exceeded"
    ngx.header["X-RateLimit-Remaining"] = "0"
    ngx.say(cjson.encode({
        error = "Too Many Requests",
        message = "Rate limit exceeded",
        limit_type = limit_type or "unknown",
        retry_after = retry_after or 1,
        request_id = request_id
    }))
end

--- 获取限流器状态信息
-- @param key string 限流key（可选，不传则返回所有）
-- @return table 状态信息
function _M.get_status(key)
    local dict = get_dict()
    if not dict then
        return {}
    end
    
    if key then
        local tokens = dict:get(key .. ":tokens")
        local last_time = dict:get(key .. ":last_time")
        return {
            key = key,
            tokens = tokens,
            last_time = last_time,
            time_since_update = last_time and (ngx.now() - last_time) or nil
        }
    end
    
    -- 返回配置信息
    local rl_config = config.get_rate_limiter_config()
    return {
        enabled = rl_config.enabled,
        global = rl_config.global,
        providers = rl_config.providers,
        ip = rl_config.ip,
        ip_burst = rl_config.ip_burst,
        api_key = rl_config.api_key,
        api_key_burst = rl_config.api_key_burst,
        uri = rl_config.uri,
        uri_burst = rl_config.uri_burst
    }
end

--- 重置限流器状态（用于测试）
-- @param key string 限流key
function _M.reset(key)
    local dict = get_dict()
    if not dict then
        return false, "Shared dict not found"
    end
    
    if key then
        dict:delete(key .. ":tokens")
        dict:delete(key .. ":last_time")
        return true
    end
    
    return false, "Key is required"
end

return _M
