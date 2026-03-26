--- OpenResty API Proxy Gateway - Zerion Provider转换器
-- 处理Zerion API的响应转换和错误提取
--

local cjson = require "cjson"
local base = require "transformer.provider.base"
local error_module = require "transformer.error"

local _M = base:new("zerion")
_M._VERSION = '1.0.0'

--- 从Zerion响应中提取错误信息
-- Zerion错误格式示例:
-- {
--   "errors": [{
--     "code": "invalid_api_key",
--     "detail": "Invalid API key"
--   }]
-- }
-- @param response table 原始响应对象
-- @return table|nil 错误信息对象
function _M:extract_error(response)
    if not response or not response.body then
        return nil
    end
    
    local body = response.body
    if type(body) ~= "string" or body == "" then
        return nil
    end
    
    local decode_ok, data = pcall(cjson.decode, body)
    if not decode_ok or type(data) ~= "table" then
        return nil
    end
    
    -- Zerion使用errors数组格式
    if data.errors and type(data.errors) == "table" and #data.errors > 0 then
        local first_error = data.errors[1]
        local detail = first_error.detail or first_error.message or first_error.code or "Unknown error"
        
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            detail,
            {
                code = first_error.code,
                detail = first_error.detail,
                source = data.errors
            }
        )
    end
    
    -- 备用：检查其他常见错误字段
    if data.error then
        local detail = type(data.error) == "string" and data.error or data.error.message or "Unknown error"
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            detail,
            data.error
        )
    end
    
    if data.message then
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            data.message,
            { message = data.message }
        )
    end
    
    return nil
end

--- 转换Zerion响应数据
-- 如需对Zerion响应数据进行转换，可在此方法中实现
-- @param data table 解析后的响应数据
-- @return table 转换后的数据
function _M:transform(data)
    -- 目前不进行数据转换，直接返回原始数据
    return data
end

return _M
