--- OpenResty API Proxy Gateway - 代理处理器
-- 

local http = require "resty.http"
local cjson = require "cjson"
local config = require "config"
local circuit_breaker = require "circuit_breaker"
local rate_limiter = require "rate_limiter"
local geoip = require "geoip"

local _M = {}

-- 请求上下文
local function new_context()
    return {
        request_id = nil,
        provider = nil,
        provider_config = nil,
        start_time = ngx.now(),
        upstream_path = nil,
        client_ip = nil
    }
end

-- 生成 UUID
local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end
-- 获取请求 ID
local function get_request_id()
    local request_id = ngx.var.http_x_onekey_request_id
    if not request_id or request_id == "" then
        request_id = generate_uuid()
    end
    return request_id
end
-- 解析请求路径
local function parse_path(uri)
    -- 格式: /provider/path/to/resource
    local provider_name, path = uri:match("^/(%w+)/?(.*)$")
    return provider_name, path or ""
end
-- 获取客户端 IP
local function get_client_ip()
    -- 优先检查 X-Real-IP
    local real_ip = ngx.var.http_x_real_ip
    if real_ip and real_ip ~= "" then
        return real_ip
    end
    
    -- 检查 X-Forwarded-For（取第一个IP）
    local forwarded_for = ngx.var.http_x_forwarded_for
    if forwarded_for and forwarded_for ~= "" then
        local first_ip = forwarded_for:match("^%s*([^,]+)")
        if first_ip then
            return first_ip:gsub("%s+$", "")  -- 去除尾部空格
        end
    end
    
    -- 使用直接连接IP
    return ngx.var.remote_addr or "unknown"
end
--- 获取客户端传递的 API Key（用于 Alchemy URL拼接）
-- 支持两种方式：Header (X-API-Key) 或 URL 参数 (api_key)
-- @return string|nil API Key
local function get_client_api_key()
    -- 1. 优先从 Header 获取
    local api_key = ngx.var.http_x_api_key
    if api_key and api_key ~= "" then
        return api_key
    end
    
    -- 2. 从 URL 参数获取
    local args = ngx.req.get_uri_args()
    api_key = args.api_key
    if api_key and api_key ~= "" then
        return api_key
    end
    
    return nil
end

-- 构建上游 URL
-- @param provider_config table Provider配置
-- @param path string 请求路径
-- @return string|nil URL, string|nil 错误信息
local function build_upstream_url(provider_config, path)
    local endpoint = provider_config.endpoint
    local auth_type = provider_config.auth_type
    
    -- 获取查询字符串
    local query_string = ngx.var.query_string or ""
    
    local url
    if auth_type == "url" then
        -- Alchemy: 路径已经包含 v2/{api_key}/... 格式，直接透传
        -- 客户端请求格式: /alchemy/v2/{api_key}/method
        -- 上游格式: https://eth-mainnet.g.alchemy.com/v2/{api_key}/method
        if path and path ~= "" then
            url = endpoint .. "/" .. path
        else
            url = endpoint
        end
    else
        -- Zerion/CoinGecko: 直接拼接路径，认证信息通过Header透传
        if path and path ~= "" then
            url = endpoint .. "/" .. path
        else
            url = endpoint
        end
    end
    
    -- 添加查询字符串
    if query_string ~= "" then
        url = url .. "?" .. query_string
    end
    
    return url
end

-- 构建上游请求头
-- @param provider_config table Provider配置
-- @param request_id string 请求ID
-- @return table 请求头
local function build_upstream_headers(provider_config, request_id)
    local headers = {}
    
    -- 复制客户端 Header（过滤敏感 Header）
    -- 注意：Authorization 和 x_cg_* 等认证Header会被保留并透传
    local client_headers = ngx.req.get_headers()
    for k, v in pairs(client_headers) do
        local lower_k = string.lower(k)
        if not config.filtered_headers[lower_k] then
            if type(v) == "table" then
                headers[k] = table.concat(v, ", ")
            else
                headers[k] = v
            end
        end
    end
    
    -- 添加追踪 Header
    headers["X-Onekey-Request-Id"] = request_id
    headers["X-Forwarded-For"] = ngx.var.remote_addr
    headers["X-Real-IP"] = ngx.var.remote_addr
    
    return headers
end
-- 获取请求体
local function get_request_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    return body
end
-- 发送响应
local function send_response(response)
    -- 设置响应头
    if response.headers then
        for k, v in pairs(response.headers) do
            local lower_k = string.lower(k)
            -- 过滤一些不应传递的响应头
            if lower_k ~= "transfer-encoding" and lower_k ~= "connection" then
                ngx.header[k] = v
            end
        end
    end
    
    ngx.status = response.status
    if response.body then
        ngx.print(response.body)
    end
end
-- 发送错误响应
local function send_error(status, message, request_id)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = request_id or ""
    ngx.say(cjson.encode({
        error = message,
        request_id = request_id or ""
    }))
end
-- 主处理函数
function _M.handle()
    local ctx = new_context()
    ngx.ctx = ctx
    
    -- 1. 生成/获取请求 ID
    ctx.request_id = get_request_id()
    ngx.header["X-Onekey-Request-Id"] = ctx.request_id
    
    -- 2. 获取客户端 IP
    ctx.client_ip = get_client_ip()
    
    -- 3. 解析 Provider
    local uri = ngx.var.uri
    local provider_name, path = parse_path(uri)
    
    if not provider_name or not config.has_provider(provider_name) then
        return send_error(404, "Provider not found. Valid providers: /zerion, /coingecko, /alchemy", ctx.request_id)
    end
    
    ctx.provider = provider_name
    ctx.provider_config = config.get_provider(provider_name)
    ctx.upstream_path = path
    
    -- 设置 Nginx 变量用于日志
    ngx.var.provider = provider_name
    
    -- 4. 限流检查
    local rl_allowed, rl_reason = rate_limiter.check_rate_limit(provider_name, ctx.client_ip)
    if not rl_allowed then
        rate_limiter.send_rate_limited_response(rl_reason, 1)
        return
    end
    
    -- 5. 熔断检查
    local cb_allowed, cb_reason = circuit_breaker.allow_request(provider_name)
    if not cb_allowed then
        local retry_after = cb_reason
        circuit_breaker.send_open_response(provider_name, retry_after)
        return
    end
    
    -- 6. 构建上游请求
    local httpc = http.new()
    local timeout = ctx.provider_config.timeout or config.timeout.read
    httpc:set_timeout(timeout)
    
    local upstream_url, url_err = build_upstream_url(ctx.provider_config, path)
    if not upstream_url then
        return send_error(401, url_err or "API Key is required", ctx.request_id)
    end
    
    local upstream_headers = build_upstream_headers(ctx.provider_config, ctx.request_id)
    local method = ngx.req.get_method()
    local body = get_request_body()
    
    ngx.log(ngx.DEBUG, "[", ctx.request_id, "] Upstream URL: ", upstream_url)
    
    -- 7. 发送请求
    local response, err = httpc:request_uri(upstream_url, {
        method = method,
        headers = upstream_headers,
        body = body,
        ssl_verify = false,  -- 生产环境应启用
        keepalive_timeout = 60,
        keepalive_pool = 10
    })
    
    local duration = (ngx.now() - ctx.start_time) * 1000  -- 毫秒
    
    -- 8. 处理响应
    if response then
        -- 设置上游状态和响应时间变量（用于日志）
        ngx.var.lua_upstream_status = tostring(response.status)
        ngx.var.lua_upstream_response_time = string.format("%.3f", duration / 1000)
        
        ngx.log(ngx.INFO, "[", ctx.request_id, "] ", method, " ", uri, " -> ", response.status,
                " (", string.format("%.2f", duration), "ms)")
        
        -- 记录成功/失败（用于熔断器状态管理）
        -- 2xx和 3xx 视为成功，4xx 和 5xx 视为失败
        if response.status >= 200 and response.status < 400 then
            circuit_breaker.record_success(provider_name)
        else
            circuit_breaker.record_failure(provider_name)
        end
        
        return send_response(response)
    else
        -- 网络错误、超时等也需要记录失败
        -- 设置上游状态变量（用于日志）
        ngx.var.lua_upstream_status = "502"
        ngx.var.lua_upstream_response_time = string.format("%.3f", duration / 1000)
        
        circuit_breaker.record_failure(provider_name)
        ngx.log(ngx.ERR, "[", ctx.request_id, "] Upstream error: ", err)
        return send_error(502, "Bad Gateway: " .. (err or "unknown error"), ctx.request_id)
    end
end

return _M
