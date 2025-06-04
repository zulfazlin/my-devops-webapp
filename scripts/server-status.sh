#!/bin/bash

# Server Status Monitoring Script
# Check the health and status of your web server

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
INSTANCE_TAG_NAME="my-webapp-server"
KEY_FILE="my-devops-key.pem"
SSH_USER="ec2-user"

print_header() {
    echo "================================================"
    echo "        Server Status & Health Check"
    echo "================================================"
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Get instance information
get_instance_info() {
    print_status "Fetching EC2 instance information..."
    
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress,PrivateIpAddress,InstanceType,LaunchTime]' \
        --output text)
    
    if [ "$INSTANCE_INFO" = "None	None	None	None	None	None" ]; then
        print_error "No instance found with tag Name=$INSTANCE_TAG_NAME"
        exit 1
    fi
    
    read INSTANCE_ID STATE PUBLIC_IP PRIVATE_IP INSTANCE_TYPE LAUNCH_TIME <<< "$INSTANCE_INFO"
    
    echo ""
    echo "🖥️  Instance Details:"
    echo "   Instance ID: $INSTANCE_ID"
    echo "   State: $STATE"
    echo "   Instance Type: $INSTANCE_TYPE"
    echo "   Public IP: $PUBLIC_IP"
    echo "   Private IP: $PRIVATE_IP"
    echo "   Launch Time: $LAUNCH_TIME"
    echo ""
}

# Check AWS resources
check_aws_resources() {
    print_status "Checking AWS resources..."
    
    if [ "$STATE" = "running" ]; then
        print_success "Instance is running"
    else
        print_warning "Instance state: $STATE"
    fi
    
    # Check security groups
    SG_INFO=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].[GroupId,GroupName]' \
        --output text)
    
    echo "   Security Group: $SG_INFO"
}

# Check server connectivity and services
check_server_status() {
    if [ "$STATE" != "running" ]; then
        print_error "Instance is not running. Cannot check server status."
        return 1
    fi
    
    print_status "Checking server connectivity and services..."
    
    # Test SSH connectivity
    if ssh -i "$KEY_FILE" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$PUBLIC_IP" "echo 'SSH OK'" > /dev/null 2>&1; then
        print_success "SSH connection working"
    else
        print_error "SSH connection failed"
        return 1
    fi
    
    # Check system status
    print_status "Getting system information..."
    ssh -i "$KEY_FILE" "$SSH_USER@$PUBLIC_IP" << 'EOF'
echo "📊 System Status:"

# System uptime
echo "   Uptime: $(uptime -p)"

# System load
echo "   Load Average: $(uptime | awk -F'load average:' '{print $2}')"

# Memory usage
echo "   Memory Usage:"
free -h | grep -E "Mem|Swap" | sed 's/^/     /'

# Disk usage
echo "   Disk Usage:"
df -h / | tail -1 | awk '{print "     Root: " $3 " used, " $4 " available (" $5 " used)"}'

echo ""
echo "🌐 Web Server Status:"

# Apache status
if systemctl is-active httpd > /dev/null 2>&1; then
    echo "   ✓ Apache: Running"
    echo "   ✓ Apache enabled: $(systemctl is-enabled httpd)"
else
    echo "   ✗ Apache: Not running"
fi

# Check web content
if [ -f /var/www/html/index.html ]; then
    echo "   ✓ Web content: Present"
    echo "   ✓ File size: $(ls -lh /var/www/html/index.html | awk '{print $5}')"
    echo "   ✓ Last modified: $(stat -c %y /var/www/html/index.html)"
else
    echo "   ✗ Web content: Missing"
fi

# Test HTTP response
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
if [ "$HTTP_STATUS" = "200" ]; then
    echo "   ✓ HTTP Response: $HTTP_STATUS (OK)"
else
    echo "   ✗ HTTP Response: $HTTP_STATUS (Error)"
fi

echo ""
echo "📝 Recent Apache Logs (last 5 lines):"
sudo tail -5 /var/log/httpd/access_log 2>/dev/null || echo "   No access logs found"
EOF
}

# Check external connectivity
check_external_access() {
    print_status "Testing external web access..."
    
    # Test HTTP from external
    HTTP_RESPONSE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://$PUBLIC_IP" 2>/dev/null || echo "000")
    
    if [ "$HTTP_RESPONSE" = "200" ]; then
        print_success "Website accessible from internet (HTTP $HTTP_RESPONSE)"
        echo "   🌐 Your site: http://$PUBLIC_IP"
    else
        print_error "Website not accessible from internet (HTTP $HTTP_RESPONSE)"
        print_warning "Check security group rules for port 80"
    fi
}

# Show useful commands
show_useful_commands() {
    echo ""
    echo "🔧 Useful Commands:"
    echo "   Connect to server: ssh -i $KEY_FILE $SSH_USER@$PUBLIC_IP"
    echo "   View Apache logs: ssh -i $KEY_FILE $SSH_USER@$PUBLIC_IP 'sudo tail -f /var/log/httpd/access_log'"
    echo "   Restart Apache: ssh -i $KEY_FILE $SSH_USER@$PUBLIC_IP 'sudo systemctl restart httpd'"
    echo "   Deploy updates: ./deploy.sh"
    echo ""
}

# Main function
main() {
    print_header
    get_instance_info
    check_aws_resources
    check_server_status
    check_external_access
    show_useful_commands
}

# Run main function
main "$@"