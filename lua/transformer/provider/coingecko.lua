--- OpenResty API Proxy Gateway - CoinGecko Provider转换器
-- 处理CoinGecko API的响应转换和错误提取
--

local cjson = require "cjson"
local base = require "transformer.provider.base"
local error_module = require "transformer.error"

local _M = base:new("coingecko")
_M._VERSION = '1.0.0'

--- 从CoinGecko响应中提取错误信息
-- CoinGecko错误格式示例:
-- {
--   "error": "Invalid API key",
--   "status": {
--     "error_code": 401,
--     "error_message": "Invalid API key"
--   }
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
    
    -- CoinGecko使用status对象格式
    if data.status and type(data.status) == "table" then
        local detail = data.status.error_message or data.error or "Unknown error"
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            detail,
            {
                error_code = data.status.error_code,
                error_message = data.status.error_message,
                status = data.status
            }
        )
    end
    
    -- 简单错误格式: { "error": "message" }
    if data.error then
        local detail = type(data.error) == "string" and data.error or "Unknown error"
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            detail,
            { error = data.error }
        )
    end
    
    -- 检查message字段
    if data.message then
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            data.message,
            { message = data.message }
        )
    end
    
    return nil
end

--- 转换CoinGecko响应数据
-- 如需对CoinGecko响应数据进行转换，可在此方法中实现
-- @param data table 解析后的响应数据
-- @return table 转换后的数据
function _M:transform(data)
    -- 目前不进行数据转换，直接返回原始数据
    return data
end

return _M
