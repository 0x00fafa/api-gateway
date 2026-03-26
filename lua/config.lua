--- OpenResty API Proxy Gateway - 配置模块
--

local cjson = require "cjson"
local _M = {}

-- 超时配置
_M.timeout = {
    connect = 5000,   -- 连接超时（毫秒）
    send = 10000,     -- 发送超时（毫秒）
    read = 30000      -- 读取超时（毫秒）
}

-- 需要过滤的 Header（不转发到上游）
_M.filtered_headers = {
    ["host"] = true,
    ["connection"] = true,
    ["keep-alive"] = true,
    ["transfer-encoding"] = true,
    ["te"] = true,
    ["trailer"] = true,
    ["upgrade"] = true,
    ["proxy-authorization"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-connection"] = true
}

-- 获取 Provider 配置（每次请求都重新读取环境变量）
-- 认证方式说明：
-- 客户端统一通过 X-API-Key Header 传递 API_KEY
-- 网关根据各 provider 的 auth_format 配置，将 API_KEY 转换为上游所需格式
-- - Zerion: 转换为 Authorization: Basic {base64(api_key:)} Header
-- - CoinGecko: 转换为 x_cg_demo_api_key Header
-- - Alchemy: 拼接到 URL 路径 /v2/{api_key}/
function _M.get_provider(name)
    local providers = {
        zerion = {
            name = "zerion",
            endpoint = os.getenv("ZERION_ENDPOINT") or "https://api.zerion.io",
            auth_type = "header",  -- 认证信息注入到 Header
            auth_format = "basic",  -- Basic Auth 格式: Authorization: Basic base64(api_key:)
            timeout = 30000  -- 30秒
        },
        coingecko = {
            name = "coingecko",
            endpoint = os.getenv("COINGECKO_ENDPOINT") or "https://api.coingecko.com",
            auth_type = "header",  -- 认证信息注入到 Header
            auth_format = "x_cg_demo_api_key",  -- 自定义 Header 名称
            timeout = 30000
        },
        alchemy = {
            name = "alchemy",
            endpoint = os.getenv("ALCHEMY_ENDPOINT") or "https://eth-mainnet.g.alchemy.com",
            auth_type = "url",  -- API Key 拼接在 URL 路径
            auth_format = "path",  -- 路径格式: /v2/{api_key}/
            timeout = 60000  -- 60秒，区块链查询可能较慢
        }
    }
    return providers[name]
end

-- 检查 Provider 是否存在
function _M.has_provider(name)
    local providers = {
        zerion = true,
        coingecko = true,
        alchemy = true
    }
    return providers[name] ~= nil
end

-- 获取 GeoIP 访问控制配置
function _M.get_geoip_config()
    local enabled_str = os.getenv("GEOIP_ENABLED") or "false"
    local mode = os.getenv("GEOIP_MODE") or "blacklist"
    local countries_str = os.getenv("GEOIP_COUNTRIES") or ""
    local allow_unknown_str = os.getenv("GEOIP_ALLOW_UNKNOWN") or "true"
    
    -- 解析国家代码列表
    local countries = {}
    if countries_str and countries_str ~= "" then
        for country in string.gmatch(countries_str, "([^,]+)") do
            -- 去除空格并转为大写
            country = country:gsub("^%s*(.-)%s*$", "%1"):upper()
            countries[country] = true
        end
    end
    
    return {
        enabled = enabled_str:lower() == "true",
        mode = mode:lower(),  -- "blacklist" or "whitelist"
        countries = countries,
        allow_unknown = allow_unknown_str:lower() == "true"
    }
end

-- 获取熔断器配置
function _M.get_circuit_breaker_config()
    local enabled_str = os.getenv("CIRCUIT_BREAKER_ENABLED") or "false"
    local failure_threshold = tonumber(os.getenv("CIRCUIT_BREAKER_FAILURE_THRESHOLD")) or 5
    local success_threshold = tonumber(os.getenv("CIRCUIT_BREAKER_SUCCESS_THRESHOLD")) or 3
    local timeout = tonumber(os.getenv("CIRCUIT_BREAKER_TIMEOUT")) or 30
    local half_open_requests = tonumber(os.getenv("CIRCUIT_BREAKER_HALF_OPEN_REQUESTS")) or 3
    
    return {
        enabled = enabled_str:lower() == "true",
        failure_threshold = failure_threshold,
        success_threshold = success_threshold,
        timeout = timeout,
        half_open_requests = half_open_requests
    }
end

-- 获取限流器配置
function _M.get_rate_limiter_config()
    local enabled_str = os.getenv("RATE_LIMITER_ENABLED") or "false"
    local global = tonumber(os.getenv("RATE_LIMIT_GLOBAL")) or 10000
    local providers_str = os.getenv("RATE_LIMIT_PROVIDERS") or '{"zerion":100,"coingecko":500,"alchemy":200}'
    local ip = tonumber(os.getenv("RATE_LIMIT_IP")) or 100
    local ip_burst = tonumber(os.getenv("RATE_LIMIT_IP_BURST")) or 20
    local api_key = tonumber(os.getenv("RATE_LIMIT_API_KEY")) or 1000
    local api_key_burst = tonumber(os.getenv("RATE_LIMIT_API_KEY_BURST")) or 100
    local uri = tonumber(os.getenv("RATE_LIMIT_URI")) or 50
    local uri_burst = tonumber(os.getenv("RATE_LIMIT_URI_BURST")) or 10
    
    -- 解析 Provider 限流配置
    local providers = {}
    local decode_ok, providers_data = pcall(cjson.decode, providers_str)
    if decode_ok and type(providers_data) == "table" then
        providers = providers_data
    end
    
    return {
        enabled = enabled_str:lower() == "true",
        global = global,
        providers = providers,
        ip = ip,
        ip_burst = ip_burst,
        api_key = api_key,
        api_key_burst = api_key_burst,
        uri = uri,
        uri_burst = uri_burst
    }
end

-- 获取缓存配置
function _M.get_cache_config()
    local enabled_str = os.getenv("CACHE_ENABLED") or "false"
    local policy = os.getenv("CACHE_POLICY") or "get_only"  -- never, get_only, all
    local providers_str = os.getenv("CACHE_PROVIDERS") or '{"zerion":60,"coingecko":300,"alchemy":30}'
    local default_ttl = tonumber(os.getenv("CACHE_DEFAULT_TTL")) or 60
    local max_size = tonumber(os.getenv("CACHE_MAX_SIZE")) or 100  -- MB
    
    -- 解析 Provider 缓存TTL配置
    local providers = {}
    local decode_ok, providers_data = pcall(cjson.decode, providers_str)
    if decode_ok and type(providers_data) == "table" then
        providers = providers_data
    end
    
    return {
        enabled = enabled_str:lower() == "true",
        policy = policy,  -- never, get_only, all
        providers = providers,
        default_ttl = default_ttl,
        max_size = max_size
    }
end

-- 获取响应转换配置
function _M.get_response_transform_config()
    local enabled_str = os.getenv("RESPONSE_TRANSFORM_ENABLED") or "false"
    local format = os.getenv("RESPONSE_FORMAT") or "unified"  -- unified / raw
    
    return {
        enabled = enabled_str:lower() == "true",
        format = format,  -- unified: 统一格式, raw: 原始格式
        include_meta = true  -- 是否包含meta信息
    }
end

-- 获取超时配置
function _M.get_timeout_config()
    local connect_timeout = tonumber(os.getenv("TIMEOUT_CONNECT")) or 5000
    local send_timeout = tonumber(os.getenv("TIMEOUT_SEND")) or 10000
    local read_timeout = tonumber(os.getenv("TIMEOUT_READ")) or 30000
    
    return {
        connect = connect_timeout,  -- 连接超时（毫秒）
        send = send_timeout,        -- 发送超时（毫秒）
        read = read_timeout         -- 读取超时（毫秒）
    }
end

-- 获取Provider超时配置（覆盖全局配置）
function _M.get_provider_timeout(provider_name)
    local provider = _M.get_provider(provider_name)
    if provider and provider.timeout then
        return provider.timeout
    end
    return _M.get_timeout_config().read
end

return _M
