#!/bin/bash
# OpenResty API Proxy Gateway - 性能压测脚本
# 
# 使用方法:
#   ./scripts/benchmark.sh [gateway_url] [api_key]
#
# 示例:
#   ./scripts/benchmark.sh https://api.0x00fafa.com YOUR_API_KEY
#
# 依赖:
#   - wrk: https://github.com/wg/wrk
#   - hey: https://github.com/rakyll/hey (备选)
#   - jq: https://stedolan.github.io/jq/
#
# 安装依赖:
#   macOS: brew install wrk hey jq
#   Linux: 
#     wrk: git clone https://github.com/wg/wrk.git && cd wrk && make
#     hey: go install github.com/rakyll/hey@latest
#     jq: apt-get install jq
#
# 注意:
#   - 压测前会临时禁用限流器
#   - 压测会消耗实际的 API 调次数
#   - 建议在测试环境中进行，避免影响生产环境

#

set -e

# 默认参数
GATEWAY_URL="${1:-https://api.0x00fafa.com}"
API_KEY="${2:-}"
OUTPUT_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 压测参数
DURATION="30s"        # 每个测试持续时间
WARMUP="5s"           # 预热时间
CONNECTIONS=100       # 连接数
THREADS=4             # 线程数

# 结果存储
declare -A RESULTS
declare -A TEST_NAMES

# 初始化结果数组
RESULTS=()
TEST_NAMES=()

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}API Gateway Performance Benchmark${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Gateway URL: $GATEWAY_URL"
echo "Output Directory: $OUTPUT_DIR"
echo "Duration: $DURATION (warmup: $WARMUP)"
echo "Connections: $CONNECTIONS, Threads: $THREADS"
echo -e "${BLUE}============================================${NC}"
echo ""

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]]; then
        echo "redhat"
    else
        echo "linux"
    fi
}

# 安装 wrk
install_wrk() {
    local os=$(detect_os)
    echo -e "${YELLOW}Installing wrk...${NC}"
    
    case $os in
        macos)
            if command -v brew &> /dev/null; then
                brew install wrk
            else
                echo -e "${RED}Homebrew not found. Please install wrk manually.${NC}"
                return 1
            fi
            ;;
        debian)
            sudo apt-get update && sudo apt-get install -y wrk
            ;;
        redhat)
            sudo yum install -y epel-release && sudo yum install -y wrk
            ;;
        *)
            # 从源码编译
            echo -e "${YELLOW}Compiling wrk from source...${NC}"
            local tmp_dir=$(mktemp -d)
            git clone https://github.com/wg/wrk.git "$tmp_dir/wrk"
            cd "$tmp_dir/wrk" && make
            sudo cp wrk /usr/local/bin/
            cd - > /dev/null
            rm -rf "$tmp_dir"
            ;;
    esac
    
    if command -v wrk &> /dev/null; then
        echo -e "${GREEN}✓ wrk installed successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to install wrk${NC}"
        return 1
    fi
}

# 安装 hey
install_hey() {
    local os=$(detect_os)
    echo -e "${YELLOW}Installing hey...${NC}"
    
    case $os in
        macos)
            if command -v brew &> /dev/null; then
                brew install hey
            else
                echo -e "${RED}Homebrew not found. Please install hey manually.${NC}"
                return 1
            fi
            ;;
        *)
            if command -v go &> /dev/null; then
                go install github.com/rakyll/hey@latest
                # 确保 GOPATH/bin 在 PATH 中
                export PATH=$PATH:$(go env GOPATH)/bin
            else
                echo -e "${RED}Go not found. Please install Go first: https://golang.org/doc/install${NC}"
                return 1
            fi
            ;;
    esac
    
    if command -v hey &> /dev/null; then
        echo -e "${GREEN}✓ hey installed successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to install hey${NC}"
        return 1
    fi
}

# 检查工具是否安装
check_tools() {
    local has_wrk=0
    local has_hey=0
    
    if command -v wrk &> /dev/null; then
        has_wrk=1
        echo -e "${GREEN}✓ wrk is installed${NC}"
    else
        echo -e "${YELLOW}✗ wrk is not installed${NC}"
    fi
    
    if command -v hey &> /dev/null; then
        has_hey=1
        echo -e "${GREEN}✓ hey is installed${NC}"
    else
        echo -e "${YELLOW}✗ hey is not installed${NC}"
    fi
    
    # 如果都没有安装，尝试自动安装
    if [ $has_wrk -eq 0 ] && [ $has_hey -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}Neither wrk nor hey is installed. Attempting auto-install...${NC}"
        echo ""
        
        # 优先尝试安装 wrk（更轻量）
        if install_wrk; then
            has_wrk=1
        elif install_hey; then
            has_hey=1
        else
            echo -e "${RED}Error: Failed to install both wrk and hey!${NC}"
            echo ""
            echo "Please install manually:"
            echo "  wrk:"
            echo "    macOS: brew install wrk"
            echo "    Debian/Ubuntu: sudo apt-get install wrk"
            echo "    RHEL/CentOS: sudo yum install wrk"
            echo ""
            echo "  hey:"
            echo "    macOS: brew install hey"
            echo "    Linux: go install github.com/rakyll/hey@latest"
            exit 1
        fi
    fi
    
    if [ $has_wrk -eq 1 ]; then
        TOOL="wrk"
    else
        TOOL="hey"
    fi
    
    echo -e "${GREEN}Using $TOOL for benchmarking${NC}"
    echo ""
}

# 运行基准测试的函数
run_benchmark() {
    local name=$1
    local url=$2
    local headers=$3
    local output_file="$OUTPUT_DIR/${name}.txt"
    
    echo -e "${YELLOW}Testing: $url${NC}"
    echo "Output: $output_file"
    echo ""
    
    if [ "$TOOL" = "wrk" ]; then
        if [ -n "$headers" ]; then
            wrk -t$THREADS -c$CONNECTIONS -d$DURATION -H "$headers" "$url" > "$output_file" 2>&1
        else
            wrk -t$THREADS -c$CONNECTIONS -d$DURATION "$url" > "$output_file" 2>&1
        fi
    else
        # hey
        if [ -n "$headers" ]; then
            hey -z $DURATION -c $CONNECTIONS -q 1 -H "$headers" "$url" > "$output_file" 2>&1
        else
            hey -z $DURATION -c $CONNECTIONS -q 1 "$url" > "$output_file" 2>&1
        fi
    fi
    
    # 显示结果摘要
    echo -e "${GREEN}Results:${NC}"
    if [ "$TOOL" = "wrk" ]; then
        grep -E "Requests/sec" "$output_file" | tail -1
        grep -E "Latency.*" "$output_file" | tail -1
        grep -E "Transfer/sec" "$output_file" | tail -1
    else
        # hey
        tail -20 "$output_file"
    fi
    echo ""
    
    # 保存到数组
    RESULTS+=("$output_file")
    TEST_NAMES+=("$name")
}

# 保存配置的函数
save_config() {
    local config_file="$1"
    local config_name="$2"
    local config_value="$3"
    
    if [ ! -f "$config_file" ]; then
        echo "$config_name = $config_value" >> "$config_file"
    else
        echo "$config_name = $config_value" >> "$config_file"
    fi
}

# 恢复配置的函数
restore_config() {
    local config_file="$1"
    local config_name="$2"
    local config_value="$3"
    
    if [ -f "$config_file" ]; then
        # 恢复原值
        sed -i "s/^$config_name = .*/d" "$config_file"
        echo "$config_name = $config_value" >> "$config_file"
    fi
}

# 生成报告
generate_report() {
    local report_file="$OUTPUT_DIR/benchmark_report.md"
    
    echo "# API Gateway Performance Benchmark Report" > "$report_file"
    echo "" >> "$report_file"
    echo "**Generated:** $(date)" >> "$report_file"
    echo "" >> "$report_file"
    echo "**Gateway URL:** $GATEWAY_URL" >> "$report_file"
    echo "" >> "$report_file"
    echo "---" >> "$report_file"
    echo "" >> "$report_file"
    echo "## Test Environment" >> "$report_file"
    echo "" >> "$report_file"
    echo "- **Tool:** $TOOL" >> "$report_file"
    echo "- **Duration:** $DURATION" >> "$report_file"
    echo "- **Warmup:** $WARMUP" >> "$report_file"
    echo "- **Connections:** $CONNECTIONS" >> "$report_file"
    echo "- **Threads:** $THREADS" >> "$report_file"
    echo "" >> "$report_file"
    echo "---" >> "$report_file"
    echo "" >> "$report_file"
    
    # 解析每个测试结果
    for i in "${!TEST_NAMES[@]}"; do
        local name=$i
        local result_file="$OUTPUT_DIR/${name}.txt"
        
        echo "## Test: $name" >> "$report_file"
        echo "" >> "$report_file"
        
        if [ -f "$result_file" ]; then
            echo '```' >> "$report_file"
            cat "$result_file" >> "$report_file"
            echo '```' >> "$report_file"
            echo "" >> "$report_file"
        fi
    done
    
    echo "---" >> "$report_file"
    echo "" >> "$report_file"
    echo "## Summary" >> "$report_file"
    echo "" >> "$report_file"
    echo "See individual test files for detailed results." >> "$report_file"
}

# 检查工具
check_tools

# 1. 禁用限流器
echo -e "${YELLOW}1. Disabling rate limiter...${NC}"
echo "Current config:"
curl -s "$GATEWAY_URL/admin/config/rate_limiter" | jq . 2>/dev/null || echo "Unable to get config"
echo ""
echo "Disabling..."
curl -s -X PUT "$GATEWAY_URL/admin/config/rate_limiter" \
    -H "Content-Type: application/json" \
    -d '{"value":{"enabled":false}}' | jq . 2>/dev/null || echo "Failed"
echo ""
echo -e "${GREEN}✓ Rate limiter disabled${NC}"
echo ""

# 2. 禁用熔断器
echo -e "${YELLOW}2. Disabling circuit breaker...${NC}"
echo "Current config:"
curl -s "$GATEWAY_URL/admin/config/circuit_breaker" | jq . 2>/dev/null || echo "Unable to get config"
echo ""
echo "Disabling..."
curl -s -X PUT "$GATEWAY_URL/admin/config/circuit_breaker" \
    -H "Content-Type: application/json" \
    -d '{"value":{"enabled":false}}' | jq . 2>/dev/null || echo "Failed"
echo ""
echo -e "${GREEN}✓ Circuit breaker disabled${NC}"
echo ""

# 3. 禁用缓存
echo -e "${YELLOW}3. Disabling cache...${NC}"
echo "Current config:"
curl -s "$GATEWAY_URL/admin/config/cache" | jq . 2>/dev/null || echo "Unable to get config"
echo ""
echo "Disabling..."
curl -s -X PUT "$GATEWAY_URL/admin/config/cache" \
    -H "Content-Type: application/json" \
    -d '{"value":{"enabled":false}}' | jq . 2>/dev/null || echo "Failed"
echo ""
echo -e "${GREEN}✓ Cache disabled${NC}"
echo ""

# 4. 预热
echo -e "${YELLOW}4. Warming up... (5 seconds)${NC}"
echo "Sending warmup requests to /health endpoint..."
for i in {1..3}; do
    curl -s "$GATEWAY_URL/health" > /dev/null
    echo "Warmup request $i sent"
done
echo ""
echo -e "${GREEN}✓ Warmup complete${NC}"
echo ""

# 5. 运行基准测试
echo -e "${YELLOW}5. Running baseline test: Health Check (no upstream)${NC}"
echo "Testing: $GATEWAY_URL/health"
echo ""

run_benchmark "health" "$GATEWAY_URL/health" ""

# 6. 测试缓存场景
echo -e "${YELLOW}6. Testing cached endpoint (CoinGecko ping)${NC}"
echo "This tests the caching functionality."
echo "Testing: $GATEWAY_URL/coingecko/api/v3/ping"
echo ""

if [ -n "$API_KEY" ]; then
    run_benchmark "coingecko_cached" "$GATEWAY_URL/coingecko/api/v3/ping" "X-API-Key: $API_KEY"
else
    run_benchmark "coingecko_cached" "$GATEWAY_URL/coingecko/api/v3/ping" ""
fi
echo ""

# 7. 测试代理转发场景（需要 API Key)
echo -e "${YELLOW}7. Testing proxy endpoint (CoinGecko prices)${NC}"
echo "This tests the full proxy chain with upstream API."
echo "Testing: $GATEWAY_URL/coingecko/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
echo ""

if [ -n "$API_KEY" ]; then
    run_benchmark "coingecko_proxy" "$GATEWAY_URL/coingecko/api/v3/simple/price?ids=bitcoin&vs_currencies=usd" "X-API-Key: $API_KEY"
else
    echo -e "${RED}Error: API_KEY is required for proxy test${NC}"
    echo "Please provide API_KEY as the second argument"
    echo ""
    echo "Example: $0 $GATEWAY_URL YOUR_API_KEY"
    exit 1
fi
echo ""

# 8. 生成报告
echo -e "${YELLOW}8. Generating benchmark report...${NC}"
generate_report

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Benchmark Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "Files:"
ls -la "$OUTPUT_DIR"

echo ""
echo "To view this report, run:"
echo "  cat $OUTPUT_DIR/benchmark_report.md"
echo ""
