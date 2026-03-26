--- OpenResty API Proxy Gateway - Provider转换器基类
-- 定义Provider转换器接口，所有Provider转换器继承此类
--

local cjson = require "cjson"
local error_module = require "transformer.error"

local _M = {
    _VERSION = '1.0.0',
    name = "base"
}

--- 创建新的Provider转换器实例
-- @param name string Provider名称
-- @return table Provider转换器实例
function _M:new(name)
    local instance = {
        name = name or "base"
    }
    setmetatable(instance, { __index = self })
    return instance
end

--- 转换响应数据
-- 子类可重写此方法实现自定义数据转换
-- @param data table 解析后的响应数据
-- @return table 转换后的数据
function _M:transform(data)
    -- 默认不转换，直接返回原始数据
    return data
end

--- 从Provider响应中提取错误信息
-- 子类应重写此方法以实现Provider特定的错误提取逻辑
-- @param response table 原始响应对象
-- @return table|nil 错误信息对象
function _M:extract_error(response)
    -- 默认使用通用错误提取
    return error_module.extract_generic_error(response)
end

--- 判断响应是否为错误响应
-- @param response table 原始响应对象
-- @return boolean 是否为错误响应
function _M:is_error_response(response)
    if not response then
        return true
    end
    
    local status = response.status or 200
    return status >= 400
end

--- 处理响应
-- @param response table 原始响应对象
-- @param ctx table 请求上下文
-- @return table 处理后的响应数据, table|nil 错误信息
function _M:process_response(response, ctx)
    if self:is_error_response(response) then
        local error_info = self:extract_error(response)
        return nil, error_info
    end
    
    -- 尝试解析JSON
    local body = response.body
    if not body or type(body) ~= "string" or body == "" then
        return nil, nil
    end
    
    local decode_ok, data = pcall(cjson.decode, body)
    if not decode_ok or type(data) ~= "table" then
        -- 非JSON响应，返回原始body
        return body, nil
    end
    
    -- 应用数据转换
    local transformed_data = self:transform(data)
    return transformed_data, nil
end

return _M
