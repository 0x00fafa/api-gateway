--- OpenResty API Proxy Gateway - Alchemy Provider转换器
-- 处理Alchemy API的响应转换和错误提取
--

local cjson = require "cjson"
local base = require "transformer.provider.base"
local error_module = require "transformer.error"

local _M = base:new("alchemy")
_M._VERSION = '1.0.0'

--- 从Alchemy响应中提取错误信息
-- Alchemy使用JSON-RPC 2.0格式:
-- {
--   "jsonrpc": "2.0",
--   "id": 1,
--   "error": {
--     "code": -32000,
--     "message": "Invalid API key"
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
    
    -- JSON-RPC错误格式
    if data.error then
        local detail = "Unknown error"
        local error_data = data.error
        
        if type(error_data) == "table" then
            detail = error_data.message or error_data.data or "Unknown error"
            return error_module.build_error_info(
                error_module.ERROR_TYPE.PROVIDER_ERROR,
                detail,
                {
                    code = error_data.code,
                    message = error_data.message,
                    data = error_data.data,
                    jsonrpc = data.jsonrpc
                }
            )
        elseif type(error_data) == "string" then
            detail = error_data
            return error_module.build_error_info(
                error_module.ERROR_TYPE.PROVIDER_ERROR,
                detail,
                { error = error_data }
            )
        end
    end
    
    -- HTTP错误但JSON-RPC格式响应
    if data.message then
        return error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            data.message,
            { message = data.message }
        )
    end
    
    return nil
end

--- 转换Alchemy响应数据
-- Alchemy使用JSON-RPC 2.0格式，可以在此提取result字段
-- @param data table 解析后的响应数据
-- @return table 转换后的数据
function _M:transform(data)
    -- 目前不进行数据转换，直接返回原始数据
    -- 如果需要，可以提取data.result作为实际数据
    return data
end

--- 判断响应是否为错误响应
-- JSON-RPC响应中，有error字段即为错误
-- @param response table 原始响应对象
-- @return boolean 是否为错误响应
function _M:is_error_response(response)
    -- 首先检查HTTP状态码
    if not response then
        return true
    end
    
    local status = response.status or 200
    if status >= 400 then
        return true
    end
    
    -- 对于JSON-RPC，即使HTTP 200也可能包含错误
    if response.body and type(response.body) == "string" then
        local decode_ok, data = pcall(cjson.decode, response.body)
        if decode_ok and type(data) == "table" and data.error then
            return true
        end
    end
    
    return false
end

return _M
