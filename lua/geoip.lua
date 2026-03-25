--- OpenResty API Proxy Gateway - GeoIP 模块
-- 基于 MaxMind GeoLite2 数据库进行IP地理位置查询

local maxminddb = require "resty.maxminddb"
local config = require "config"
local cjson = require "cjson"

local _M = {}

-- GeoIP 数据库路径
local GEOIP_DB_PATH = "/usr/local/openresty/geoip/GeoLite2-Country.mmdb"

--- 初始化 GeoIP 数据库
-- @return boolean 是否成功
function _M.init()
    local ok, err = maxminddb.init(GEOIP_DB_PATH)
    if not ok then
        ngx.log(ngx.ERR, "[GeoIP] Failed to init GeoIP database: ", err or "unknown error")
        return false
    end
    
    ngx.log(ngx.INFO, "[GeoIP] GeoIP database loaded successfully from ", GEOIP_DB_PATH)
    return true
end

--- 根据IP地址查询国家代码
-- @param ip string IP地址
-- @return string|nil 国家代码（如 "US", "CN"），查询失败返回 nil
function _M.lookup_country(ip)
    -- 跳过本地地址
    if not ip or ip == "" or ip == "127.0.0.1" or ip == "::1" then
        return "LOCAL"
    end
    
    -- 跳过私有IP地址
    local private_patterns = {
        "^10%.",           -- 10.0.0.0/8
        "^172%.(1[6-9]|2[0-9]|3[01])%.",  -- 172.16.0.0/12
        "^192%.168%.",     -- 192.168.0.0/16
        "^169%.254%.",     -- 169.254.0.0/16 (链路本地)
        "^fc", "^fd",      -- IPv6 私有地址
    }
    
    for _, pattern in ipairs(private_patterns) do
        if ngx.re.match(ip, pattern, "jo") then
            return "PRIVATE"
        end
    end
    
    local res, err = maxminddb.lookup(ip)
    if not res then
        ngx.log(ngx.DEBUG, "[GeoIP] Lookup failed for ", ip, ": ", err or "unknown")
        return nil
    end
    
    -- 提取国家代码
    local country_code = nil
    if res.country and res.country.iso_code then
        country_code = res.country.iso_code
    end
    
    return country_code
end

--- 获取客户端真实IP
-- 优先从 X-Forwarded-For 或 X-Real-IP 头获取
-- @return string 客户端IP地址
function _M.get_client_ip()
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

--- 设置请求的国家代码变量
-- 在 access 阶段调用
function _M.set_country_code()
    local client_ip = _M.get_client_ip()
    local country_code = _M.lookup_country(client_ip) or "UNKNOWN"
    
    ngx.var.geoip_country_code = country_code
    
    ngx.log(ngx.DEBUG, "[GeoIP] IP: ", client_ip, " -> Country: ", country_code)
end

--- 检查国家访问控制
-- @return boolean 是否允许访问
-- @return string|nil 如果阻止，返回国家代码
function _M.check_access()
    local geoip_config = config.get_geoip_config()
    
    -- 未启用 GeoIP 控制，允许访问
    if not geoip_config.enabled then
        return true
    end
    
    local client_ip = _M.get_client_ip()
    local country_code = _M.lookup_country(client_ip) or "UNKNOWN"
    
    -- 设置国家代码变量
    ngx.var.geoip_country_code = country_code
    
    -- 检查是否在列表中
    local in_list = geoip_config.countries[country_code]
    
    -- 黑名单模式
    if geoip_config.mode == "blacklist" then
        if in_list then
            -- 记录阻止日志
            ngx.log(ngx.WARN, "[GeoIP] Access BLOCKED - IP: ", client_ip,
                    ", Country: ", country_code, ", Mode: blacklist")
            return false, country_code
        end
        return true
    end
    
    -- 白名单模式
    if in_list then
        return true
    end
    
    -- 检查是否允许未知国家
    if country_code == "UNKNOWN" and geoip_config.allow_unknown then
        return true
    end
    
    -- 记录阻止日志
    ngx.log(ngx.WARN, "[GeoIP] Access BLOCKED - IP: ", client_ip,
            ", Country: ", country_code, ", Mode: whitelist")
    return false, country_code
end

--- 发送访问拒绝响应
-- @param country_code string 国家代码
-- @param request_id string 请求ID
function _M.send_blocked_response(country_code, request_id)
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Onekey-Request-Id"] = request_id or ""
    ngx.say(cjson.encode({
        error = "Access Denied",
        message = "Access from your country is not allowed",
        country_code = country_code or "UNKNOWN",
        request_id = request_id or ""
    }))
end

return _M
