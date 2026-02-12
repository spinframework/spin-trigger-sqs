#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SQS_ENDPOINT="${SQS_ENDPOINT:-http://localhost:9324}"
TEST_QUEUE_NAME="${TEST_QUEUE_NAME:-test-queue}"
SPIN_OUTPUT_LOG="guest/.spin/logs/localtest_stdout.txt"
SPIN_PID=""
MESSAGE="test-value"
MESSAGE_BODY="Test message from e2e test"
ATTRIBUTE_NAME="glonk"

rm -rf guest/.spin

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo -e "${GREEN}=== Spin SQS Trigger E2E Test ===${NC}"

# Function to cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [ ! -z "$SPIN_PID" ] && kill -0 "$SPIN_PID" 2>/dev/null; then
        echo "Stopping Spin process (PID: $SPIN_PID)..."
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
    fi

    # Delete the test queue
    if [ ! -z "$QUEUE_URL" ]; then
        echo "Deleting test queue..."
        aws sqs delete-queue --queue-url "$QUEUE_URL" --endpoint-url "$SQS_ENDPOINT" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# Check if ElasticMQ is running
echo "Checking if ElasticMQ is accessible at $SQS_ENDPOINT..."
# ElasticMQ returns 400 for requests without proper SQS actions, but that means it's running
# We just need to check if we get any response (not a connection error)
if ! curl -s "$SQS_ENDPOINT/" > /dev/null 2>&1; then
    echo -e "${RED}Error: ElasticMQ is not accessible at $SQS_ENDPOINT${NC}"
    echo "Please start ElasticMQ first:"
    echo "  make setup-elasticmq    (starts ElasticMQ in Docker container)"
    echo "Or use 'make test-e2e-full' to automatically set up and tear down ElasticMQ"
    exit 1
fi
echo -e "${GREEN}✓ ElasticMQ is running${NC}"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}⚠ Docker is not installed (optional for local testing)${NC}"
else
    echo -e "${GREEN}✓ Docker is available${NC}"
fi

# Check if aws CLI is available
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    echo "Please install the AWS CLI: https://aws.amazon.com/cli/"
    exit 1
fi
echo -e "${GREEN}✓ AWS CLI is available${NC}"

# Check if spin is available
if ! command -v spin &> /dev/null; then
    echo -e "${RED}Error: Spin is not installed${NC}"
    echo "Please install Spin: https://developer.fermyon.com/spin/install"
    exit 1
fi
echo -e "${GREEN}✓ Spin is available${NC}"

# Build and install the plugin
echo -e "\n${GREEN}Building and installing the SQS trigger plugin...${NC}"
cargo build --release
spin pluginify --install

echo -e "\n${GREEN}✓ Plugin installed${NC}"

# Create SQS queue
echo -e "\n${GREEN}Creating SQS queue '$TEST_QUEUE_NAME'...${NC}"
QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$TEST_QUEUE_NAME" \
    --endpoint-url "$SQS_ENDPOINT" \
    --query 'QueueUrl' \
    --output text)

if [ -z "$QUEUE_URL" ]; then
    echo -e "${RED}Error: Failed to create queue${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Queue created: $QUEUE_URL${NC}"

# Update guest/spin.toml with the queue URL
echo -e "\n${GREEN}Updating guest/spin.toml with queue URL...${NC}"

# Backup original spin.toml
cp guest/spin.toml guest/spin.toml.backup

# Replace queue_url
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS sed syntax
    sed -i '' "s|queue_url = \".*\"|queue_url = \"$QUEUE_URL\"|g" guest/spin.toml
else
    # Linux sed syntax
    sed -i "s|queue_url = \".*\"|queue_url = \"$QUEUE_URL\"|g" guest/spin.toml
fi

echo -e "${GREEN}✓ Updated spin.toml${NC}"

# Build the guest application
echo -e "\n${GREEN}Building guest application...${NC}"
spin build  --from guest
echo -e "${GREEN}✓ Guest application built${NC}"

# Start Spin application
echo -e "\n${GREEN}Starting Spin application...${NC}"
AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
AWS_ENDPOINT_URL="$SQS_ENDPOINT" \
AWS_ENDPOINT_URL_SQS="$SQS_ENDPOINT" \
spin up --from guest &
SPIN_PID=$!

echo "Spin started with PID: $SPIN_PID"
echo "Waiting for Spin to initialize..."
sleep 10

# Check if Spin is still running
if ! kill -0 "$SPIN_PID" 2>/dev/null; then
    echo -e "${RED}Error: Spin process died unexpectedly${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Spin is running${NC}"

# Send test message to SQS
echo -e "\n${GREEN}Sending test message to SQS queue...${NC}"
MESSAGE_ID=$(aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$MESSAGE_BODY" \
    --message-attributes "{\"$ATTRIBUTE_NAME\":{\"DataType\":\"String\",\"StringValue\":\"$MESSAGE\"}}" \
    --endpoint-url "$SQS_ENDPOINT" \
    --query 'MessageId' \
    --output text)

echo -e "${GREEN}✓ Message sent (ID: $MESSAGE_ID)${NC}"

# Wait for message to be processed
echo "Waiting for message to be processed..."
sleep 15

# Restore original spin.toml
mv guest/spin.toml.backup guest/spin.toml

# Verify output
echo -e "\n${GREEN}Verifying output...${NC}"
echo -e "\n${YELLOW}=== Spin Application Output ===${NC}"
cat "$SPIN_OUTPUT_LOG"
echo -e "${YELLOW}===============================${NC}\n"

# Check for expected output
TEST_PASSED=true

if grep -q "$MESSAGE" "$SPIN_OUTPUT_LOG"; then
    echo -e "${GREEN}✓ Found '$MESSAGE' in output${NC}"
else
    echo -e "${RED}✗ Did not find '$MESSAGE' in output${NC}"
    TEST_PASSED=false
fi

if grep -q "ATTR $ATTRIBUTE_NAME:" "$SPIN_OUTPUT_LOG"; then
    echo -e "${GREEN}✓ Found message attribute '$ATTRIBUTE_NAME' in output${NC}"
else
    echo -e "${YELLOW}⚠ Did not find expected message attribute '$ATTRIBUTE_NAME'${NC}"
fi

if grep -q "$MESSAGE_BODY" "$SPIN_OUTPUT_LOG"; then
    echo -e "${GREEN}✓ Found message body in output${NC}"
else
    echo -e "${YELLOW}⚠ Did not find message body${NC}"
fi

if [ "$TEST_PASSED" = true ]; then
    echo -e "\n${GREEN}=== E2E Test PASSED ===${NC}"
    exit 0
else
    echo -e "\n${RED}=== E2E Test FAILED ===${NC}"
    exit 1
fi
