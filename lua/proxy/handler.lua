--- OpenResty API Proxy Gateway - 代理处理器
--

local http = require "resty.http"
local cjson = require "cjson"
local config = require "config"
local circuit_breaker = require "circuit_breaker"
local rate_limiter = require "rate_limiter"
local geoip = require "geoip"
local cache = require "cache"
local transformer = require "transformer"
local error_module = require "transformer.error"
local retry = require "retry"
local degradation = require "degradation"

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

--- 敏感信息脱敏处理
-- @param str string 需要脱敏的字符串
-- @param show_prefix number 显示前几个字符（默认4）
-- @param show_suffix number 显示后几个字符（默认4）
-- @return string 脱敏后的字符串
local function mask_sensitive(str, show_prefix, show_suffix)
    if not str or type(str) ~= "string" or str == "" then
        return str
    end
    
    show_prefix = show_prefix or 4
    show_suffix = show_suffix or 4
    
    local len = #str
    -- 如果字符串太短，只显示部分
    if len <= show_prefix + show_suffix then
        return string.sub(str, 1, math.floor(len / 2)) .. "****"
    end
    
    local prefix = string.sub(str, 1, show_prefix)
    local suffix = string.sub(str, -show_suffix)
    
    return prefix .. "****" .. suffix
end

--- 脱敏 API Key
-- @param api_key string API Key
-- @return string 脱敏后的API Key
local function mask_api_key(api_key)
    return mask_sensitive(api_key, 4, 4)
end

--- 脱敏钱包地址
-- @param address string 钱包地址
-- @return string 脱敏后的钱包地址
local function mask_wallet_address(address)
    return mask_sensitive(address, 6, 4)
end

--- 从URL中提取并脱敏API Key和钱包地址
-- @param url string 原始URL
-- @return string 脱敏后的URL
local function mask_url_api_key(url)
    if not url then return url end
    
    local masked_url = url
    
    -- 匹配 /v2/{api_key}/ 格式（Alchemy风格）
    masked_url = masked_url:gsub("(/v2/)([^/?]+)([/?]?)", function(prefix, api_key, suffix)
        return prefix .. mask_api_key(api_key) .. suffix
    end)
    
    -- 匹配 URL参数中的 api_key=xxx
    masked_url = masked_url:gsub("([?&]api_key=)([^&]+)", function(prefix, api_key)
        return prefix .. mask_api_key(api_key)
    end)
    
    -- 匹配以太坊钱包地址（0x开头，40个十六进制字符）
    -- 常见格式：/wallets/0x... /address/0x... 等
    masked_url = masked_url:gsub("(0x)([0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF])([0-9aA-fF]+)",
        function(prefix, first_chars, rest)
            if #first_chars + #rest == 40 then
                return mask_wallet_address(prefix .. first_chars .. rest)
            end
            return prefix .. first_chars .. rest
        end)
    
    return masked_url
end

--- 脱敏请求体中的钱包地址
-- @param body string 请求体（JSON格式）
-- @return string 脱敏后的请求体
local function mask_body_wallet_addresses(body)
    if not body or type(body) ~= "string" or body == "" then
        return body
    end
    
    -- 匹配以太坊地址格式（0x开头，40个十六进制字符）
    local masked_body = body:gsub('"0x([0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF][0-9aA-fF])([0-9aA-fF]+)"',
        function(prefix, rest)
            local full_addr = prefix .. rest
            if #full_addr == 40 then
                return '"' .. mask_wallet_address("0x" .. full_addr) .. '"'
            end
            return '"0x' .. prefix .. rest .. '"'
        end)
    
    return masked_body
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
--- 获取客户端传递的 API Key
-- 统一从 X-API-Key Header 获取
-- @return string|nil API Key
local function get_client_api_key()
    local api_key = ngx.var.http_x_api_key
    if api_key and api_key ~= "" then
        return api_key
    end
    return nil
end

--- Base64 编码函数
-- @param str string 需要编码的字符串
-- @return string Base64编码后的字符串
local function base64_encode(str)
    return ngx.encode_base64(str)
end

--- 构建认证 Header
-- 根据provider配置将API_KEY转换为上游所需的认证格式
-- @param provider_config table Provider配置
-- @param api_key string 客户端传递的API Key
-- @return table 认证Header键值对
local function build_auth_headers(provider_config, api_key)
    local auth_headers = {}
    local auth_type = provider_config.auth_type
    local auth_format = provider_config.auth_format
    
    if auth_type == "header" and api_key then
        if auth_format == "basic" then
            -- Zerion: Basic Auth 格式
            -- Authorization: Basic base64(api_key:)
            local credentials = base64_encode(api_key .. ":")
            auth_headers["Authorization"] = "Basic " .. credentials
        elseif auth_format then
            -- CoinGecko 等其他自定义 Header 格式
            -- 直接使用 auth_format 作为 Header 名称
            auth_headers[auth_format] = api_key
        end
    end
    
    return auth_headers
end

-- 构建上游 URL
-- @param provider_config table Provider配置
-- @param path string 请求路径
-- @param api_key string|nil 客户端传递的API Key
-- @return string|nil URL, string|nil 错误信息
local function build_upstream_url(provider_config, path, api_key)
    local endpoint = provider_config.endpoint
    local auth_type = provider_config.auth_type
    local auth_format = provider_config.auth_format
    
    -- 获取查询字符串
    local query_string = ngx.var.query_string or ""
    
    -- 清理路径：移除首尾斜杠
    local clean_path = path or ""
    clean_path = clean_path:gsub("^/+", ""):gsub("/+$", "")
    
    -- 调试日志
    ngx.log(ngx.DEBUG, "build_upstream_url: endpoint=", endpoint,
            ", auth_type=", auth_type, ", auth_format=", auth_format,
            ", path=", path or "nil", ", clean_path=", clean_path,
            ", api_key=", api_key and mask_api_key(api_key) or "nil")
    
    local url
    if auth_type == "url" then
        -- Alchemy: 需要将 API Key 插入到 URL 路径中
        -- 客户端请求格式: /alchemy/v2/ 或 /alchemy/v2/method
        -- 上游格式: https://eth-mainnet.g.alchemy.com/v2/{api_key}/ 或 /v2/{api_key}/method
        if not api_key then
            return nil, "API Key is required via X-API-Key header"
        end
        
        if auth_format == "path" then
            -- Alchemy URL格式: /v2/{api_key} 或 /v2/{api_key}/xxx
            -- 检测路径是否以 v2 开头（可能是 v2 或 v2/xxx）
            if clean_path == "v2" or clean_path:match("^v2/") then
                -- 将 v2 或 v2/xxx 转换为 v2/{api_key} 或 v2/{api_key}/xxx
                local rest_path = ""
                if clean_path:match("^v2/(.+)$") then
                    rest_path = clean_path:match("^v2/(.+)$")
                end
                
                if rest_path and rest_path ~= "" then
                    url = endpoint .. "/v2/" .. api_key .. "/" .. rest_path
                else
                    url = endpoint .. "/v2/" .. api_key
                end
            elseif clean_path == "" then
                -- 路径为空，直接构建 /v2/{api_key}
                url = endpoint .. "/v2/" .. api_key
            else
                -- 其他路径，在前面添加 /v2/{api_key}/
                url = endpoint .. "/v2/" .. api_key .. "/" .. clean_path
            end
        else
            -- 其他URL格式，直接拼接
            if clean_path ~= "" then
                url = endpoint .. "/" .. clean_path
            else
                url = endpoint
            end
        end
    else
        -- Zerion/CoinGecko: 直接拼接路径，认证信息通过Header注入
        if clean_path ~= "" then
            url = endpoint .. "/" .. clean_path
        else
            url = endpoint
        end
    end
    
    -- 添加查询字符串
    if query_string ~= "" then
        url = url .. "?" .. query_string
    end
    
    -- 调试日志：输出最终URL
    ngx.log(ngx.DEBUG, "build_upstream_url: final_url=", mask_url_api_key(url))
    
    return url
end

-- 构建上游请求头
-- @param provider_config table Provider配置
-- @param request_id string 请求ID
-- @param api_key string|nil 客户端传递的API Key
-- @return table 请求头
local function build_upstream_headers(provider_config, request_id, api_key)
    local headers = {}
    
    -- 复制客户端 Header（过滤敏感 Header）
    -- 注意：不再透传客户端的认证Header，由网关统一注入
    local client_headers = ngx.req.get_headers()
    local filtered_auth_headers = {
        ["authorization"] = true,
        ["x-api-key"] = true,
        ["x_cg_pro_api_key"] = true,
        ["x_cg_demo_api_key"] = true
    }
    
    for k, v in pairs(client_headers) do
        local lower_k = string.lower(k)
        if not config.filtered_headers[lower_k] and not filtered_auth_headers[lower_k] then
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
    
    -- 根据 provider 配置注入认证 Header
    if api_key then
        local auth_headers = build_auth_headers(provider_config, api_key)
        for k, v in pairs(auth_headers) do
            headers[k] = v
        end
    end
    
    return headers
end
-- 获取请求体
local function get_request_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    return body
end
-- 发送响应
local function send_response(response, ctx)
    ngx.log(ngx.INFO, "[Proxy] send_response called, provider: ", ctx and ctx.provider or "nil")
    
    -- 检查是否启用响应转换
    local transform_enabled = transformer.is_enabled()
    ngx.log(ngx.INFO, "[Proxy] transform_enabled: ", tostring(transform_enabled))
    
    if transform_enabled then
        -- 使用统一格式响应
        ngx.log(ngx.INFO, "[Proxy] Using unified response format")
        local transformed = transformer.transform_response(ctx.provider, response, ctx)
        transformer.send_transformed_response(transformed, response)
        return
    end
    
    -- 原始透传逻辑（向后兼容）
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
local function send_error(status, message, ctx, error_type)
    -- 检查是否启用响应转换
    if transformer.is_enabled() then
        -- 使用统一格式错误响应
        local request_id = ctx and ctx.request_id or ""
        local transformed = transformer.transform_error(status, message, ctx, error_type)
        ngx.status = status
        ngx.header["Content-Type"] = "application/json"
        ngx.header["X-Onekey-Request-Id"] = request_id
        ngx.say(cjson.encode(transformed))
        return
    end
    
    -- 原始错误格式（向后兼容）
    local request_id = ctx and ctx.request_id or ""
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = request_id
    ngx.say(cjson.encode({
        error = message,
        request_id = request_id
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
        return send_error(404, "Provider not found. Valid providers: /zerion, /coingecko, /alchemy", ctx, error_module.ERROR_TYPE.NOT_FOUND_ERROR)
    end
    
    ctx.provider = provider_name
    ctx.provider_config = config.get_provider(provider_name)
    ctx.upstream_path = path
    
    -- 设置 Nginx 变量用于日志
    ngx.var.provider = provider_name
    -- 设置脱敏后的路径用于访问日志
    ngx.var.masked_path = mask_url_api_key(uri)
    
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
    
    -- 6. 获取客户端 API Key
    local api_key = get_client_api_key()
    local method = ngx.req.get_method()
    local body = get_request_body()
    
    -- 7. 缓存检查（仅对可缓存请求）
    local cache_key = nil
    local cache_ttl = nil
    local cache_config = config.get_cache_config()
    local cache_status = "BYPASS"  -- 默认绕过缓存
    
    -- 使用INFO级别确保日志输出
    ngx.log(ngx.INFO, "[Cache] config: enabled=", tostring(cache_config.enabled),
            ", policy=", cache_config.policy or "nil",
            ", provider_ttl=", tostring(cache_config.providers[provider_name]))
    
    if cache.is_cacheable(provider_name, method, ctx.provider_config) then
        cache_ttl = cache_config.providers[provider_name] or cache_config.default_ttl
        cache_key = cache.generate_cache_key(provider_name, method, ngx.var.uri, body)
        cache_status = "MISS"  -- 可缓存，标记为MISS
        
        ngx.log(ngx.INFO, "[Cache] key: ", cache_key, ", TTL: ", tostring(cache_ttl))
        
        -- 尝试从缓存获取
        local cached_response = cache.get(cache_key)
        if cached_response then
            -- 缓存命中，直接返回
            cache_status = "HIT"
            ctx.cache_status = cache_status
            ngx.log(ngx.INFO, "[Cache] HIT: ", provider_name, " ", method, " ", mask_url_api_key(ngx.var.uri))
            
            -- 构建响应对象（用于转换器）
            local response_obj = {
                status = cached_response.status,
                headers = cached_response.headers or {},
                body = cached_response.body
            }
            response_obj.headers["X-Cache-Status"] = "HIT"
            response_obj.headers["X-Cache-TTL"] = tostring(math.floor(cached_response.expires_at - ngx.now()))
            
            -- 使用send_response处理（支持响应转换）
            return send_response(response_obj, ctx)
        else
            ngx.log(ngx.INFO, "[Cache] MISS: ", provider_name, " ", method, " ", mask_url_api_key(ngx.var.uri))
        end
    end
    
    -- 设置缓存状态到上下文，用于后续添加响应头
    ctx.cache_status = cache_status
    ctx.cache_key = cache_key
    ctx.cache_ttl = cache_ttl
    
    -- 8. 构建上游请求
    local httpc = http.new()
    local timeout = config.get_provider_timeout(provider_name)
    httpc:set_timeout(timeout)
    
    local upstream_url, url_err = build_upstream_url(ctx.provider_config, path, api_key)
    if not upstream_url then
        return send_error(401, url_err or "API Key is required", ctx, error_module.ERROR_TYPE.AUTH_ERROR)
    end
    
    local upstream_headers = build_upstream_headers(ctx.provider_config, ctx.request_id, api_key)
    
    -- 脱敏后的URL用于日志记录
    local masked_url = mask_url_api_key(upstream_url)
    ngx.log(ngx.DEBUG, "[", ctx.request_id, "] Provider: ", provider_name, ", Upstream URL: ", masked_url)
    
    -- 脱敏请求体用于日志记录
    local masked_body = mask_body_wallet_addresses(body)
    if masked_body and masked_body ~= "" then
        ngx.log(ngx.DEBUG, "[", ctx.request_id, "] Request Body: ", masked_body)
    end
    
    -- 9. 发送请求（带重试）
    local request_fn = function()
        -- 每次重试需要创建新的HTTP连接
        local retry_httpc = http.new()
        retry_httpc:set_timeout(timeout)
        
        local res, req_err = retry_httpc:request_uri(upstream_url, {
            method = method,
            headers = upstream_headers,
            body = body,
            ssl_verify = false,  -- 生产环境应启用
            keepalive_timeout = 60,
            keepalive_pool = 10
        })
        
        return res, req_err
    end
    
    local response, err = retry.do_with_retry(request_fn, method, provider_name, ctx)
    
    local duration = (ngx.now() - ctx.start_time) * 1000  -- 毫秒
    
    -- 9. 处理响应
    if response then
        -- 设置上游状态和响应时间变量（用于日志）
        ngx.var.lua_upstream_status = tostring(response.status)
        ngx.var.lua_upstream_response_time = string.format("%.3f", duration / 1000)
        
        -- 脱敏URI用于日志（处理可能包含API Key的URI）
        local masked_uri = mask_url_api_key(uri)
        ngx.log(ngx.INFO, "[", ctx.request_id, "] Provider: ", provider_name, ", ", method, " ", masked_uri, " -> ", response.status,
                " (", string.format("%.2f", duration), "ms)")
        
        -- 记录成功/失败（用于熔断器状态管理）
        -- 2xx和 3xx 视为成功，4xx 和 5xx 视为失败
        if response.status >= 200 and response.status < 400 then
            circuit_breaker.record_success(provider_name)
            
            -- 10. 保存到缓存（仅对可缓存的请求）
            if ctx.cache_key and ctx.cache_ttl then
                cache.set(ctx.cache_key, response, ctx.cache_ttl)
            end
        else
            circuit_breaker.record_failure(provider_name)
        end
        
        -- 添加缓存状态响应头
        if not response.headers then
            response.headers = {}
        end
        response.headers["X-Cache-Status"] = ctx.cache_status or "BYPASS"
        
        return send_response(response, ctx)
    else
        -- 网络错误、超时等也需要记录失败
        -- 设置上游状态变量（用于日志）
        ngx.var.lua_upstream_status = "502"
        ngx.var.lua_upstream_response_time = string.format("%.3f", duration / 1000)
        
        circuit_breaker.record_failure(provider_name)
        -- 脱敏URI用于错误日志
        local masked_uri = mask_url_api_key(uri)
        ngx.log(ngx.ERR, "[", ctx.request_id, "] Provider: ", provider_name, ", URI: ", masked_uri, ", Upstream error: ", err)
        
        -- 尝试优雅降级
        local degradation_type = degradation.DEGRADATION_TYPE.UPSTREAM_ERROR
        if err and string.find(string.lower(err), "timeout", 1, true) then
            degradation_type = degradation.DEGRADATION_TYPE.TIMEOUT
        end
        
        local degraded = degradation.try_degrade(ctx.cache_key, ctx, degradation_type, {
            status = 502,
            message = "Bad Gateway",
            detail = "上游服务不可用: " .. (err or "unknown error"),
            retry_after = 30
        })
        
        -- 如果降级成功，直接返回（响应已发送）
        if degraded then
            return
        end
        
        -- 降级失败，返回标准错误响应
        return send_error(502, "Bad Gateway: " .. (err or "unknown error"), ctx, error_module.ERROR_TYPE.UPSTREAM_ERROR)
    end
end

return _M
