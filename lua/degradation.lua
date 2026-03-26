--- OpenResty API Proxy Gateway - 优雅降级模块
-- 当上游服务不可用时，提供降级响应以保证服务可用性
--

local cjson = require "cjson"
local config = require "config"

local _M = {
    _VERSION = '1.0.0'
}

-- 降级类型常量
_M.DEGRADATION_TYPE = {
    STALE_CACHE = "stale_cache",       -- 使用过期缓存
    CIRCUIT_OPEN = "circuit_open",     -- 熔断器打开
    UPSTREAM_ERROR = "upstream_error", -- 上游错误
    TIMEOUT = "timeout",               -- 超时
    RATE_LIMITED = "rate_limited"      -- 限流
}

--- 获取降级配置
-- @return table 降级配置
function _M.get_config()
    local enabled_str = os.getenv("DEGRADATION_ENABLED") or "true"
    local stale_cache_enabled_str = os.getenv("DEGRADATION_STALE_CACHE_ENABLED") or "true"
    local stale_cache_max_age = tonumber(os.getenv("DEGRADATION_STALE_CACHE_MAX_AGE")) or 300
    
    return {
        enabled = enabled_str:lower() == "true",
        stale_cache = {
            enabled = stale_cache_enabled_str:lower() == "true",
            max_age = stale_cache_max_age  -- 过期缓存最大可用时间（秒）
        }
    }
end

--- 从缓存获取过期数据（用于降级）
-- @param cache_key string 缓存Key
-- @param max_age number 最大过期时间（秒）
-- @return table|nil 缓存的响应，nil表示未命中或超过最大过期时间
function _M.get_stale_cache(cache_key, max_age)
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        ngx.log(ngx.WARN, "[Degradation] Cache dict 'api_cache' not found")
        return nil
    end
    
    local cached_data, err = cache_dict:get(cache_key)
    if err then
        ngx.log(ngx.WARN, "[Degradation] Cache get error: ", err)
        return nil
    end
    
    if not cached_data then
        ngx.log(ngx.DEBUG, "[Degradation] No cached data for key: ", cache_key)
        return nil
    end
    
    -- 解析缓存数据
    local decode_ok, cached_response = pcall(cjson.decode, cached_data)
    if not decode_ok then
        ngx.log(ngx.WARN, "[Degradation] Cache decode error")
        return nil
    end
    
    -- 检查是否超过最大过期时间
    if cached_response.expires_at then
        local expired_seconds = ngx.now() - cached_response.expires_at
        if expired_seconds > max_age then
            ngx.log(ngx.INFO, "[Degradation] Stale cache exceeded max age: ", expired_seconds, "s > ", max_age, "s")
            return nil
        end
        -- 记录过期时间
        cached_response.stale_seconds = math.floor(expired_seconds)
    end
    
    ngx.log(ngx.INFO, "[Degradation] Using stale cache, expired ", cached_response.stale_seconds or 0, "s ago")
    return cached_response
end

--- 构建降级响应
-- @param degradation_type string 降级类型
-- @param ctx table 请求上下文
-- @param options table 可选参数
-- @return table 降级响应对象
function _M.build_degradation_response(degradation_type, ctx, options)
    options = options or {}
    local status = options.status or 503
    local message = options.message or "Service Temporarily Unavailable"
    local detail = options.detail or "上游服务暂时不可用，请稍后重试"
    local retry_after = options.retry_after or 30
    local stale_data = options.stale_data
    
    local response = {
        success = false,
        code = status,
        message = message,
        error = {
            type = "service_degraded",
            detail = detail,
            degradation_type = degradation_type,
            retry_after = retry_after
        },
        data = stale_data,
        meta = {
            request_id = ctx and ctx.request_id or "",
            provider = ctx and ctx.provider or "",
            timestamp = ngx.now(),
            degraded = true,
            data_source = stale_data and "stale_cache" or "none"
        }
    }
    
    -- 如果使用了过期缓存，添加额外信息
    if stale_data and options.stale_seconds then
        response.meta.stale_seconds = options.stale_seconds
        response.warning = string.format("数据来自%d秒前的缓存", options.stale_seconds)
    end
    
    return response
end

--- 发送降级响应
-- @param degradation_type string 降级类型
-- @param ctx table 请求上下文
-- @param options table 可选参数
function _M.send_degradation_response(degradation_type, ctx, options)
    options = options or {}
    local response = _M.build_degradation_response(degradation_type, ctx, options)
    
    ngx.status = options.status or 503
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = ctx and ctx.request_id or ""
    ngx.header["X-Degraded"] = "true"
    ngx.header["X-Data-Source"] = response.meta.data_source
    
    if options.retry_after then
        ngx.header["Retry-After"] = tostring(options.retry_after)
    end
    
    ngx.say(cjson.encode(response))
end

--- 尝试降级处理
-- @param cache_key string|nil 缓存Key
-- @param ctx table 请求上下文
-- @param degradation_type string 降级类型
-- @param options table 可选参数
-- @return boolean 是否成功降级
function _M.try_degrade(cache_key, ctx, degradation_type, options)
    options = options or {}
    local degradation_config = _M.get_config()
    
    ngx.log(ngx.INFO, "[Degradation] Attempting degradation, type: ", degradation_type, 
            ", cache_key: ", cache_key or "nil")
    
    -- 检查是否启用降级
    if not degradation_config.enabled then
        ngx.log(ngx.INFO, "[Degradation] Degradation disabled")
        return false
    end
    
    -- 尝试使用过期缓存
    if cache_key and degradation_config.stale_cache.enabled then
        local stale_cache = _M.get_stale_cache(cache_key, degradation_config.stale_cache.max_age)
        if stale_cache then
            -- 解析缓存数据作为stale_data
            local stale_data = nil
            if stale_cache.body then
                local decode_ok, body_data = pcall(cjson.decode, stale_cache.body)
                if decode_ok and type(body_data) == "table" then
                    stale_data = body_data
                end
            end
            
            -- 发送带过期缓存数据的降级响应
            _M.send_degradation_response(degradation_type, ctx, {
                status = 200,  -- 有数据时返回200
                message = "OK (Degraded)",
                detail = "服务降级中，返回缓存数据",
                stale_data = stale_data,
                stale_seconds = stale_cache.stale_seconds,
                retry_after = options.retry_after or 30
            })
            return true
        end
    end
    
    -- 没有缓存数据，发送纯降级响应
    _M.send_degradation_response(degradation_type, ctx, options)
    return true
end

return _M
