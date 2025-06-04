#!/bin/bash

# Alert Testing Script
# Tests your monitoring and alerting system

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

print_status() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Get instance info
get_instance_info() {
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' \
        --output text)
    
    read INSTANCE_ID INSTANCE_IP <<< "$INSTANCE_INFO"
    
    if [ "$INSTANCE_ID" = "None" ]; then
        print_error "No running instance found"
        exit 1
    fi
}

# Test 1: CloudWatch agent status
test_cloudwatch_agent() {
    print_status "Testing CloudWatch agent..."
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        if systemctl is-active amazon-cloudwatch-agent > /dev/null 2>&1; then
            echo "PASS: CloudWatch agent is running"
        else
            echo "FAIL: CloudWatch agent is not running"
            exit 1
        fi
        
        # Check if agent is sending metrics
        if [ -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log ]; then
            if grep -q "Successfully sent metrics" /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log; then
                echo "PASS: Agent is sending metrics"
            else
                echo "WARN: No recent metric sends found in logs"
            fi
        else
            echo "WARN: CloudWatch agent log not found"
        fi
EOF
    
    if [ $? -eq 0 ]; then
        print_success "CloudWatch agent test passed"
    else
        print_error "CloudWatch agent test failed"
    fi
}

# Test 2: Health check functionality
test_health_checks() {
    print_status "Testing health check system..."
    
    # Run manual health check
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        if [ -f /usr/local/bin/health-check.sh ]; then
            echo "PASS: Health check script exists"
            
            # Run health check
            /usr/local/bin/health-check.sh
            
            # Check if log was updated
            if [ -f /var/log/webapp-health.log ]; then
                LAST_CHECK=$(tail -1 /var/log/webapp-health.log)
                echo "PASS: Health check executed - $LAST_CHECK"
            else
                echo "FAIL: Health check log not found"
                exit 1
            fi
        else
            echo "FAIL: Health check script not found"
            exit 1
        fi
        
        # Check cron job
        if crontab -l | grep -q "health-check.sh"; then
            echo "PASS: Health check is scheduled in cron"
        else
            echo "WARN: Health check not found in cron"
        fi
EOF
    
    if [ $? -eq 0 ]; then
        print_success "Health check test passed"
    else
        print_error "Health check test failed"
    fi
}

# Test 3: Log collection
test_log_collection() {
    print_status "Testing log collection..."
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        # Check if logs exist
        if [ -f /var/log/httpd/access_log ]; then
            echo "PASS: Apache access log exists"
            
            # Generate a test entry
            curl -s http://localhost > /dev/null
            sleep 2
            
            # Check if entry was logged
            if tail -1 /var/log/httpd/access_log | grep -q "$(date +'%d/%b/%Y')"; then
                echo "PASS: Access log is being updated"
            else
                echo "WARN: Access log may not be updating properly"
            fi
        else
            echo "FAIL: Apache access log not found"
        fi
        
        if [ -f /var/log/httpd/error_log ]; then
            echo "PASS: Apache error log exists"
        else
            echo "FAIL: Apache error log not found"
        fi
        
        if [ -f /var/log/webapp-health.log ]; then
            echo "PASS: Health check log exists"
        else
            echo "WARN: Health check log not found"
        fi
EOF
    
    print_success "Log collection test completed"
}

# Test 4: CloudWatch metrics
test_cloudwatch_metrics() {
    print_status "Testing CloudWatch metrics..."
    
    # Check if custom metrics are being sent
    RECENT_METRICS=$(aws cloudwatch get-metric-statistics \
        --namespace "DevOps/WebApp" \
        --metric-name "HealthCheck" \
        --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
        --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
        --period 300 \
        --statistics Sum \
        --query 'Datapoints | length(@)')
    
    if [ "$RECENT_METRICS" -gt 0 ]; then
        print_success "Custom health check metrics found in CloudWatch"
    else
        print_warning "No recent health check metrics in CloudWatch"
    fi
    
    # Check EC2 metrics
    EC2_METRICS=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/EC2" \
        --metric-name "CPUUtilization" \
        --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
        --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
        --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
        --period 300 \
        --statistics Average \
        --query 'Datapoints | length(@)')
    
    if [ "$EC2_METRICS" -gt 0 ]; then
        print_success "EC2 metrics are being collected"
    else
        print_warning "No recent EC2 metrics found"
    fi
}

# Test 5: SNS alerts
test_sns_alerts() {
    print_status "Testing SNS alert system..."
    
    if [ -f .sns-topic-arn ]; then
        TOPIC_ARN=$(cat .sns-topic-arn)
        print_success "SNS topic found: $TOPIC_ARN"
        
        # Send test notification
        print_status "Sending test alert..."
        aws sns publish \
            --topic-arn "$TOPIC_ARN" \
            --subject "DevOps WebApp - Test Alert" \
            --message "This is a test alert from your DevOps monitoring system. If you receive this, your alerts are working correctly! Timestamp: $(date)"
        
        print_success "Test alert sent - check your email!"
    else
        print_warning "SNS topic ARN file not found - alerts may not be configured"
    fi
}

# Test 6: CloudWatch alarms
test_cloudwatch_alarms() {
    print_status "Testing CloudWatch alarms..."
    
    # List alarms
    ALARMS=$(aws cloudwatch describe-alarms \
        --alarm-name-prefix "DevOps-WebApp" \
        --query 'MetricAlarms[*].[AlarmName,StateValue]' \
        --output text)
    
    if [ ! -z "$ALARMS" ]; then
        print_success "CloudWatch alarms found:"
        echo "$ALARMS" | while read alarm_name state; do
            if [ "$state" = "OK" ]; then
                state_color=$GREEN
            elif [ "$state" = "ALARM" ]; then
                state_color=$RED
            else
                state_color=$YELLOW
            fi
            echo -e "   ${alarm_name}: ${state_color}${state}${NC}"
        done
    else
        print_warning "No CloudWatch alarms found"
    fi
}

# Test 7: Simulated load test
simulate_load_test() {
    print_status "Running simulated load test..."
    
    print_warning "This will generate artificial load on your server"
    read -p "Continue? (y/N): " confirm
    
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
            echo "Generating 50 HTTP requests..."
            for i in {1..50}; do
                curl -s http://localhost > /dev/null &
                sleep 0.1
            done
            wait
            
            echo "Load test completed"
            echo "Check your monitoring dashboard for traffic spike"
EOF
        
        print_success "Load test completed - check your monitoring!"
    else
        print_status "Load test skipped"
    fi
}

# Test 8: Dashboard accessibility
test_dashboard() {
    print_status "Testing CloudWatch dashboard..."
    
    # Check if dashboard exists
    DASHBOARD_EXISTS=$(aws cloudwatch get-dashboard \
        --dashboard-name "DevOps-WebApp-Monitoring" \
        --query 'DashboardName' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$DASHBOARD_EXISTS" != "None" ]; then
        print_success "CloudWatch dashboard exists"
        echo "   View at: https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=DevOps-WebApp-Monitoring"
    else
        print_warning "CloudWatch dashboard not found"
    fi
}

# Generate test report
generate_test_report() {
    echo ""
    echo "================================================"
    echo "           MONITORING TEST REPORT"
    echo "================================================"
    echo "Test Date: $(date)"
    echo "Instance: $INSTANCE_ID ($INSTANCE_IP)"
    echo ""
    echo "✅ Tests Completed:"
    echo "   • CloudWatch Agent Status"
    echo "   • Health Check System"
    echo "   • Log Collection"
    echo "   • CloudWatch Metrics"
    echo "   • SNS Alerts"
    echo "   • CloudWatch Alarms"
    echo "   • Dashboard Access"
    if [ "$load_test_run" = "true" ]; then
        echo "   • Load Testing"
    fi
    echo ""
    echo "📋 Next Steps:"
    echo "   1. Check your email for test alert"
    echo "   2. Verify metrics in CloudWatch console"
    echo "   3. Review dashboard for recent activity"
    echo "   4. Monitor logs for any issues"
    echo ""
    echo "🔗 Quick Links:"
    echo "   CloudWatch Console: https://ap-southeast-1.console.aws.amazon.com/cloudwatch/"
    echo "   Your Dashboard: https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=DevOps-WebApp-Monitoring"
    echo ""
}

# Main function
main() {
    echo "================================================"
    echo "    DevOps Learning - Alert System Testing"
    echo "================================================"
    echo ""
    
    # Check prerequisites
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        print_error "AWS CLI not configured"
        exit 1
    fi
    
    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key file not found: $KEY_FILE"
        exit 1
    fi
    
    # Get instance information
    get_instance_info
    print_status "Testing monitoring for instance: $INSTANCE_ID ($INSTANCE_IP)"
    echo ""
    
    # Run all tests
    test_cloudwatch_agent
    echo ""
    test_health_checks
    echo ""
    test_log_collection
    echo ""
    test_cloudwatch_metrics
    echo ""
    test_sns_alerts
    echo ""
    test_cloudwatch_alarms
    echo ""
    test_dashboard
    echo ""
    
    # Optional load test
    load_test_run="false"
    if [ "$1" = "--load-test" ]; then
        simulate_load_test
        load_test_run="true"
        echo ""
    fi
    
    # Generate report
    generate_test_report
    
    print_success "🎉 Monitoring system testing completed!"
}

# Show usage
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Alert System Testing Script"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help        Show this help"
    echo "  --load-test   Include simulated load testing"
    echo ""
    echo "This script tests all components of your monitoring system:"
    echo "  • CloudWatch agent"
    echo "  • Health checks"
    echo "  • Log collection"
    echo "  • Metrics reporting"
    echo "  • SNS alerts"
    echo "  • CloudWatch alarms"
    echo "  • Dashboard functionality"
    echo ""
    exit 0
fi

# Run main function
main "$@"