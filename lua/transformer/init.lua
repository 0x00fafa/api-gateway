--- OpenResty API Proxy Gateway - 响应转换器入口
-- 提供统一的响应转换接口
--

local cjson = require "cjson"
local config = require "config"
local response_module = require "transformer.response"
local error_module = require "transformer.error"

local _M = {
    _VERSION = '1.0.0'
}

-- Provider转换器缓存
local provider_transformers = {}

--- 获取Provider转换器
-- @param provider_name string Provider名称
-- @return table Provider转换器实例
function _M.get_transformer(provider_name)
    -- 检查缓存
    if provider_transformers[provider_name] then
        return provider_transformers[provider_name]
    end
    
    -- 尝试加载Provider特定的转换器
    local ok, transformer = pcall(require, "transformer.provider." .. provider_name)
    if ok and transformer then
        provider_transformers[provider_name] = transformer
        return transformer
    end
    
    -- 回退到基础转换器
    local base = require "transformer.provider.base"
    local instance = base:new(provider_name)
    provider_transformers[provider_name] = instance
    return instance
end

--- 检查响应转换是否启用
-- @return boolean 是否启用
function _M.is_enabled()
    local transform_config = config.get_response_transform_config()
    local enabled = transform_config and transform_config.enabled
    ngx.log(ngx.INFO, "[Transformer] is_enabled: ", tostring(enabled), ", config: ", require("cjson").encode(transform_config or {}))
    return enabled
end

--- 转换成功响应
-- @param provider_name string Provider名称
-- @param response table 原始响应对象
-- @param ctx table 请求上下文
-- @return table 统一格式的响应对象
function _M.transform_response(provider_name, response, ctx)
    -- 获取转换器
    local transformer = _M.get_transformer(provider_name)
    
    -- 检查Content-Type是否为JSON
    local content_type = response.headers and response.headers["content-type"]
    if not response_module.is_json_content_type(content_type) then
        -- 非JSON响应，返回原始数据
        ngx.log(ngx.DEBUG, "[Transformer] Non-JSON response, returning raw data")
        return response_module.build_success(response.body, ctx, response)
    end
    
    -- 处理响应
    local data, err_info = transformer:process_response(response, ctx)
    
    if err_info then
        -- Provider返回错误
        return response_module.build_provider_error(response, ctx, err_info)
    end
    
    -- 返回成功响应
    return response_module.build_success(data, ctx, response)
end

--- 转换错误响应
-- @param status number HTTP状态码
-- @param message string 错误消息
-- @param ctx table 请求上下文
-- @param error_type string 错误类型（可选）
-- @return table 统一格式的错误响应对象
function _M.transform_error(status, message, ctx, error_type)
    local error_info = error_module.build_error_info(
        error_type or error_module.ERROR_TYPE.INTERNAL_ERROR,
        message,
        nil
    )
    return response_module.build_error(status, message, ctx, error_info)
end

--- 转换Provider错误响应
-- @param provider_name string Provider名称
-- @param response table 原始响应对象
-- @param ctx table 请求上下文
-- @return table 统一格式的错误响应对象
function _M.transform_provider_error(provider_name, response, ctx)
    local transformer = _M.get_transformer(provider_name)
    local error_info = transformer:extract_error(response)
    return response_module.build_provider_error(response, ctx, error_info)
end

--- 转换网关错误响应
-- @param status number HTTP状态码
-- @param error_type string 错误类型
-- @param detail string 错误详情
-- @param ctx table 请求上下文
-- @return table 统一格式的错误响应对象
function _M.transform_gateway_error(status, error_type, detail, ctx)
    return response_module.build_gateway_error(status, error_type, detail, ctx)
end

--- 发送统一格式的响应
-- @param transformed_response table 转换后的响应对象
-- @param original_response table 原始响应对象（用于获取HTTP状态码）
function _M.send_transformed_response(transformed_response, original_response)
    -- 保持原始HTTP状态码
    local status = transformed_response.code or 200
    ngx.status = status
    
    -- 设置响应头
    ngx.header["Content-Type"] = "application/json"
    if original_response and original_response.headers then
        -- 透传一些有用的响应头
        local headers_to_pass = {
            ["etag"] = true,
            ["last-modified"] = true,
            ["cache-control"] = true
        }
        for k, v in pairs(original_response.headers) do
            local lower_k = string.lower(k)
            if headers_to_pass[lower_k] then
                ngx.header[k] = v
            end
        end
    end
    
    -- 输出响应
    ngx.say(cjson.encode(transformed_response))
end

return _M
