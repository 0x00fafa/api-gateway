--- OpenResty API Proxy Gateway - 错误类型定义与处理
-- 定义统一的错误类型常量和错误处理函数
--

local cjson = require "cjson"

local _M = {
    _VERSION = '1.0.0'
}

-- 错误类型常量
_M.ERROR_TYPE = {
    PROVIDER_ERROR = "provider_error",       -- Provider返回的错误
    UPSTREAM_ERROR = "upstream_error",       -- 上游连接错误
    RATE_LIMIT_ERROR = "rate_limit_error",   -- 限流错误
    CIRCUIT_BREAKER_ERROR = "circuit_breaker_error", -- 熔断错误
    AUTH_ERROR = "auth_error",               -- 认证错误
    VALIDATION_ERROR = "validation_error",   -- 参数验证错误
    NOT_FOUND_ERROR = "not_found_error",     -- 资源未找到
    INTERNAL_ERROR = "internal_error"        -- 内部错误
}

-- HTTP状态码对应的默认消息
local STATUS_MESSAGES = {
    [200] = "OK",
    [201] = "Created",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [429] = "Too Many Requests",
    [500] = "Internal Server Error",
    [502] = "Bad Gateway",
    [503] = "Service Unavailable",
    [504] = "Gateway Timeout"
}

--- 获取状态码对应的消息
-- @param status number HTTP状态码
-- @return string 状态消息
function _M.get_status_message(status)
    return STATUS_MESSAGES[status] or "Unknown Error"
end

--- 构建错误信息对象
-- @param error_type string 错误类型（来自 ERROR_TYPE）
-- @param detail string 错误详情
-- @param provider_error table|nil Provider原始错误结构
-- @return table 错误信息对象
function _M.build_error_info(error_type, detail, provider_error)
    local error_info = {
        type = error_type,
        detail = detail
    }
    
    if provider_error then
        error_info.provider_error = provider_error
    end
    
    return error_info
end

--- 从Provider响应中提取错误信息（通用方法）
-- @param response table 响应对象
-- @return table|nil 错误信息对象
function _M.extract_generic_error(response)
    if not response or not response.body then
        return nil
    end
    
    local body = response.body
    if type(body) ~= "string" or body == "" then
        return nil
    end
    
    -- 尝试解析JSON
    local decode_ok, data = pcall(cjson.decode, body)
    if not decode_ok or type(data) ~= "table" then
        return nil
    end
    
    -- 尝试常见的错误字段
    local error_detail = nil
    local provider_error = {}
    
    -- 格式1: { "error": "message" }
    if data.error then
        error_detail = data.error
        provider_error = { message = data.error }
    end
    
    -- 格式2: { "message": "error message" }
    if data.message and not error_detail then
        error_detail = data.message
        provider_error = { message = data.message }
    end
    
    -- 格式3: { "errors": [{ "code": "...", "detail": "..." }] }
    if data.errors and type(data.errors) == "table" and #data.errors > 0 then
        local first_error = data.errors[1]
        error_detail = first_error.detail or first_error.message or first_error.code
        provider_error = data.errors
    end
    
    -- 格式4: { "error": { "code": ..., "message": ... } } (JSON-RPC风格)
    if type(data.error) == "table" then
        error_detail = data.error.message or data.error.data or "Unknown error"
        provider_error = data.error
    end
    
    -- 格式5: { "status": { "error_code": ..., "error_message": ... } }
    if data.status and type(data.status) == "table" then
        error_detail = data.status.error_message or data.error
        provider_error = data.status
    end
    
    if error_detail then
        return _M.build_error_info(
            _M.ERROR_TYPE.PROVIDER_ERROR,
            error_detail,
            provider_error
        )
    end
    
    return nil
end

return _M
