#!/bin/bash
# OpenResty API Proxy Gateway - 缓存功能测试脚本
# 
# 使用方法:
#   ./scripts/test_cache.sh [gateway_url] [api_key] [provider]
#
# 示例:
#   ./scripts/test_cache.sh https://api.0x00fafa.com YOUR_API_KEY coingecko
#   ./scripts/test_cache.sh https://api.0x00fafa.com YOUR_API_KEY zerion
#
# 注意:
#   - 缓存需要先通过 Admin API 启用
#   - 默认缓存策略为 get_only，只缓存 GET 请求
#   - 响应头 X-Cache-Status 表示缓存状态: HIT/MISS/BYPASS

set -e

# 默认参数
GATEWAY_URL="${1:-https://api.0x00fafa.com}"
API_KEY="${2:-}"
PROVIDER="${3:-coingecko}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 根据provider选择测试路径
case "$PROVIDER" in
    coingecko)
        TEST_PATH="/coingecko/api/v3/ping"
        ;;
    zerion)
        TEST_PATH="/zerion/v1/wallets/0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045/portfolio"
        ;;
    alchemy)
        echo -e "${YELLOW}Note: Alchemy uses POST requests which are not cached by default (CACHE_POLICY=get_only)${NC}"
        echo "Skipping Alchemy cache test."
        exit 0
        ;;
    *)
        echo -e "${RED}Unknown provider: $PROVIDER${NC}"
        echo "Supported providers: coingecko, zerion, alchemy"
        exit 1
        ;;
esac

FULL_URL="${GATEWAY_URL}${TEST_PATH}"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Cache Functionality Test${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Gateway URL: $GATEWAY_URL"
echo "Provider: $PROVIDER"
echo "Test Path: $TEST_PATH"
echo "Full URL: $FULL_URL"
echo -e "${BLUE}============================================${NC}"
echo ""

# 检查缓存配置
echo -e "${YELLOW}1. 检查缓存配置${NC}"
CACHE_CONFIG=$(curl -s "${GATEWAY_URL}/admin/config/cache" 2>/dev/null)
echo "$CACHE_CONFIG" | jq . 2>/dev/null || echo "$CACHE_CONFIG"
echo ""

# 检查是否启用缓存
CACHE_ENABLED=$(echo "$CACHE_CONFIG" | jq -r '.enabled // false' 2>/dev/null)
if [ "$CACHE_ENABLED" != "true" ]; then
    echo -e "${YELLOW}Warning: Cache is not enabled. Enable it first:${NC}"
    echo ""
    echo "  curl -X PUT \"${GATEWAY_URL}/admin/config/cache\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"enabled\":true,\"policy\":\"get_only\",\"providers\":{\"${PROVIDER}\":60},\"default_ttl\":60}'"
    echo ""
    read -p "Press Enter to continue anyway or Ctrl+C to exit..."
fi

# 函数：发送请求并显示缓存状态
test_request() {
    local request_num=$1
    echo -e "${YELLOW}=== Request #$request_num ===${NC}"
    
    # 构建curl命令
    local curl_cmd="curl -s -D - -o /dev/null"
    if [ -n "$API_KEY" ]; then
        curl_cmd="$curl_cmd -H \"X-API-Key: $API_KEY\""
    fi
    curl_cmd="$curl_cmd \"$FULL_URL\""
    
    # 发送请求并获取响应头
    local headers=$(eval "$curl_cmd" 2>/dev/null)
    
    # 提取HTTP状态码
    local http_code=$(echo "$headers" | grep "HTTP/2" | tail -1 | awk '{print $2}')
    if [ -z "$http_code" ]; then
        http_code=$(echo "$headers" | grep "HTTP/" | tail -1 | awk '{print $2}')
    fi
    
    # 提取缓存状态 (X-Cache-Status)
    local cache_status=$(echo "$headers" | grep -i "x-cache-status" | cut -d':' -f2 | tr -d ' \r\n')
    
    # 提取缓存TTL（如果有）
    local cache_ttl=$(echo "$headers" | grep -i "x-cache-ttl" | cut -d':' -f2 | tr -d ' \r\n')
    
    # 提取请求ID
    local request_id=$(echo "$headers" | grep -i "x-onekey-request-id" | cut -d':' -f2 | tr -d ' \r\n')
    
    echo "HTTP Status: ${http_code:-N/A}"
    echo "Request ID: ${request_id:-N/A}"
    
    if [ -n "$cache_status" ]; then
        if [ "$cache_status" = "HIT" ]; then
            echo -e "Cache Status: ${GREEN}$cache_status${NC}"
        elif [ "$cache_status" = "MISS" ]; then
            echo -e "Cache Status: ${YELLOW}$cache_status${NC}"
        else
            echo -e "Cache Status: ${BLUE}$cache_status${NC}"
        fi
    else
        echo "Cache Status: N/A (cache may be disabled)"
    fi
    
    if [ -n "$cache_ttl" ]; then
        echo "Cache TTL: ${cache_ttl}s"
    fi
    
    echo ""
}

# 等待用户确认
echo -e "${YELLOW}Press Enter to start the test (3 requests will be sent)...${NC}"
read -r

# 测试1：第一次请求（应该MISS）
test_request 1

# 等待1秒
echo "Waiting 1 second..."
sleep 1

# 测试2：第二次请求（应该HIT）
test_request 2

# 等待1秒
echo "Waiting 1 second..."
sleep 1

# 测试3：第三次请求（应该HIT）
test_request 3

# 显示缓存统计
echo -e "${YELLOW}=== Cache Statistics ===${NC}"
curl -s "${GATEWAY_URL}/admin/config/cache" | jq . 2>/dev/null || echo "Unable to get cache stats"
echo ""

echo -e "${GREEN}=== Cache Test Complete ===${NC}"
echo ""
echo "Tips:"
echo "  - If all requests show BYPASS, check if cache is enabled for this provider"
echo "  - If requests show MISS but never HIT, check cache TTL configuration"
echo "  - Use the following command to enable cache:"
echo ""
echo "    curl -X PUT \"${GATEWAY_URL}/admin/config/cache\" \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{\"enabled\":true,\"policy\":\"get_only\",\"providers\":{\"${PROVIDER}\":60}}'"
echo ""
