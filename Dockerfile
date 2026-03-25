# OpenResty API Proxy Gateway
# 

FROM openresty/openresty:alpine-fat

LABEL maintainer="API Proxy Gateway"
LABEL description="High-performance API proxy gateway based on OpenResty"

# 安装必要的系统依赖
RUN apk add --no-cache curl

# 安装必要的 Lua 库
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-maxminddb

# 创建必要的目录
RUN mkdir -p /var/log/openresty \
    && mkdir -p /usr/local/openresty/lualib/custom \
    && mkdir -p /usr/local/openresty/nginx/ssl \
    && mkdir -p /usr/local/openresty/geoip

# 复制 Lua 模块
COPY lua/ /usr/local/openresty/lualib/custom/

# 复制 Nginx 配置
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# 复制 SSL 证书
COPY ssl/ /usr/local/openresty/nginx/ssl/

# 复制 GeoIP 数据库
COPY GeoLite2-Country.mmdb /usr/local/openresty/geoip/GeoLite2-Country.mmdb

# 设置权限
RUN chown -R nobody:nobody /var/log/openresty \
    && chmod 600 /usr/local/openresty/nginx/ssl/*.pem \
    && chmod 644 /usr/local/openresty/geoip/GeoLite2-Country.mmdb

# 暴露端口
EXPOSE 80 443

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# 启动 OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
