#!/bin/bash
# OpenResty API Proxy Gateway - 熔断器测试脚本
# 
# 使用方法:
#   ./scripts/test_circuit_breaker.sh [gateway_url] [provider]
#
# 示例:
#   ./scripts/test_circuit_breaker.sh https://api.0x00fafa.com test
#   ./scripts/test_circuit_breaker.sh https://api.0x00fafa.com zerion
#
# 注意:
#   - 管理端点路径是 /admin/...，不要通过 /zerion/... 等provider路径访问
#   - 熔断器需要先通过 Admin API 启用

set -e

# 默认参数
BASE_URL="${1:-https://api.0x00fafa.com}"
PROVIDER="${2:-test}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Circuit Breaker Test Script${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Base URL: $BASE_URL"
echo "Provider: $PROVIDER"
echo -e "${BLUE}============================================${NC}"
echo ""

# 检查熔断器配置
echo -e "${YELLOW}0. 检查熔断器配置${NC}"
CB_CONFIG=$(curl -s "$BASE_URL/admin/config/circuit_breaker" 2>/dev/null)
echo "$CB_CONFIG" | jq . 2>/dev/null || echo "$CB_CONFIG"
echo ""

# 检查是否启用熔断器
CB_ENABLED=$(echo "$CB_CONFIG" | jq -r '.enabled // false' 2>/dev/null)
if [ "$CB_ENABLED" != "true" ]; then
    echo -e "${YELLOW}Warning: Circuit breaker is not enabled. Enable it first:${NC}"
    echo ""
    echo "  curl -X PUT \"$BASE_URL/admin/config/circuit_breaker\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"enabled\":true,\"failure_threshold\":5,\"success_threshold\":3,\"timeout\":30}'"
    echo ""
    read -p "Press Enter to continue anyway or Ctrl+C to exit..."
fi

# 1. 查看当前熔断器状态
echo -e "${YELLOW}1. 查看当前熔断器状态${NC}"
curl -s "$BASE_URL/admin/circuit-breaker/$PROVIDER" | jq .
echo ""

# 2. 重置熔断器状态
echo -e "${YELLOW}2. 重置熔断器状态${NC}"
curl -s -X POST "$BASE_URL/admin/circuit-breaker/$PROVIDER/reset" | jq .
echo ""

# 3. 查看重置后的状态
echo -e "${YELLOW}3. 查看重置后的状态（应该是 closed）${NC}"
curl -s "$BASE_URL/admin/circuit-breaker/$PROVIDER" | jq .
echo ""

# 4. 测试成功请求（连续3次）
echo -e "${YELLOW}4. 测试成功请求（连续3次）${NC}"
for i in {1..3}; do
    echo "Request $i:"
    RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/circuit-breaker?provider=$PROVIDER&fail=false")
    HTTP_CODE=$(echo "$RESULT" | tail -n1)
    BODY=$(echo "$RESULT" | head -n -1)
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "  ${GREEN}✓ Success${NC}"
        echo "$BODY" | jq -c '{message, provider, state: .state.state}'
    else
        echo -e "  ${RED}✗ Failed (HTTP $HTTP_CODE)${NC}"
        echo "$BODY" | jq -c .
    fi
    echo ""
done

# 5. 查看熔断器状态（应该是closed）
echo -e "${YELLOW}5. 查看熔断器状态（应该是 closed）${NC}"
curl -s "$BASE_URL/admin/circuit-breaker/$PROVIDER" | jq .
echo ""

# 6. 测试失败请求（连续6次，触发熔断）
echo -e "${YELLOW}6. 测试失败请求（连续6次，触发熔断）${NC}"
echo "Failure threshold: $(echo "$CB_CONFIG" | jq -r '.failure_threshold // 5')"
echo ""
for i in {1..6}; do
    echo "Request $i:"
    RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/circuit-breaker?provider=$PROVIDER&fail=true")
    HTTP_CODE=$(echo "$RESULT" | tail -n1)
    BODY=$(echo "$RESULT" | head -n -1)
    
    if [ "$HTTP_CODE" == "500" ]; then
        echo -e "  ${RED}✗ Simulated Failure${NC}"
    else
        echo -e "  HTTP $HTTP_CODE"
    fi
    echo "$BODY" | jq -c .
    echo ""
done

# 7. 查看熔断器状态（应该是open）
echo -e "${YELLOW}7. 查看熔断器状态（应该是 open）${NC}"
curl -s "$BASE_URL/admin/circuit-breaker/$PROVIDER" | jq .
echo ""

# 8. 再次尝试请求（应该被熔断）
echo -e "${YELLOW}8. 再次尝试请求（应该被熔断，返回 503）${NC}"
RESULT=$(curl -s -w "\n%{http_code}" "$BASE_URL/admin/test/circuit-breaker?provider=$PROVIDER&fail=false")
HTTP_CODE=$(echo "$RESULT" | tail -n1)
BODY=$(echo "$RESULT" | head -n -1)
echo "HTTP Status: $HTTP_CODE"
echo "$BODY" | jq .
echo ""

# 9. 手动触发熔断（zerion）
echo -e "${YELLOW}9. 手动触发熔断（zerion）${NC}"
curl -s -X POST "$BASE_URL/admin/circuit-breaker/zerion/trip" | jq .
echo ""

# 10. 查看所有熔断器状态
echo -e "${YELLOW}10. 查看所有熔断器状态${NC}"
curl -s "$BASE_URL/admin/circuit-breaker" | jq .
echo ""

# 11. 恢复所有熔断器
echo -e "${YELLOW}11. 恢复所有熔断器${NC}"
curl -s -X POST "$BASE_URL/admin/circuit-breaker/zerion/reset" | jq -c '{message, provider, state: .state.state}'
curl -s -X POST "$BASE_URL/admin/circuit-breaker/$PROVIDER/reset" | jq -c '{message, provider, state: .state.state}'
echo ""

# 12. 最终状态确认
echo -e "${YELLOW}12. 最终状态确认${NC}"
curl -s "$BASE_URL/admin/circuit-breaker" | jq '.providers | to_entries[] | {provider: .key, state: .value.state}'
echo ""

echo -e "${GREEN}=== Circuit Breaker Test Complete ===${NC}"
echo ""
echo "Summary:"
echo "  - Circuit breaker states: closed (normal), open (tripped), half_open (recovering)"
echo "  - Failure threshold: consecutive failures needed to trip"
echo "  - Success threshold: consecutive successes needed to recover"
echo "  - Timeout: seconds to wait before entering half-open state"
echo ""
echo "Useful Commands:"
echo "  # View all circuit breakers"
echo "  curl -s \"$BASE_URL/admin/circuit-breaker\" | jq ."
echo ""
echo "  # Trip a circuit breaker manually"
echo "  curl -X POST \"$BASE_URL/admin/circuit-breaker/zerion/trip\""
echo ""
echo "  # Reset a circuit breaker"
echo "  curl -X POST \"$BASE_URL/admin/circuit-breaker/zerion/reset\""
echo ""
