--- OpenResty API Proxy Gateway - 配置管理模块
-- 实现配置热更新功能，配置存储在共享内存或Redis中
--

local cjson = require "cjson"

local _M = {
    _VERSION = '1.0.0'
}

-- 配置存储键前缀
local CONFIG_KEY_PREFIX = "config:"

-- 默认配置（当Redis不可用时使用）
local DEFAULT_CONFIG = {
    -- Provider配置
    providers = {
        zerion = {
            endpoint = "https://api.zerion.io",
            timeout = 30000
        },
        coingecko = {
            endpoint = "https://api.coingecko.com",
            timeout = 30000
        },
        alchemy = {
            endpoint = "https://eth-mainnet.g.alchemy.com",
            timeout = 60000
        }
    },
    -- 超时配置
    timeout = {
        connect = 5000,
        send = 10000,
        read = 30000
    },
    -- 熔断器配置
    circuit_breaker = {
        enabled = false,
        failure_threshold = 5,
        success_threshold = 3,
        timeout = 30,
        half_open_requests = 3
    },
    -- 限流器配置
    rate_limiter = {
        enabled = false,
        global = 10000,
        providers = {
            zerion = 100,
            coingecko = 500,
            alchemy = 200
        },
        ip = 100,
        ip_burst = 20,
        api_key = 1000,
        api_key_burst = 100,
        uri = 50,
        uri_burst = 10
    },
    -- 缓存配置
    cache = {
        enabled = false,
        policy = "get_only",
        providers = {
            zerion = 60,
            coingecko = 300,
            alchemy = 30
        },
        default_ttl = 60,
        max_size = 100
    },
    -- 重试配置
    retry = {
        enabled = true,
        max_attempts = 3,
        initial_delay = 3000,
        max_delay = 30000,
        multiplier = 2
    },
    -- 降级配置
    degradation = {
        enabled = true,
        stale_cache_enabled = true,
        stale_cache_max_age = 300
    },
    -- 响应转换配置
    response_transform = {
        enabled = true,
        format = "unified"
    },
    -- 分布式限流配置
    distributed_rate_limit = {
        enabled = false,
        redis_host = "redis",
        redis_port = 6379,
        redis_password = "",
        redis_db = 0,
        sync_interval = 1,
        local_ratio = 0.2
    },
    -- GeoIP配置
    geoip = {
        enabled = false,
        mode = "blacklist",
        countries = {},
        allow_unknown = true
    }
}

-- 配置版本
local config_version = 0
local config_loaded_at = 0

--- 获取共享内存字典
local function get_shared_dict()
    local dict = ngx.shared.config_cache
    if not dict then
        ngx.log(ngx.WARN, "[ConfigManager] Shared dict 'config_cache' not found")
        return nil
    end
    return dict
end

--- 从 .env 文件读取配置
-- @param filepath string 文件路径
-- @return table|nil 配置表
local function load_config_from_env_file(filepath)
    filepath = filepath or "/usr/local/openresty/lualib/custom/.env"
    
    local file, err = io.open(filepath, "r")
    if not file then
        ngx.log(ngx.DEBUG, "[ConfigManager] Cannot open env file: ", filepath, " ", err or "unknown")
        return nil
    end
    
    local env_vars = {}
    for line in file:lines() do
        -- 跳过注释和空行
        line = line:gsub("^%s*(.-)%s*$", "%1")  -- 去除首尾空格
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                key = key:gsub("^%s*(.-)%s*$", "%1")
                value = value:gsub("^%s*(.-)%s*$", "%1")
                -- 移除引号
                value = value:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", "%1")
                env_vars[key] = value
            end
        end
    end
    file:close()
    
    return env_vars
end

--- 从环境变量加载基础配置
-- @return table 基础配置
local function load_base_config_from_env()
    local base_config = {}
    
    -- 首先尝试从 .env 文件读取
    local env_file_vars = load_config_from_env_file()
    
    -- 辅助函数：优先从 os.getenv 获取，否则从 .env 文件获取
    local function get_env(key, default)
        local val = os.getenv(key)
        if val then return val end
        if env_file_vars and env_file_vars[key] then
            return env_file_vars[key]
        end
        return default
    end
    
    -- Redis连接信息
    base_config.redis_host = get_env("REDIS_HOST", "redis")
    base_config.redis_port = tonumber(get_env("REDIS_PORT")) or 6379
    base_config.redis_password = get_env("REDIS_PASSWORD", "")
    base_config.redis_db = tonumber(get_env("REDIS_DB")) or 0
    
    -- 配置来源
    base_config.config_source = get_env("CONFIG_SOURCE", "local")
    
    return base_config, env_file_vars
end

--- 从共享内存加载配置
-- @return table|nil 配置表
local function load_config_from_shared_dict()
    local dict = get_shared_dict()
    if not dict then
        return nil
    end
    
    local config_str, err = dict:get(CONFIG_KEY_PREFIX .. "main")
    if err then
        ngx.log(ngx.WARN, "[ConfigManager] Failed to get config: ", err)
        return nil
    end
    
    if not config_str then
        return nil
    end
    
    local decode_ok, config = pcall(cjson.decode, config_str)
    if not decode_ok then
        ngx.log(ngx.WARN, "[ConfigManager] Failed to decode config")
        return nil
    end
    
    return config
end

--- 保存配置到共享内存
-- @param config table 配置表
-- @return boolean 是否成功
local function save_config_to_shared_dict(config)
    local dict = get_shared_dict()
    if not dict then
        return false
    end
    
    local encode_ok, config_str = pcall(cjson.encode, config)
    if not encode_ok then
        ngx.log(ngx.WARN, "[ConfigManager] Failed to encode config")
        return false
    end
    
    local success, err = dict:set(CONFIG_KEY_PREFIX .. "main", config_str)
    if err then
        ngx.log(ngx.WARN, "[ConfigManager] Failed to save config: ", err)
        return false
    end
    
    -- 更新版本号
    dict:incr(CONFIG_KEY_PREFIX .. "version", 1)
    
    return true
end

--- 获取配置版本
-- @return number 配置版本
function _M.get_config_version()
    local dict = get_shared_dict()
    if not dict then
        return 0
    end
    
    local version = dict:get(CONFIG_KEY_PREFIX .. "version")
    return tonumber(version) or 0
end

--- 加载配置（主入口）
-- 优先级：共享内存 > 环境变量 > 默认配置
-- @param force_reload boolean 是否强制重新加载
-- @return table 配置表
function _M.load_config(force_reload)
    local now = ngx.now()
    
    -- 检查是否需要重新加载（每5秒最多加载一次）
    if not force_reload and config_loaded_at > 0 and (now - config_loaded_at) < 5 then
        -- 返回缓存的配置
        return _M.get_cached_config()
    end
    
    -- 1. 尝试从共享内存加载
    local config = load_config_from_shared_dict()
    if config then
        ngx.log(ngx.DEBUG, "[ConfigManager] Loaded config from shared dict")
        config_loaded_at = now
        return config
    end
    
    -- 2. 从环境变量加载（向后兼容）
    config = _M.load_config_from_env()
    if config then
        ngx.log(ngx.DEBUG, "[ConfigManager] Loaded config from env")
        config_loaded_at = now
        -- 保存到共享内存供后续使用
        save_config_to_shared_dict(config)
        return config
    end
    
    -- 3. 使用默认配置
    ngx.log(ngx.DEBUG, "[ConfigManager] Using default config")
    config_loaded_at = now
    return DEFAULT_CONFIG
end

--- 从环境变量加载配置（向后兼容）
-- 优先从 os.getenv 获取，其次从 .env 文件获取
-- @return table 配置表
function _M.load_config_from_env()
    local config = {}
    
    -- 复制默认配置结构
    for k, v in pairs(DEFAULT_CONFIG) do
        if type(v) == "table" then
            config[k] = {}
            for kk, vv in pairs(v) do
                config[k][kk] = vv
            end
        else
            config[k] = v
        end
    end
    
    -- 加载 .env 文件（作为备选配置源）
    local env_file_vars = load_config_from_env_file()
    
    -- 辅助函数：优先从 os.getenv 获取，否则从 .env 文件获取
    local function get_env(key, default)
        local val = os.getenv(key)
        if val then return val end
        if env_file_vars and env_file_vars[key] then
            return env_file_vars[key]
        end
        return default
    end
    
    -- 从环境变量/.env文件覆盖配置
    -- Provider配置
    config.providers.zerion.endpoint = get_env("ZERION_ENDPOINT", config.providers.zerion.endpoint)
    config.providers.coingecko.endpoint = get_env("COINGECKO_ENDPOINT", config.providers.coingecko.endpoint)
    config.providers.alchemy.endpoint = get_env("ALCHEMY_ENDPOINT", config.providers.alchemy.endpoint)
    
    -- 熔断器配置
    config.circuit_breaker.enabled = (get_env("CIRCUIT_BREAKER_ENABLED", "false")):lower() == "true"
    config.circuit_breaker.failure_threshold = tonumber(get_env("CIRCUIT_BREAKER_FAILURE_THRESHOLD")) or config.circuit_breaker.failure_threshold
    config.circuit_breaker.success_threshold = tonumber(get_env("CIRCUIT_BREAKER_SUCCESS_THRESHOLD")) or config.circuit_breaker.success_threshold
    config.circuit_breaker.timeout = tonumber(get_env("CIRCUIT_BREAKER_TIMEOUT")) or config.circuit_breaker.timeout
    
    -- 限流器配置
    config.rate_limiter.enabled = (get_env("RATE_LIMITER_ENABLED", "false")):lower() == "true"
    config.rate_limiter.global = tonumber(get_env("RATE_LIMIT_GLOBAL")) or config.rate_limiter.global
    config.rate_limiter.ip = tonumber(get_env("RATE_LIMIT_IP")) or config.rate_limiter.ip
    
    -- 缓存配置
    config.cache.enabled = (get_env("CACHE_ENABLED", "false")):lower() == "true"
    config.cache.policy = get_env("CACHE_POLICY", config.cache.policy)
    
    -- 重试配置
    config.retry.enabled = (get_env("RETRY_ENABLED", "true")):lower() == "true"
    config.retry.initial_delay = tonumber(get_env("RETRY_INITIAL_DELAY")) or config.retry.initial_delay
    config.retry.max_delay = tonumber(get_env("RETRY_MAX_DELAY")) or config.retry.max_delay
    
    -- 降级配置
    config.degradation.enabled = (get_env("DEGRADATION_ENABLED", "true")):lower() == "true"
    
    -- 响应转换配置
    config.response_transform.enabled = (get_env("RESPONSE_TRANSFORM_ENABLED", "true")):lower() == "true"
    
    -- 分布式限流配置
    config.distributed_rate_limit.enabled = (get_env("DISTRIBUTED_RATE_LIMIT_ENABLED", "false")):lower() == "true"
    config.distributed_rate_limit.redis_host = get_env("DISTRIBUTED_RATE_LIMIT_REDIS_HOST", config.distributed_rate_limit.redis_host)
    config.distributed_rate_limit.redis_port = tonumber(get_env("DISTRIBUTED_RATE_LIMIT_REDIS_PORT")) or config.distributed_rate_limit.redis_port
    
    -- GeoIP配置
    config.geoip.enabled = (get_env("GEOIP_ENABLED", "false")):lower() == "true"
    
    return config
end

--- 获取缓存的配置
-- @return table 配置表
function _M.get_cached_config()
    -- 简单实现：直接从共享内存获取
    return load_config_from_shared_dict() or DEFAULT_CONFIG
end

--- 更新配置
-- @param new_config table 新配置
-- @return boolean 是否成功, string|nil 错误信息
function _M.update_config(new_config)
    -- 验证配置
    if not new_config or type(new_config) ~= "table" then
        return false, "Invalid config format"
    end
    
    -- 合并默认配置（确保所有字段都存在）
    local merged_config = {}
    for k, v in pairs(DEFAULT_CONFIG) do
        if type(v) == "table" then
            merged_config[k] = {}
            for kk, vv in pairs(v) do
                merged_config[k][kk] = new_config[k] and new_config[k][kk] or vv
            end
        else
            merged_config[k] = new_config[k] or v
        end
    end
    
    -- 保存到共享内存
    local success = save_config_to_shared_dict(merged_config)
    if success then
        ngx.log(ngx.INFO, "[ConfigManager] Config updated successfully, version: ", _M.get_config_version())
        return true, nil
    else
        return false, "Failed to save config"
    end
end

--- 重置配置到默认值
-- @return boolean 是否成功
function _M.reset_config()
    local success = save_config_to_shared_dict(DEFAULT_CONFIG)
    if success then
        ngx.log(ngx.INFO, "[ConfigManager] Config reset to default")
    end
    return success
end

--- 获取配置状态
-- @return table 状态信息
function _M.get_status()
    local dict = get_shared_dict()
    
    return {
        version = _M.get_config_version(),
        loaded_at = config_loaded_at,
        source = dict and "shared_dict" or "default",
        has_custom_config = dict and dict:get(CONFIG_KEY_PREFIX .. "main") ~= nil
    }
end

--- 获取特定配置项
-- @param path string 配置路径（如 "circuit_breaker.enabled"）
-- @return any 配置值
function _M.get(path)
    local config = _M.load_config()
    if not path then
        return config
    end
    
    -- 解析路径
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    -- 遍历配置
    local value = config
    for _, part in ipairs(parts) do
        if type(value) ~= "table" then
            return nil
        end
        value = value[part]
    end
    
    return value
end

--- 设置特定配置项
-- @param path string 配置路径
-- @param value any 配置值
-- @return boolean 是否成功
function _M.set(path, value)
    if not path then
        return false
    end
    
    local config = _M.load_config()
    
    -- 解析路径
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    -- 遍历并设置值
    local current = config
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end
    
    current[parts[#parts]] = value
    
    return save_config_to_shared_dict(config)
end

return _M
