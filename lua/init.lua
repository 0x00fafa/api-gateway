--- OpenResty API Proxy Gateway - 初始化模块
-- 

local _M = {}

function _M.init()
    -- 初始化随机数种子
    math.randomseed(ngx.now() * 1000)
    
    ngx.log(ngx.INFO, "[Init] OpenResty API Proxy Gateway initialized successfully")
end

return _M
