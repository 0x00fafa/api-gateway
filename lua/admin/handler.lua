--- OpenResty API Proxy Gateway - 管理API处理器
-- 提供熔断器和限流器的测试和管理接口

local cjson = require "cjson"
local circuit_breaker = require "circuit_breaker"
local rate_limiter = require "rate_limiter"
local config = require "config"
local metrics = require "metrics"

local _M = {}

--- 生成 UUID
local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

--- 发送 JSON 响应
local function send_json(status, data)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(data))
end

--- 发送错误响应
local function send_error(status, message)
    send_json(status, {
        error = message,
        request_id = generate_uuid()
    })
end

--- 熔断器状态查询
-- GET /admin/circuit-breaker/:provider
-- GET /admin/circuit-breaker (所有provider)
function _M.circuit_breaker_status()
    local uri = ngx.var.uri
    local provider_name = uri:match("^/admin/circuit%-breaker/([^/]+)$")
    
    local cb_config = config.get_circuit_breaker_config()
    
    if provider_name then
        -- 单个 provider 状态
        local state_info = circuit_breaker.get_state_info(provider_name)
        send_json(200, {
            provider = provider_name,
            config = cb_config,
            state = state_info
        })
    else
        -- 所有 provider 状态
        local providers = {"zerion", "coingecko", "alchemy"}
        local result = {
            config = cb_config,
            providers = {}
        }
        for _, provider in ipairs(providers) do
            result.providers[provider] = circuit_breaker.get_state_info(provider)
        end
        send_json(200, result)
    end
end

--- 熔断器手动触发
-- POST /admin/circuit-breaker/:provider/trip
function _M.circuit_breaker_trip()
    local uri = ngx.var.uri
    local provider_name = uri:match("^/admin/circuit%-breaker/([^/]+)/trip$")
    
    if not provider_name then
        return send_error(400, "Invalid provider name")
    end
    
    local success, err = circuit_breaker.trip(provider_name)
    if success then
        send_json(200, {
            message = "Circuit breaker tripped successfully",
            provider = provider_name,
            state = circuit_breaker.get_state_info(provider_name)
        })
    else
        send_error(500, err or "Failed to trip circuit breaker")
    end
end

--- 熔断器手动恢复
-- POST /admin/circuit-breaker/:provider/reset
function _M.circuit_breaker_reset()
    local uri = ngx.var.uri
    local provider_name = uri:match("^/admin/circuit%-breaker/([^/]+)/reset$")
    
    if not provider_name then
        return send_error(400, "Invalid provider name")
    end
    
    local success, err = circuit_breaker.reset(provider_name)
    if success then
        send_json(200, {
            message = "Circuit breaker reset successfully",
            provider = provider_name,
            state = circuit_breaker.get_state_info(provider_name)
        })
    else
        send_error(500, err or "Failed to reset circuit breaker")
    end
end

--- 限流器状态查询
-- GET /admin/rate-limiter
-- GET /admin/rate-limiter/:key
function _M.rate_limiter_status()
    local uri = ngx.var.uri
    local key = uri:match("^/admin/rate%-limiter/(.+)$")
    
    local status = rate_limiter.get_status(key)
    send_json(200, status)
end

--- 限流器重置
-- POST /admin/rate-limiter/:key/reset
function _M.rate_limiter_reset()
    local uri = ngx.var.uri
    local key = uri:match("^/admin/rate%-limiter/([^/]+)/reset$")
    
    if not key then
        return send_error(400, "Invalid key name")
    end
    
    local success, err = rate_limiter.reset(key)
    if success then
        send_json(200, {
            message = "Rate limiter reset successfully",
            key = key
        })
    else
        send_error(500, err or "Failed to reset rate limiter")
    end
end

--- 测试端点 - 模拟限流
-- GET /admin/test/rate-limit?limit=5&burst=3
-- 该端点会快速消耗令牌，用于测试限流功能
function _M.test_rate_limit()
    local args = ngx.req.get_uri_args()
    local limit = tonumber(args.limit) or 5
    local burst = tonumber(args.burst) or 3
    local key = "test:rate_limit"
    
    local allowed = rate_limiter.token_bucket(key, limit, burst)
    
    if allowed then
        send_json(200, {
            message = "Request allowed",
            key = key,
            limit = limit,
            burst = burst
        })
    else
        send_json(429, {
            error = "Too Many Requests",
            message = "Rate limit exceeded (test endpoint)",
            key = key,
            limit = limit,
            burst = burst
        })
    end
end

--- 测试端点 - 模拟熔断
-- GET /admin/test/circuit-breaker?provider=test&fail=true
-- 该端点模拟熔断器行为
function _M.test_circuit_breaker()
    local args = ngx.req.get_uri_args()
    local provider = args.provider or "test"
    local should_fail = args.fail == "true"
    
    local allowed, reason, retry_after = circuit_breaker.allow_request(provider)
    
    if not allowed then
        circuit_breaker.send_open_response(provider, retry_after)
        return
    end
    
    if should_fail then
        circuit_breaker.record_failure(provider)
        send_json(500, {
            error = "Simulated failure",
            message = "This is a simulated failure for testing",
            provider = provider
        })
    else
        circuit_breaker.record_success(provider)
        send_json(200, {
            message = "Request successful",
            provider = provider,
            state = circuit_breaker.get_state_info(provider)
        })
    end
end

--- 获取监控指标（Prometheus格式）
-- GET /admin/metrics
function _M.metrics()
    local metrics = require "metrics"
    
    ngx.status = 200
    ngx.header["Content-Type"] = "text/plain; version=0.0.4"
    ngx.print(metrics.export_prometheus())
end

--- 获取监控指标（JSON格式）
-- GET /admin/metrics/json
function _M.metrics_json()
    local metrics = require "metrics"
    
    send_json(200, {
        message = "Metrics exported",
        data = metrics.export_json()
    })
end

--- 获取健康状态
-- GET /admin/health
function _M.health()
    local circuit_breaker = require "circuit_breaker"
    local config = require "config"
    
    local providers = {"zerion", "coingecko", "alchemy"}
    local health_status = {
        status = "healthy",
        timestamp = ngx.now(),
        providers = {}
    }
    
    local all_healthy = true
    for _, provider in ipairs(providers) do
        local state_info = circuit_breaker.get_state_info(provider)
        local is_healthy = state_info.state == "closed"
        if not is_healthy then
            all_healthy = false
        end
        
        health_status.providers[provider] = {
            status = is_healthy and "healthy" or "unhealthy",
            state = state_info.state,
            failure_count = state_info.failure_count,
            success_count = state_info.success_count
        }
    end
    
    if not all_healthy then
        health_status.status = "degraded"
    end
    
    local status_code = all_healthy and 200 or 503
    send_json(status_code, health_status)
end

--- 分布式限流状态
-- GET /admin/distributed-rate-limit
function _M.distributed_rate_limit_status()
    local distributed_rate_limiter = require "distributed_rate_limiter"
    local args = ngx.req.get_uri_args()
    local key = args.key or "global"
    local rate = tonumber(args.rate) or 100
    local capacity = tonumber(args.capacity) or 1000
    
    local status = distributed_rate_limiter.get_status(key, rate, capacity)
    send_json(200, status)
end

--- 分布式限流重置
-- POST /admin/distributed-rate-limit/reset
function _M.distributed_rate_limit_reset()
    local distributed_rate_limiter = require "distributed_rate_limiter"
    local args = ngx.req.get_uri_args()
    local key = args.key
    
    if not key then
        return send_error(400, "Key parameter is required")
    end
    
    local success = distributed_rate_limiter.reset(key)
    if success then
        send_json(200, {
            message = "Distributed rate limit reset successfully",
            key = key
        })
    else
        send_error(500, "Failed to reset distributed rate limit")
    end
end

--- 配置管理 - 获取/更新完整配置
-- GET /admin/config - 获取完整配置
-- PUT /admin/config - 更新完整配置
function _M.config_manage()
    local config_manager = require "config_manager"
    local method = ngx.req.get_method()
    
    if method == "GET" then
        -- 获取完整配置
        local cfg = config_manager.load_config()
        local status = config_manager.get_status()
        send_json(200, {
            config = cfg,
            status = status
        })
    elseif method == "PUT" then
        -- 更新完整配置
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        
        if not body_data then
            return send_error(400, "Request body is required")
        end
        
        local decode_ok, new_config = pcall(cjson.decode, body_data)
        if not decode_ok then
            return send_error(400, "Invalid JSON format")
        end
        
        local success, err = config_manager.update_config(new_config)
        if success then
            send_json(200, {
                message = "Config updated successfully",
                version = config_manager.get_config_version()
            })
        else
            send_error(500, err or "Failed to update config")
        end
    else
        send_error(405, "Method not allowed")
    end
end

--- 配置状态
-- GET /admin/config/status
function _M.config_status()
    local config_manager = require "config_manager"
    local status = config_manager.get_status()
    send_json(200, status)
end

--- 配置重置
-- POST /admin/config/reset
function _M.config_reset()
    local config_manager = require "config_manager"
    
    local success = config_manager.reset_config()
    if success then
        send_json(200, {
            message = "Config reset to default successfully",
            version = config_manager.get_config_version()
        })
    else
        send_error(500, "Failed to reset config")
    end
end

--- 配置项操作
-- GET /admin/config/:path - 获取配置项
-- PUT /admin/config/:path - 设置配置项
function _M.config_item()
    local config_manager = require "config_manager"
    local uri = ngx.var.uri
    local path = uri:match("^/admin/config/(.+)$")
    local method = ngx.req.get_method()
    
    if not path then
        return send_error(400, "Invalid config path")
    end
    
    -- URL解码路径（将%2E转换为.等）
    path = ngx.unescape_uri(path)
    
    if method == "GET" then
        -- 获取配置项
        local value = config_manager.get(path)
        if value == nil then
            return send_error(404, "Config path not found: " .. path)
        end
        send_json(200, {
            path = path,
            value = value
        })
    elseif method == "PUT" then
        -- 设置配置项
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        
        if not body_data then
            return send_error(400, "Request body is required")
        end
        
        local decode_ok, body = pcall(cjson.decode, body_data)
        if not decode_ok then
            return send_error(400, "Invalid JSON format")
        end
        
        local value = body.value
        if value == nil then
            return send_error(400, " 'value' field is required")
        end
        
        local success = config_manager.set(path, value)
        if success then
            send_json(200, {
                message = "Config item updated successfully",
                path = path,
                value = value,
                version = config_manager.get_config_version()
            })
        else
            send_error(500, "Failed to update config item")
        end
    else
        send_error(405, "Method not allowed")
    end
end

return _M
