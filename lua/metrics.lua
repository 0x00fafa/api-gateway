--- OpenResty API Proxy Gateway - 监控指标模块
-- 收集和暴露Prometheus格式的监控指标
--

local cjson = require "cjson"

local _M = {
    _VERSION = '1.0.0'
}

-- 共享内存字典名称
local SHARED_DICT = "api_cache"

-- 指标键前缀
local PREFIX = "metrics:"

--- 获取共享内存字典
-- @return table|nil 共享内存字典
local function get_shared_dict()
    local dict = ngx.shared[SHARED_DICT]
    if not dict then
        ngx.log(ngx.WARN, "[Metrics] Shared dict '", SHARED_DICT, "' not found")
        return nil
    end
    return dict
end

--- 原子增加计数器
-- @param key string 键名
-- @param value number 增加值（默认1）
-- @param ttl number 过期时间（秒，默认86400）
local function incr_counter(key, value, ttl)
    local dict = get_shared_dict()
    if not dict then
        return
    end
    
    value = value or 1
    ttl = ttl or 86400
    
    local new_val, err = dict:incr(key, value, 0, ttl)
    if err then
        ngx.log(ngx.DEBUG, "[Metrics] incr error for ", key, ": ", err)
    end
end

--- 记录请求
-- @param provider string Provider名称
-- @param method string HTTP方法
-- @param status number HTTP状态码
-- @param duration number 请求耗时（毫秒）
-- @param success boolean 是否成功
function _M.record_request(provider, method, status, duration, success)
    local dict = get_shared_dict()
    if not dict then
        return
    end
    
    local now = ngx.now()
    local minute_key = os.date("%Y%m%d%H%M", now)
    
    -- 总请求数
    incr_counter(PREFIX .. "requests_total:" .. minute_key, 1, 3600)
    
    -- Provider请求数
    incr_counter(PREFIX .. "requests_by_provider:" .. provider .. ":" .. minute_key, 1, 3600)
    
    -- 方法请求数
    incr_counter(PREFIX .. "requests_by_method:" .. method .. ":" .. minute_key, 1, 3600)
    
    -- 状态码统计
    local status_class = math.floor(status / 100) .. "xx"
    incr_counter(PREFIX .. "requests_by_status:" .. status_class .. ":" .. minute_key, 1, 3600)
    incr_counter(PREFIX .. "requests_by_status:" .. status .. ":" .. minute_key, 1, 3600)
    
    -- 成功/失败统计
    if success then
        incr_counter(PREFIX .. "requests_success:" .. provider .. ":" .. minute_key, 1, 3600)
    else
        incr_counter(PREFIX .. "requests_failure:" .. provider .. ":" .. minute_key, 1, 3600)
    end
    
    -- 延迟统计（存储到延迟桶）
    _M.record_latency(provider, duration)
end

--- 记录延迟（使用直方图桶）
-- @param provider string Provider名称
-- @param duration number 请求耗时（毫秒）
function _M.record_latency(provider, duration)
    local dict = get_shared_dict()
    if not dict then
        return
    end
    
    local now = ngx.now()
    local minute_key = os.date("%Y%m%d%H%M", now)
    
    -- 延迟桶（毫秒）
    local latency_buckets = {10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000}
    
    for _, bucket in ipairs(latency_buckets) do
        if duration <= bucket then
            incr_counter(PREFIX .. "latency_bucket:" .. provider .. ":" .. bucket .. ":" .. minute_key, 1, 3600)
            break
        end
    end
    -- 超过最大桶
    if duration > latency_buckets[#latency_buckets] then
        incr_counter(PREFIX .. "latency_bucket:" .. provider .. ":inf:" .. minute_key, 1, 3600)
    end
    
    -- 总延迟和计数（用于计算平均值）
    incr_counter(PREFIX .. "latency_sum:" .. provider .. ":" .. minute_key, duration, 3600)
    incr_counter(PREFIX .. "latency_count:" .. provider .. ":" .. minute_key, 1, 3600)
end

--- 记录错误
-- @param provider string Provider名称
-- @param error_type string 错误类型
function _M.record_error(provider, error_type)
    local now = ngx.now()
    local minute_key = os.date("%Y%m%d%H%M", now)
    
    incr_counter(PREFIX .. "errors_by_type:" .. error_type .. ":" .. minute_key, 1, 3600)
    incr_counter(PREFIX .. "errors_by_provider:" .. provider .. ":" .. minute_key, 1, 3600)
end

--- 记录活跃连接
-- @param delta number 变化量（1或-1）
function _M.record_active_connection(delta)
    local dict = get_shared_dict()
    if not dict then
        return
    end
    
    local key = PREFIX .. "active_connections"
    local new_val, err = dict:incr(key, delta, 0)
    if err then
        ngx.log(ngx.DEBUG, "[Metrics] active connections incr error: ", err)
    end
end

--- 记录缓存状态
-- @param provider string Provider名称
-- @param status string 缓存状态（HIT/MISS/BYPASS）
function _M.record_cache_status(provider, status)
    incr_counter(PREFIX .. "cache_" .. string.lower(status) .. ":" .. provider, 1, 3600)
end

--- 记录重试
-- @param provider string Provider名称
-- @param attempts number 重试次数
function _M.record_retry(provider, attempts)
    incr_counter(PREFIX .. "retries:" .. provider, attempts - 1, 3600)
    incr_counter(PREFIX .. "retry_total", attempts - 1, 3600)
end

--- 记录降级
-- @param provider string Provider名称
-- @param degradation_type string 降级类型
function _M.record_degradation(provider, degradation_type)
    incr_counter(PREFIX .. "degradations:" .. provider .. ":" .. degradation_type, 1, 3600)
    incr_counter(PREFIX .. "degradations_total", 1, 3600)
end

--- 获取计数器值
-- @param key string 键名
-- @return number|nil 值
local function get_counter(key)
    local dict = get_shared_dict()
    if not dict then
        return nil
    end
    
    local val, _ = dict:get(key)
    return val or 0
end

--- 计算百分位数
-- @param provider string Provider名称
-- @param percentile number 百分位（50/95/99）
-- @param window_minutes number 时间窗口（分钟）
-- @return number|nil 百分位值（毫秒）
function _M.calculate_percentile(provider, percentile, window_minutes)
    local dict = get_shared_dict()
    if not dict then
        return nil
    end
    
    window_minutes = window_minutes or 5
    local now = ngx.now()
    
    -- 聚合时间窗口内的延迟桶
    local latency_buckets = {10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000}
    local bucket_counts = {}
    local total_count = 0
    
    for i = 0, window_minutes - 1 do
        local time = now - i * 60
        local minute_key = os.date("%Y%m%d%H%M", time)
        
        for _, bucket in ipairs(latency_buckets) do
            local count = get_counter(PREFIX .. "latency_bucket:" .. provider .. ":" .. bucket .. ":" .. minute_key) or 0
            bucket_counts[bucket] = (bucket_counts[bucket] or 0) + count
            total_count = total_count + count
        end
        
        -- 超过最大桶的计数
        local inf_count = get_counter(PREFIX .. "latency_bucket:" .. provider .. ":inf:" .. minute_key) or 0
        bucket_counts["inf"] = (bucket_counts["inf"] or 0) + inf_count
        total_count = total_count + inf_count
    end
    
    if total_count == 0 then
        return nil
    end
    
    -- 计算目标位置
    local target = total_count * (percentile / 100)
    local cumulative = 0
    
    for _, bucket in ipairs(latency_buckets) do
        cumulative = cumulative + (bucket_counts[bucket] or 0)
        if cumulative >= target then
            return bucket
        end
    end
    
    -- 超过最大桶
    return latency_buckets[#latency_buckets] * 2
end

--- 生成Prometheus格式指标
-- @return string Prometheus格式指标文本
function _M.export_prometheus()
    local dict = get_shared_dict()
    local lines = {}
    local now = ngx.now()
    local current_minute = os.date("%Y%m%d%H%M", now)
    
    -- 辅助函数：添加指标行
    local function add_metric(name, help, type_str, value, labels)
        table.insert(lines, "# HELP " .. name .. " " .. help)
        table.insert(lines, "# TYPE " .. name .. " " .. type_str)
        if labels then
            table.insert(lines, name .. labels .. " " .. tostring(value))
        else
            table.insert(lines, name .. " " .. tostring(value))
        end
    end
    
    -- 活跃连接数
    local active_conns = get_counter(PREFIX .. "active_connections") or 0
    add_metric("api_gateway_active_connections", "Current number of active connections", "gauge", active_conns)
    
    -- 总请求数（当前分钟）
    local requests_total = get_counter(PREFIX .. "requests_total:" .. current_minute) or 0
    add_metric("api_gateway_requests_total", "Total number of requests", "counter", requests_total)
    
    -- Provider统计
    local providers = {"zerion", "coingecko", "alchemy"}
    for _, provider in ipairs(providers) do
        local provider_requests = get_counter(PREFIX .. "requests_by_provider:" .. provider .. ":" .. current_minute) or 0
        local provider_success = get_counter(PREFIX .. "requests_success:" .. provider .. ":" .. current_minute) or 0
        local provider_failure = get_counter(PREFIX .. "requests_failure:" .. provider .. ":" .. current_minute) or 0
        
        add_metric("api_gateway_provider_requests_total", "Total requests by provider", "counter", provider_requests, '{provider="' .. provider .. '"}')
        add_metric("api_gateway_provider_success_total", "Successful requests by provider", "counter", provider_success, '{provider="' .. provider .. '"}')
        add_metric("api_gateway_provider_failure_total", "Failed requests by provider", "counter", provider_failure, '{provider="' .. provider .. '"}')
        
        -- 成功率
        local success_rate = 0
        if provider_requests > 0 then
            success_rate = provider_success / provider_requests * 100
        end
        add_metric("api_gateway_provider_success_rate", "Success rate by provider", "gauge", string.format("%.2f", success_rate), '{provider="' .. provider .. '"}')
        
        -- 延迟百分位数
        local p50 = _M.calculate_percentile(provider, 50, 5) or 0
        local p95 = _M.calculate_percentile(provider, 95, 5) or 0
        local p99 = _M.calculate_percentile(provider, 99, 5) or 0
        
        add_metric("api_gateway_latency_p50_ms", "Request latency P50 in milliseconds", "gauge", p50, '{provider="' .. provider .. '"}')
        add_metric("api_gateway_latency_p95_ms", "Request latency P95 in milliseconds", "gauge", p95, '{provider="' .. provider .. '"}')
        add_metric("api_gateway_latency_p99_ms", "Request latency P99 in milliseconds", "gauge", p99, '{provider="' .. provider .. '"}')
    end
    
    -- 错误统计
    local error_types = {"timeout", "connection_refused", "dns_error", "upstream_error"}
    for _, err_type in ipairs(error_types) do
        local count = get_counter(PREFIX .. "errors_by_type:" .. err_type .. ":" .. current_minute) or 0
        add_metric("api_gateway_errors_total", "Total errors by type", "counter", count, '{error_type="' .. err_type .. '"}')
    end
    
    -- 缓存统计
    for _, provider in ipairs(providers) do
        local hits = get_counter(PREFIX .. "cache_hit:" .. provider) or 0
        local misses = get_counter(PREFIX .. "cache_miss:" .. provider) or 0
        add_metric("api_gateway_cache_hits_total", "Cache hits by provider", "counter", hits, '{provider="' .. provider .. '"}')
        add_metric("api_gateway_cache_misses_total", "Cache misses by provider", "counter", misses, '{provider="' .. provider .. '"}')
    end
    
    -- 重试统计
    local retries = get_counter(PREFIX .. "retry_total") or 0
    add_metric("api_gateway_retries_total", "Total number of retries", "counter", retries)
    
    -- 降级统计
    local degradations = get_counter(PREFIX .. "degradations_total") or 0
    add_metric("api_gateway_degradations_total", "Total number of degradations", "counter", degradations)
    
    return table.concat(lines, "\n")
end

--- 生成JSON格式指标（用于API）
-- @return table 指标数据表
function _M.export_json()
    local now = ngx.now()
    local current_minute = os.date("%Y%m%d%H%M", now)
    
    local data = {
        timestamp = now,
        active_connections = get_counter(PREFIX .. "active_connections") or 0,
        requests_total = get_counter(PREFIX .. "requests_total:" .. current_minute) or 0,
        providers = {},
        errors = {},
        cache = {},
        retries = get_counter(PREFIX .. "retry_total") or 0,
        degradations = get_counter(PREFIX .. "degradations_total") or 0
    }
    
    local providers = {"zerion", "coingecko", "alchemy"}
    for _, provider in ipairs(providers) do
        local requests = get_counter(PREFIX .. "requests_by_provider:" .. provider .. ":" .. current_minute) or 0
        local success = get_counter(PREFIX .. "requests_success:" .. provider .. ":" .. current_minute) or 0
        local failure = get_counter(PREFIX .. "requests_failure:" .. provider .. ":" .. current_minute) or 0
        
        data.providers[provider] = {
            requests = requests,
            success = success,
            failure = failure,
            success_rate = requests > 0 and (success / requests * 100) or 0,
            latency = {
                p50 = _M.calculate_percentile(provider, 50, 5) or 0,
                p95 = _M.calculate_percentile(provider, 95, 5) or 0,
                p99 = _M.calculate_percentile(provider, 99, 5) or 0
            }
        }
        
        data.cache[provider] = {
            hits = get_counter(PREFIX .. "cache_hit:" .. provider) or 0,
            misses = get_counter(PREFIX .. "cache_miss:" .. provider) or 0
        }
    end
    
    local error_types = {"timeout", "connection_refused", "dns_error", "upstream_error"}
    for _, err_type in ipairs(error_types) do
        data.errors[err_type] = get_counter(PREFIX .. "errors_by_type:" .. err_type .. ":" .. current_minute) or 0
    end
    
    return data
end

return _M
