--- OpenResty API Proxy Gateway - 配置模块
-- 支持配置热更新，优先从 config_manager 加载配置
--

local cjson = require "cjson"
local _M = {}

-- 缓存 config_manager 模块
local config_manager_cached = nil

-- 获取 config_manager 模块（延迟加载避免循环依赖）
local function get_config_manager()
    if config_manager_cached then
        return config_manager_cached
    end
    
    local ok, cm = pcall(require, "config_manager")
    if ok and cm then
        config_manager_cached = cm
        return cm
    else
        ngx.log(ngx.WARN, "[Config] Failed to load config_manager: ", tostring(cm))
    end
    return nil
end

-- 超时配置（默认值）
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

-- 获取 Provider 配置
-- 认证方式说明：
-- 客户端统一通过 X-API-Key Header 传递 API_KEY
-- 网关根据各 provider 的 auth_format 配置，将 API_KEY 转换为上游所需格式
-- - Zerion: 转换为 Authorization: Basic {base64(api_key:)} Header
-- - CoinGecko: 转换为 x_cg_demo_api_key Header
-- - Alchemy: 拼接到 URL 路径 /v2/{api_key}/
function _M.get_provider(name)
    local cm = get_config_manager()
    local config
    
    if cm then
        config = cm.load_config()
    end
    
    -- Provider 默认配置
    local default_providers = {
        zerion = {
            name = "zerion",
            endpoint = "https://api.zerion.io",
            auth_type = "header",
            auth_format = "basic",
            timeout = 30000
        },
        coingecko = {
            name = "coingecko",
            endpoint = "https://api.coingecko.com",
            auth_type = "header",
            auth_format = "x_cg_demo_api_key",
            timeout = 30000
        },
        alchemy = {
            name = "alchemy",
            endpoint = "https://eth-mainnet.g.alchemy.com",
            auth_type = "url",
            auth_format = "path",
            timeout = 60000
        }
    }
    
    -- 从 config_manager 获取配置
    if config and config.providers and config.providers[name] then
        local provider_config = config.providers[name]
        return {
            name = name,
            endpoint = provider_config.endpoint or default_providers[name].endpoint,
            auth_type = default_providers[name].auth_type,
            auth_format = default_providers[name].auth_format,
            timeout = provider_config.timeout or default_providers[name].timeout
        }
    end
    
    -- 回退到环境变量（向后兼容）
    return {
        name = name,
        endpoint = os.getenv(string.upper(name) .. "_ENDPOINT") or default_providers[name].endpoint,
        auth_type = default_providers[name].auth_type,
        auth_format = default_providers[name].auth_format,
        timeout = default_providers[name].timeout
    }
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
    local cm = get_config_manager()
    
    if cm then
        local geoip_config = cm.get("geoip")
        if geoip_config then
            return geoip_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("GEOIP_ENABLED") or "false"
    local mode = os.getenv("GEOIP_MODE") or "blacklist"
    local countries_str = os.getenv("GEOIP_COUNTRIES") or ""
    local allow_unknown_str = os.getenv("GEOIP_ALLOW_UNKNOWN") or "true"
    
    -- 解析国家代码列表
    local countries = {}
    if countries_str and countries_str ~= "" then
        for country in string.gmatch(countries_str, "([^,]+)") do
            country = country:gsub("^%s*(.-)%s*$", "%1"):upper()
            countries[country] = true
        end
    end
    
    return {
        enabled = enabled_str:lower() == "true",
        mode = mode:lower(),
        countries = countries,
        allow_unknown = allow_unknown_str:lower() == "true"
    }
end

-- 获取熔断器配置
function _M.get_circuit_breaker_config()
    local cm = get_config_manager()
    
    if cm then
        local cb_config = cm.get("circuit_breaker")
        if cb_config then
            return cb_config
        end
    end
    
    -- 回退到环境变量
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
    local cm = get_config_manager()
    
    if cm then
        local rl_config = cm.get("rate_limiter")
        if rl_config then
            return rl_config
        end
    end
    
    -- 回退到环境变量
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
    local cm = get_config_manager()
    
    if cm then
        local cache_config = cm.get("cache")
        if cache_config then
            return cache_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("CACHE_ENABLED") or "false"
    local policy = os.getenv("CACHE_POLICY") or "get_only"
    local providers_str = os.getenv("CACHE_PROVIDERS") or '{"zerion":60,"coingecko":300,"alchemy":30}'
    local default_ttl = tonumber(os.getenv("CACHE_DEFAULT_TTL")) or 60
    local max_size = tonumber(os.getenv("CACHE_MAX_SIZE")) or 100
    
    -- 解析 Provider 缓存TTL配置
    local providers = {}
    local decode_ok, providers_data = pcall(cjson.decode, providers_str)
    if decode_ok and type(providers_data) == "table" then
        providers = providers_data
    end
    
    return {
        enabled = enabled_str:lower() == "true",
        policy = policy,
        providers = providers,
        default_ttl = default_ttl,
        max_size = max_size
    }
end

-- 获取响应转换配置
function _M.get_response_transform_config()
    local cm = get_config_manager()
    
    if cm then
        local transform_config = cm.get("response_transform")
        if transform_config then
            return transform_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("RESPONSE_TRANSFORM_ENABLED") or "false"
    local format = os.getenv("RESPONSE_FORMAT") or "unified"
    
    return {
        enabled = enabled_str:lower() == "true",
        format = format,
        include_meta = true
    }
end

-- 获取超时配置
function _M.get_timeout_config()
    local cm = get_config_manager()
    
    if cm then
        local timeout_config = cm.get("timeout")
        ngx.log(ngx.INFO, "[Config] get_timeout_config from config_manager: ",
                timeout_config and cjson.encode(timeout_config) or "nil")
        if timeout_config then
            return timeout_config
        end
    else
        ngx.log(ngx.WARN, "[Config] config_manager not available, using fallback")
    end
    
    -- 回退到环境变量
    local connect_timeout = tonumber(os.getenv("TIMEOUT_CONNECT")) or 5000
    local send_timeout = tonumber(os.getenv("TIMEOUT_SEND")) or 10000
    local read_timeout = tonumber(os.getenv("TIMEOUT_READ")) or 30000
    
    ngx.log(ngx.INFO, "[Config] get_timeout_config fallback: connect=", connect_timeout,
            ", send=", send_timeout, ", read=", read_timeout)
    
    return {
        connect = connect_timeout,
        send = send_timeout,
        read = read_timeout
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

-- 获取重试配置
function _M.get_retry_config()
    local cm = get_config_manager()
    
    if cm then
        local retry_config = cm.get("retry")
        if retry_config then
            return retry_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("RETRY_ENABLED") or "true"
    local max_attempts = tonumber(os.getenv("RETRY_MAX_ATTEMPTS")) or 3
    local initial_delay = tonumber(os.getenv("RETRY_INITIAL_DELAY")) or 3000
    local max_delay = tonumber(os.getenv("RETRY_MAX_DELAY")) or 30000
    local multiplier = tonumber(os.getenv("RETRY_MULTIPLIER")) or 2
    
    return {
        enabled = enabled_str:lower() == "true",
        max_attempts = max_attempts,
        initial_delay = initial_delay,
        max_delay = max_delay,
        multiplier = multiplier
    }
end

-- 获取降级配置
function _M.get_degradation_config()
    local cm = get_config_manager()
    
    if cm then
        local degradation_config = cm.get("degradation")
        if degradation_config then
            return degradation_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("DEGRADATION_ENABLED") or "true"
    local stale_cache_enabled_str = os.getenv("DEGRADATION_STALE_CACHE_ENABLED") or "true"
    local stale_cache_max_age = tonumber(os.getenv("DEGRADATION_STALE_CACHE_MAX_AGE")) or 300
    
    return {
        enabled = enabled_str:lower() == "true",
        stale_cache_enabled = stale_cache_enabled_str:lower() == "true",
        stale_cache_max_age = stale_cache_max_age
    }
end

-- 获取分布式限流配置
function _M.get_distributed_rate_limit_config()
    local cm = get_config_manager()
    
    if cm then
        local drl_config = cm.get("distributed_rate_limit")
        if drl_config then
            return drl_config
        end
    end
    
    -- 回退到环境变量
    local enabled_str = os.getenv("DISTRIBUTED_RATE_LIMIT_ENABLED") or "false"
    local redis_host = os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_HOST") or "redis"
    local redis_port = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_PORT")) or 6379
    local redis_password = os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_PASSWORD") or ""
    local redis_db = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_DB")) or 0
    local sync_interval = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_SYNC_INTERVAL")) or 1
    local local_ratio = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_LOCAL_RATIO")) or 0.2
    
    return {
        enabled = enabled_str:lower() == "true",
        redis_host = redis_host,
        redis_port = redis_port,
        redis_password = redis_password,
        redis_db = redis_db,
        sync_interval = sync_interval,
        local_ratio = local_ratio
    }
end

return _M
