--- OpenResty API Proxy Gateway - 缓存模块
-- 实现请求响应缓存功能，减少对上游API的调用
--

local cjson = require "cjson"
local config = require "config"

local _M = {
    _VERSION = '1.0.0'
}

-- 缓存策略常量
_M.POLICY = {
    NEVER = "never",      -- 永不缓存
    GET_ONLY = "get_only", -- 只缓存GET请求
    ALL = "all"           -- 缓存所有可缓存请求
}

--- 生成缓存Key
-- @param provider string Provider名称
-- @param method string HTTP方法
-- @param url string 请求URL
-- @param body string|nil 请求体
-- @return string 缓存Key
local function generate_cache_key(provider, method, url, body)
    local key_parts = {
        provider or "",
        method or "",
        url or ""
    }
    
    -- 对于POST请求，包含请求体的一部分作为key
    -- 注意：对于大型请求体，只取前256字符的hash
    if body and type(body) == "string" and #body > 0 then
        local body_part = #body > 256 and string.sub(body, 1, 256) or body
        table.insert(key_parts, body_part)
    end
    
    local key_string = table.concat(key_parts, ":")
    
    -- 使用MD5生成较短的key（OpenResty内置）
    local md5 = ngx.md5(key_string)
    return "cache:" .. (provider or "unknown") .. ":" .. md5
end

--- 检查请求是否可缓存
-- @param provider string Provider名称
-- @param method string HTTP方法
-- @param provider_config table Provider配置
-- @return boolean 是否可缓存
function _M.is_cacheable(provider, method, provider_config)
    local cache_config = config.get_cache_config()
    
    -- 调试日志：输出缓存配置（使用INFO级别确保输出）
    ngx.log(ngx.INFO, "[Cache] is_cacheable: provider=", provider or "nil",
            ", method=", method or "nil",
            ", cache_enabled=", tostring(cache_config.enabled),
            ", policy=", cache_config.policy or "nil")
    
    -- 全局缓存开关
    if not cache_config.enabled then
        ngx.log(ngx.INFO, "[Cache] is_cacheable: cache disabled globally")
        return false
    end
    
    -- 检查provider是否在缓存白名单中
    local provider_ttl = cache_config.providers[provider]
    ngx.log(ngx.INFO, "[Cache] is_cacheable: provider_ttl=", tostring(provider_ttl),
            ", providers_config=", require("cjson").encode(cache_config.providers))
    
    if not provider_ttl or provider_ttl <= 0 then
        ngx.log(ngx.INFO, "[Cache] is_cacheable: provider not in cache list or TTL <= 0")
        return false
    end
    
    -- 根据缓存策略判断
    local policy = cache_config.policy
    ngx.log(ngx.INFO, "[Cache] is_cacheable: policy=", policy or "nil")
    
    if policy == "never" or string.find(policy, "v2/", 1, true) == 1 then
        ngx.log(ngx.INFO, "[Cache] is_cacheable: policy is NEVER")
        return false
    elseif policy == "get_only" then
        local is_get = method and string.upper(method) == "GET"
        ngx.log(ngx.INFO, "[Cache] is_cacheable: policy is GET_ONLY, is_get=", tostring(is_get))
        return is_get
    elseif policy == "all" then
        -- GET请求总是可缓存
        -- POST请求需要检查是否是幂等的（如JSON-RPC的查询方法）
        local upper_method = method and string.upper(method) or ""
        if upper_method == "GET" then
            ngx.log(ngx.INFO, "[Cache] is_cacheable: policy is ALL, method is GET, cacheable=true")
            return true
        end
        -- 对于POST请求，需要进一步检查请求体
        -- 这里简化处理，只缓存GET请求
        ngx.log(ngx.INFO, "[Cache] is_cacheable: policy is ALL, method is ", upper_method, ", cacheable=false")
        return false
    end
    
    ngx.log(ngx.INFO, "[Cache] is_cacheable: unknown policy, cacheable=false")
    return false
end

--- 从缓存获取响应
-- @param cache_key string 缓存Key
-- @return table|nil 缓存的响应，nil表示未命中
function _M.get(cache_key)
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        ngx.log(ngx.WARN, "Cache dict 'api_cache' not found")
        return nil
    end
    
    local cached_data, err = cache_dict:get(cache_key)
    if err then
        ngx.log(ngx.WARN, "Cache get error: ", err)
        return nil
    end
    
    if not cached_data then
        return nil
    end
    
    -- 解析缓存数据
    local decode_ok, cached_response = pcall(cjson.decode, cached_data)
    if not decode_ok then
        ngx.log(ngx.WARN, "Cache decode error")
        return nil
    end
    
    -- 检查是否过期
    if cached_response.expires_at and cached_response.expires_at < ngx.now() then
        -- 缓存已过期，删除
        cache_dict:delete(cache_key)
        return nil
    end
    
    ngx.log(ngx.DEBUG, "Cache hit: ", cache_key)
    return cached_response
end

--- 保存响应到缓存
-- @param cache_key string 缓存Key
-- @param response table 响应对象
-- @param ttl number 缓存时间（秒）
-- @return boolean 是否成功
function _M.set(cache_key, response, ttl)
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        ngx.log(ngx.WARN, "Cache dict 'api_cache' not found")
        return false
    end
    
    -- 只缓存成功的响应（2xx）
    if not response.status or response.status < 200 or response.status >= 300 then
        return false
    end
    
    -- 构建缓存数据
    local cached_response = {
        status = response.status,
        headers = {},
        body = response.body,
        cached_at = ngx.now(),
        expires_at = ngx.now() + ttl
    }
    
    -- 只缓存特定的响应头
    local cacheable_headers = {
        ["content-type"] = true,
        ["content-encoding"] = true,
        ["etag"] = true,
        ["last-modified"] = true
    }
    
    if response.headers then
        for k, v in pairs(response.headers) do
            local lower_k = string.lower(k)
            if cacheable_headers[lower_k] then
                cached_response.headers[k] = v
            end
        end
    end
    
    local encode_ok, cached_data = pcall(cjson.encode, cached_response)
    if not encode_ok then
        ngx.log(ngx.WARN, "Cache encode error")
        return false
    end
    
    -- 保存到共享内存
    local success, err = cache_dict:set(cache_key, cached_data, ttl)
    if err then
        ngx.log(ngx.WARN, "Cache set error: ", err)
        return false
    end
    
    ngx.log(ngx.DEBUG, "Cache set: ", cache_key, ", TTL: ", ttl, "s")
    return true
end

--- 删除缓存
-- @param cache_key string 缓存Key
-- @return boolean 是否成功
function _M.delete(cache_key)
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        return false
    end
    
    cache_dict:delete(cache_key)
    return true
end

--- 清除指定provider的所有缓存
-- @param provider string Provider名称
-- @return number 清除的缓存数量
function _M.clear_provider_cache(provider)
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        return 0
    end
    
    local prefix = "cache:" .. provider .. ":"
    local count = 0
    
    -- 遍历删除（注意：这个操作可能比较慢）
    local keys = cache_dict:get_keys(1024)
    for _, key in ipairs(keys) do
        if string.find(key, prefix, 1, true) == 1 then
            cache_dict:delete(key)
            count = count + 1
        end
    end
    
    return count
end

--- 获取缓存统计信息
-- @return table 缓存统计
function _M.get_stats()
    local cache_dict = ngx.shared.api_cache
    if not cache_dict then
        return { enabled = false }
    end
    
    return {
        enabled = true,
        capacity = cache_dict:capacity(),
        free_space = cache_dict:free_space(),
        used_space = cache_dict:capacity() - cache_dict:free_space()
    }
end

-- 导出函数
_M.generate_cache_key = generate_cache_key

return _M
