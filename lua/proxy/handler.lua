--- OpenResty API Proxy Gateway - 代理处理器
-- 

local http = require "resty.http"
local cjson = require "cjson"
local config = require "config"

local _M = {}

-- 请求上下文
local function new_context()
    return {
        request_id = nil,
        provider = nil,
        provider_config = nil,
        start_time = ngx.now(),
        upstream_path = nil
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

-- 构建上游 URL
local function build_upstream_url(provider_config, path)
    local endpoint = provider_config.endpoint
    local auth_type = provider_config.auth_type
    local auth_key = provider_config.auth_key
    
    if auth_type == "url" then
        -- Alchemy: API Key 拼接在 URL 路径
        -- 格式: https://eth-mainnet.g.alchemy.com/v2/{api_key}/{path}
        return endpoint .. "/v2/" .. auth_key .. "/" .. path
    else
        -- 其他: 直接拼接路径
        if path and path ~= "" then
            return endpoint .. "/" .. path
        else
            return endpoint
        end
    end
end

-- 构建上游请求头
local function build_upstream_headers(provider_config, request_id)
    local headers = {}
    
    -- 复制客户端 Header（过滤敏感 Header）
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
    
    -- 注入认证信息
    local auth_type = provider_config.auth_type
    local auth_key = provider_config.auth_key
    
    if auth_type == "basic" then
        -- Basic Auth: API Key 作为用户名
        local auth = ngx.encode_base64(auth_key .. ":")
        headers["Authorization"] = "Basic " .. auth
    elseif auth_type == "header" then
        -- Header 传递 API Key
        headers[provider_config.auth_header] = auth_key
    end
    -- url 类型不需要在 Header 中注入认证
    
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
    
    -- 2. 解析 Provider
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
    
    -- 3. 构建上游请求
    local httpc = http.new()
    local timeout = ctx.provider_config.timeout or config.timeout.read
    httpc:set_timeout(timeout)
    
    local upstream_url = build_upstream_url(ctx.provider_config, path)
    local upstream_headers = build_upstream_headers(ctx.provider_config, ctx.request_id)
    local method = ngx.req.get_method()
    local body = get_request_body()
    
    ngx.log(ngx.DEBUG, "[", ctx.request_id, "] Upstream URL: ", upstream_url)
    
    -- 4. 发送请求
    local response, err = httpc:request_uri(upstream_url, {
        method = method,
        headers = upstream_headers,
        body = body,
        ssl_verify = false,  -- 生产环境应启用
        keepalive_timeout = 60,
        keepalive_pool = 10
    })
    
    local duration = (ngx.now() - ctx.start_time) * 1000  -- 毫秒
    
    -- 5. 处理响应
    if response then
        ngx.log(ngx.INFO, "[", ctx.request_id, "] ", method, " ", uri, " -> ", response.status, 
                " (", string.format("%.2f", duration), "ms)")
        return send_response(response)
    else
        ngx.log(ngx.ERR, "[", ctx.request_id, "] Upstream error: ", err)
        return send_error(502, "Bad Gateway: " .. (err or "unknown error"), ctx.request_id)
    end
end

return _M
