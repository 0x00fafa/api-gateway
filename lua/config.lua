--- OpenResty API Proxy Gateway - 配置模块
-- 

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
function _M.get_provider(name)
    local providers = {
        zerion = {
            name = "zerion",
            endpoint = os.getenv("ZERION_ENDPOINT") or "https://api.zerion.io",
            auth_type = "basic",  -- Basic Auth: API Key 作为用户名
            auth_key = os.getenv("ZERION_API_KEY") or "",
            timeout = 30000  -- 30秒
        },
        coingecko = {
            name = "coingecko",
            endpoint = os.getenv("COINGECKO_ENDPOINT") or "https://api.coingecko.com",
            auth_type = "header",  -- Header 传递 API Key
            auth_key = os.getenv("COINGECKO_API_KEY") or "",
            auth_header = "x-cg-demo-api-key",
            timeout = 30000
        },
        alchemy = {
            name = "alchemy",
            endpoint = os.getenv("ALCHEMY_ENDPOINT") or "https://eth-mainnet.g.alchemy.com",
            auth_type = "url",  -- API Key 拼接在 URL 路径
            auth_key = os.getenv("ALCHEMY_API_KEY") or "",
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

return _M
