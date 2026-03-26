--- OpenResty API Proxy Gateway - 响应格式化器
-- 构建统一的响应格式
--

local cjson = require "cjson"
local error_module = require "transformer.error"

local _M = {
    _VERSION = '1.0.0'
}

--- 构建成功响应
-- @param data any 响应数据
-- @param ctx table 请求上下文
-- @param original_response table 原始响应对象
-- @return table 统一格式的响应对象
function _M.build_success(data, ctx, original_response)
    local response = {
        success = true,
        code = original_response and original_response.status or 200,
        message = error_module.get_status_message(original_response and original_response.status or 200),
        data = data,
        meta = {
            request_id = ctx and ctx.request_id or "",
            provider = ctx and ctx.provider or "",
            duration_ms = ctx and ctx.start_time and math.floor((ngx.now() - ctx.start_time) * 1000) or 0,
            cache_status = ctx and ctx.cache_status or "BYPASS",
            timestamp = ngx.now()
        }
    }
    
    return response
end

--- 构建错误响应
-- @param status number HTTP状态码
-- @param message string 错误消息
-- @param ctx table 请求上下文
-- @param error_info table|nil 错误信息对象（来自 error_module.build_error_info）
-- @return table 统一格式的错误响应对象
function _M.build_error(status, message, ctx, error_info)
    local response = {
        success = false,
        code = status,
        message = message or error_module.get_status_message(status),
        error = error_info or {
            type = error_module.ERROR_TYPE.INTERNAL_ERROR,
            detail = message or "Unknown error"
        },
        meta = {
            request_id = ctx and ctx.request_id or "",
            timestamp = ngx.now()
        }
    }
    
    -- 添加 provider 信息（如果有）
    if ctx and ctx.provider then
        response.meta.provider = ctx.provider
    end
    
    return response
end

--- 构建Provider错误响应
-- @param response table 原始响应对象
-- @param ctx table 请求上下文
-- @param extracted_error table 从Provider提取的错误信息
-- @return table 统一格式的错误响应对象
function _M.build_provider_error(response, ctx, extracted_error)
    local status = response and response.status or 500
    local message = error_module.get_status_message(status)
    
    local error_info = extracted_error
    if not error_info then
        error_info = error_module.build_error_info(
            error_module.ERROR_TYPE.PROVIDER_ERROR,
            "Provider returned an error",
            nil
        )
    end
    
    return _M.build_error(status, message, ctx, error_info)
end

--- 构建网关错误响应
-- @param status number HTTP状态码
-- @param error_type string 错误类型
-- @param detail string 错误详情
-- @param ctx table 请求上下文
-- @return table 统一格式的错误响应对象
function _M.build_gateway_error(status, error_type, detail, ctx)
    local error_info = error_module.build_error_info(error_type, detail, nil)
    return _M.build_error(status, error_module.get_status_message(status), ctx, error_info)
end

--- 检查Content-Type是否为JSON
-- @param content_type string|nil Content-Type头值
-- @return boolean 是否为JSON类型
function _M.is_json_content_type(content_type)
    if not content_type or type(content_type) ~= "string" then
        return false
    end
    
    local lower_ct = string.lower(content_type)
    return string.find(lower_ct, "application/json", 1, true) ~= nil or
           string.find(lower_ct, "text/json", 1, true) ~= nil or
           string.find(lower_ct, "+json", 1, true) ~= nil
end

--- 尝试解析JSON响应体
-- @param body string 响应体
-- @return boolean 是否成功解析, table|nil 解析后的数据
function _M.try_parse_json(body)
    if not body or type(body) ~= "string" or body == "" then
        return false, nil
    end
    
    local decode_ok, data = pcall(cjson.decode, body)
    if not decode_ok or type(data) ~= "table" then
        return false, nil
    end
    
    return true, data
end

return _M
