#!/bin/bash
# OpenResty API Proxy Gateway - 限流器测试脚本
# 
# 使用方法:
#   ./scripts/test_rate_limiter.sh [gateway_url]
#
# 示例:
#   ./scripts/test_rate_limiter.sh https://api.0x00fafa.com
#
# 注意:
#   - 限流器需要先通过 Admin API 启用
#   - 测试使用 /admin/test/rate-limit 端点，不会消耗实际 API 配额

set -e

# 默认参数
BASE_URL="${1:-https://api.0x00fafa.com}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Rate Limiter Test Script${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Base URL: $BASE_URL"
echo -e "${BLUE}============================================${NC}"
echo ""

# 检查限流器配置
echo -e "${YELLOW}0. 检查限流器配置${NC}"
RL_CONFIG=$(curl -s "$BASE_URL/admin/config/rate_limiter" 2>/dev/null)
echo "$RL_CONFIG" | jq . 2>/dev/null || echo "$RL_CONFIG"
echo ""

# 检查是否启用限流器
RL_ENABLED=$(echo "$RL_CONFIG" | jq -r '.enabled // false' 2>/dev/null)
if [ "$RL_ENABLED" != "true" ]; then
    echo -e "${YELLOW}Warning: Rate limiter is not enabled. Enable it first:${NC}"
    echo ""
    echo "  curl -X PUT \"$BASE_URL/admin/config/rate_limiter\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"enabled\":true,\"global\":10000,\"ip\":100,\"api_key\":1000}'"
    echo ""
    read -p "Press Enter to continue anyway or Ctrl+C to exit..."
fi

# 1. 查看限流器状态
echo -e "${YELLOW}1. 查看限流器状态${NC}"
curl -s "$BASE_URL/admin/rate-limiter" | jq .
echo ""

# 2. 测试限流（limit=5, burst=3）
echo -e "${YELLOW}2. 测试限流（limit=5, burst=3）- 快速发送10个请求${NC}"
echo "Configuration: limit=5 requests/sec, burst=3"
echo ""

# 重置测试key
echo "Resetting test key..."
curl -s -X POST "$BASE_URL/admin/rate-limiter/test:rate_limit/reset" | jq -c .
echo ""

echo "Sending 10 requests..."
SUCCESS_COUNT=0
FAIL_COUNT=0
for i in {1..10}; do
    RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/rate-limit?limit=5&burst=3")
    HTTP_CODE=$(echo "$RESULT" | tail -n1)
    BODY=$(echo "$RESULT" | head -n -1)
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "Request $i: ${GREEN}✓ Allowed${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "Request $i: ${RED}✗ Rate Limited (HTTP 429)${NC}"
        ((FAIL_COUNT++))
    fi
done

echo ""
echo -e "Result: ${GREEN}Allowed: $SUCCESS_COUNT${NC}, ${RED}Rate Limited: $FAIL_COUNT${NC}"
echo ""

# 3. 查看测试key的限流状态
echo -e "${YELLOW}3. 查看测试key的限流状态${NC}"
curl -s "$BASE_URL/admin/rate-limiter/test:rate_limit" | jq .
echo ""

# 4. 等待1秒后再次测试（令牌应该恢复）
echo -e "${YELLOW}4. 等待1秒后再次测试（令牌应该恢复）${NC}"
sleep 1
echo "Sending 5 requests..."
SUCCESS_COUNT=0
FAIL_COUNT=0
for i in {1..5}; do
    RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/rate-limit?limit=5&burst=3")
    HTTP_CODE=$(echo "$RESULT" | tail -n1)
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "Request $i: ${GREEN}✓ Allowed${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "Request $i: ${RED}✗ Rate Limited${NC}"
        ((FAIL_COUNT++))
    fi
done
echo ""
echo -e "Result: ${GREEN}Allowed: $SUCCESS_COUNT${NC}, ${RED}Rate Limited: $FAIL_COUNT${NC}"
echo ""

# 5. 测试不同限流维度
echo -e "${YELLOW}5. 测试不同限流维度${NC}"
echo ""
echo "Available rate limit dimensions:"
echo "  - global: Global rate limit across all requests"
echo "  - provider:{name}: Rate limit per provider (zerion, coingecko, alchemy)"
echo "  - ip:{address}: Rate limit per client IP"
echo "  - api_key:{key}: Rate limit per API key"
echo "  - uri:{path}: Rate limit per URI"
echo ""

# 6. 查看各维度限流状态
echo -e "${YELLOW}6. 查看各维度限流状态${NC}"
echo "Global rate limiter:"
curl -s "$BASE_URL/admin/rate-limiter/global" | jq -c . 2>/dev/null || echo "  Not available"
echo ""

echo "Provider rate limiters:"
for provider in zerion coingecko alchemy; do
    STATUS=$(curl -s "$BASE_URL/admin/rate-limiter/provider:$provider" 2>/dev/null)
    if [ -n "$STATUS" ] && [ "$STATUS" != "null" ]; then
        echo "  $provider: $(echo "$STATUS" | jq -c .)"
    fi
done
echo ""

# 7. 测试高并发限流
echo -e "${YELLOW}7. 测试高并发限流（50个并发请求）${NC}"
echo "Resetting test key..."
curl -s -X POST "$BASE_URL/admin/rate-limiter/test:concurrent/reset" > /dev/null
echo ""

echo "Sending 50 concurrent requests..."
SUCCESS_COUNT=0
FAIL_COUNT=0
PIDS=()

for i in {1..50}; do
    (
        RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/rate-limit?limit=10&burst=5")
        HTTP_CODE=$(echo "$RESULT" | tail -n1)
        if [ "$HTTP_CODE" == "200" ]; then
            echo "1"
        else
            echo "0"
        fi
    ) &
    PIDS+=($!)
done

# 等待所有请求完成并统计结果
for PID in "${PIDS[@]}"; do
    RESULT=$(wait $PID)
    if [ "$RESULT" == "1" ]; then
        ((SUCCESS_COUNT++))
    else
        ((FAIL_COUNT++))
    fi
done

echo ""
echo -e "Result: ${GREEN}Allowed: $SUCCESS_COUNT${NC}, ${RED}Rate Limited: $FAIL_COUNT${NC}"
echo ""

# 8. 查看最终限流器状态
echo -e "${YELLOW}8. 查看最终限流器状态${NC}"
curl -s "$BASE_URL/admin/rate-limiter" | jq .
echo ""

echo -e "${GREEN}=== Rate Limiter Test Complete ===${NC}"
echo ""
echo "Summary:"
echo "  - Token bucket algorithm: tokens are replenished over time"
echo "  - Rate (RPM): tokens added per second"
echo "  - Burst: maximum bucket capacity for handling spikes"
echo "  - After rate limited, wait for tokens to replenish"
echo ""
echo "Useful Commands:"
echo "  # View rate limiter status"
echo "  curl -s \"$BASE_URL/admin/rate-limiter\" | jq ."
echo ""
echo "  # Reset a specific key"
echo "  curl -X POST \"$BASE_URL/admin/rate-limiter/ip:192.168.1.100/reset\""
echo ""
echo "  # Update rate limiter config"
echo "  curl -X PUT \"$BASE_URL/admin/config/rate_limiter\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"enabled\":true,\"ip\":50,\"ip_burst\":10}'"
echo ""
