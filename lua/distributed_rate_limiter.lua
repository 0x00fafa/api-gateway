--- OpenResty API Proxy Gateway - 分布式限流模块
-- 实现Redis + 本地令牌桶混合限流策略
-- 本地令牌桶处理大部分请求，Redis定期同步配额
--

local cjson = require "cjson"
local config = require "config"

local _M = {
    _VERSION = '1.0.0'
}

-- 本地令牌桶缓存
local local_buckets = {}

--- 获取分布式限流配置
-- @return table 配置表
function _M.get_config()
    local enabled_str = os.getenv("DISTRIBUTED_RATE_LIMIT_ENABLED") or "false"
    local redis_host = os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_HOST") or "127.0.0.1"
    local redis_port = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_PORT")) or 6379
    local redis_password = os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_PASSWORD") or ""
    local redis_db = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_REDIS_DB")) or 0
    local sync_interval = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_SYNC_INTERVAL")) or 1  -- 同步间隔（秒）
    local local_capacity_ratio = tonumber(os.getenv("DISTRIBUTED_RATE_LIMIT_LOCAL_RATIO")) or 0.2  -- 本地配额比例
    
    return {
        enabled = enabled_str:lower() == "true",
        redis = {
            host = redis_host,
            port = redis_port,
            password = redis_password ~= "" and redis_password or nil,
            db = redis_db,
            timeout = 1000,  -- 1秒
            keepalive_timeout = 10000,  -- 10秒
            keepalive_pool = 10
        },
        sync_interval = sync_interval,
        local_capacity_ratio = local_capacity_ratio
    }
end

--- 连接Redis
-- @param redis_config table Redis配置
-- @return table|nil red Redis连接对象, string|nil err 错误信息
local function connect_redis(redis_config)
    local redis = require "resty.redis"
    local red = redis:new()
    
    red:set_timeout(redis_config.timeout)
    
    local ok, err = red:connect(redis_config.host, redis_config.port)
    if not ok then
        return nil, err
    end
    
    -- 认证
    if redis_config.password then
        local res, err = red:auth(redis_config.password)
        if not res then
            return nil, err
        end
    end
    
    -- 选择数据库
    if redis_config.db and redis_config.db > 0 then
        local res, err = red:select(redis_config.db)
        if not res then
            return nil, err
        end
    end
    
    return red, nil
end

--- 关闭Redis连接（放回连接池）
-- @param red table Redis连接对象
-- @param redis_config table Redis配置
local function close_redis(red, redis_config)
    if red then
        red:set_keepalive(redis_config.keepalive_timeout, redis_config.keepalive_pool)
    end
end

--- 创建本地令牌桶
-- @param key string 桶标识
-- @param rate number 令牌生成速率（令牌/秒）
-- @param capacity number 桶容量
-- @return table 令牌桶对象
local function create_bucket(key, rate, capacity)
    local dist_config = _M.get_config()
    local local_quota = math.floor(capacity * dist_config.local_capacity_ratio)
    
    return {
        key = key,
        rate = rate,  -- 令牌/秒
        capacity = capacity,
        tokens = capacity,  -- 当前令牌数
        last_update = ngx.now(),
        local_quota = local_quota,  -- 本地配额
        local_tokens = local_quota,  -- 本地令牌数
        last_sync = 0  -- 上次同步时间
    }
end

--- 获取或创建本地令牌桶
-- @param key string 桶标识
-- @param rate number 令牌生成速率
-- @param capacity number 桶容量
-- @return table 令牌桶对象
local function get_or_create_bucket(key, rate, capacity)
    if not local_buckets[key] then
        local_buckets[key] = create_bucket(key, rate, capacity)
    end
    return local_buckets[key]
end

--- 补充本地令牌
-- @param bucket table 令牌桶对象
local function refill_local_tokens(bucket)
    local now = ngx.now()
    local elapsed = now - bucket.last_update
    
    -- 计算新增令牌
    local new_tokens = elapsed * bucket.rate
    bucket.local_tokens = math.min(bucket.local_quota, bucket.local_tokens + new_tokens)
    bucket.tokens = math.min(bucket.capacity, bucket.tokens + new_tokens)
    bucket.last_update = now
end

--- 从Redis同步配额
-- @param bucket table 令牌桶对象
-- @param dist_config table 分布式配置
-- @return boolean 是否同步成功
local function sync_from_redis(bucket, dist_config)
    local red, err = connect_redis(dist_config.redis)
    if not red then
        ngx.log(ngx.WARN, "[DistributedRateLimiter] Redis connect error: ", err)
        return false
    end
    
    local redis_key = "rate_limit:" .. bucket.key
    local now = ngx.now()
    
    -- 使用Lua脚本原子获取并更新配额
    local script = [[
        local key = KEYS[1]
        local rate = tonumber(ARGV[1])
        local capacity = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        local sync_interval = tonumber(ARGV[4])
        
        local last_sync = tonumber(redis.call('GET', key .. ':last_sync') or 0)
        
        -- 如果距离上次同步时间太短，跳过
        if now - last_sync < sync_interval then
            return {0, capacity, last_sync}
        end
        
        -- 获取当前配额
        local current = tonumber(redis.call('GET', key) or capacity)
        
        -- 计算补充的令牌
        local elapsed = now - last_sync
        local new_tokens = math.floor(elapsed * rate)
        current = math.min(capacity, current + new_tokens)
        
        -- 更新同步时间
        redis.call('SET', key, current)
        redis.call('SET', key .. ':last_sync', now)
        redis.call('EXPIRE', key, 3600)
        redis.call('EXPIRE', key .. ':last_sync', 3600)
        
        return {1, current, now}
    ]]
    
    local res, err = red:eval(script, 1, redis_key, bucket.rate, bucket.capacity, now, dist_config.sync_interval)
    
    close_redis(red, dist_config.redis)
    
    if err then
        ngx.log(ngx.WARN, "[DistributedRateLimiter] Redis eval error: ", err)
        return false
    end
    
    if res and res[1] == 1 then
        -- 同步成功，更新本地配额
        bucket.tokens = res[2]
        bucket.last_sync = res[3]
        -- 重置本地令牌
        bucket.local_tokens = math.min(bucket.local_quota, res[2])
        ngx.log(ngx.DEBUG, "[DistributedRateLimiter] Synced from Redis: tokens=", res[2])
        return true
    end
    
    return false
end

--- 消耗Redis配额
-- @param bucket table 令牌桶对象
-- @param count number 消耗数量
-- @param dist_config table 分布式配置
-- @return boolean 是否成功
local function consume_redis_quota(bucket, count, dist_config)
    local red, err = connect_redis(dist_config.redis)
    if not red then
        ngx.log(ngx.WARN, "[DistributedRateLimiter] Redis connect error: ", err)
        return false
    end
    
    local redis_key = "rate_limit:" .. bucket.key
    
    -- 使用Lua脚本原子消耗配额
    local script = [[
        local key = KEYS[1]
        local count = tonumber(ARGV[1])
        local rate = tonumber(ARGV[2])
        local capacity = tonumber(ARGV[3])
        local now = tonumber(ARGV[4])
        
        -- 获取当前配额和上次更新时间
        local current = tonumber(redis.call('GET', key) or capacity)
        local last_update = tonumber(redis.call('GET', key .. ':last_sync') or now)
        
        -- 计算补充的令牌
        local elapsed = now - last_update
        local new_tokens = math.floor(elapsed * rate)
        current = math.min(capacity, current + new_tokens)
        
        -- 检查是否有足够配额
        if current < count then
            redis.call('SET', key, current)
            return {0, current}
        end
        
        -- 消耗配额
        current = current - count
        redis.call('SET', key, current)
        redis.call('SET', key .. ':last_sync', now)
        redis.call('EXPIRE', key, 3600)
        redis.call('EXPIRE', key .. ':last_sync', 3600)
        
        return {1, current}
    ]]
    
    local res, err = red:eval(script, 1, redis_key, count, bucket.rate, bucket.capacity, ngx.now())
    
    close_redis(red, dist_config.redis)
    
    if err then
        ngx.log(ngx.WARN, "[DistributedRateLimiter] Redis eval error: ", err)
        return false
    end
    
    if res and res[1] == 1 then
        bucket.tokens = res[2]
        return true
    end
    
    return false
end

--- 检查是否允许请求（分布式限流）
-- @param key string 限流key
-- @param rate number 令牌生成速率（令牌/秒）
-- @param capacity number 桶容量
-- @return boolean allowed 是否允许, string|nil reason 拒绝原因
function _M.check_rate_limit(key, rate, capacity)
    local dist_config = _M.get_config()
    
    -- 如果未启用分布式限流，回退到本地限流
    if not dist_config.enabled then
        -- 使用现有的本地限流器
        local rate_limiter = require "rate_limiter"
        return rate_limiter.check_rate_limit(key, "", rate)
    end
    
    -- 获取或创建本地桶
    local bucket = get_or_create_bucket(key, rate, capacity)
    
    -- 补充本地令牌
    refill_local_tokens(bucket)
    
    -- 检查本地令牌是否足够
    if bucket.local_tokens >= 1 then
        -- 本地令牌足够，直接消耗
        bucket.local_tokens = bucket.local_tokens - 1
        bucket.tokens = bucket.tokens - 1
        return true, nil
    end
    
    -- 本地令牌不足，尝试从Redis同步
    local now = ngx.now()
    if now - bucket.last_sync >= dist_config.sync_interval then
        -- 同步配额
        sync_from_redis(bucket, dist_config)
        
        -- 再次检查本地令牌
        if bucket.local_tokens >= 1 then
            bucket.local_tokens = bucket.local_tokens - 1
            bucket.tokens = bucket.tokens - 1
            return true, nil
        end
        
        -- 尝试从Redis消耗配额
        if consume_redis_quota(bucket, 1, dist_config) then
            bucket.local_tokens = bucket.local_quota - 1
            return true, nil
        end
    end
    
    -- 限流
    return false, "rate_limited"
end

--- 获取分布式限流状态
-- @param key string 限流key
-- @param rate number 令牌生成速率
-- @param capacity number 桶容量
-- @return table 状态信息
function _M.get_status(key, rate, capacity)
    local dist_config = _M.get_config()
    local status = {
        enabled = dist_config.enabled,
        key = key,
        rate = rate,
        capacity = capacity,
        local_bucket = nil,
        redis_connected = false
    }
    
    -- 获取本地桶状态
    local bucket = get_or_create_bucket(key, rate, capacity)
    refill_local_tokens(bucket)
    
    status.local_bucket = {
        tokens = bucket.tokens,
        local_tokens = bucket.local_tokens,
        local_quota = bucket.local_quota,
        last_update = bucket.last_update,
        last_sync = bucket.last_sync
    }
    
    -- 检查Redis连接
    if dist_config.enabled then
        local red, err = connect_redis(dist_config.redis)
        if red then
            status.redis_connected = true
            
            -- 获取Redis中的配额
            local redis_key = "rate_limit:" .. key
            local redis_tokens = red:get(redis_key)
            status.redis_tokens = tonumber(redis_tokens) or capacity
            
            close_redis(red, dist_config.redis)
        else
            status.redis_error = err
        end
    end
    
    return status
end

--- 重置限流计数器
-- @param key string 限流key
-- @return boolean 是否成功
function _M.reset(key)
    -- 重置本地桶
    local_buckets[key] = nil
    
    local dist_config = _M.get_config()
    if not dist_config.enabled then
        return true
    end
    
    -- 重置Redis计数器
    local red, err = connect_redis(dist_config.redis)
    if not red then
        ngx.log(ngx.WARN, "[DistributedRateLimiter] Redis reset error: ", err)
        return false
    end
    
    local redis_key = "rate_limit:" .. key
    red:del(redis_key)
    red:del(redis_key .. ":last_sync")
    
    close_redis(red, dist_config.redis)
    return true
end

return _M
