#!/bin/bash

# CloudWatch Monitoring Setup Script
# This script sets up comprehensive monitoring for your web application

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
ALARM_EMAIL="your-email@example.com"  # Replace with your email

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get instance information
get_instance_info() {
    print_status "Getting EC2 instance information..."
    
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' \
        --output text)
    
    read INSTANCE_ID INSTANCE_IP <<< "$INSTANCE_INFO"
    
    if [ "$INSTANCE_ID" = "None" ]; then
        print_error "No running instance found"
        exit 1
    fi
    
    print_success "Found instance: $INSTANCE_ID ($INSTANCE_IP)"
}

# Create SNS topic for alerts
setup_sns_alerts() {
    print_status "Setting up SNS topic for alerts..."
    
    # Create SNS topic
    TOPIC_ARN=$(aws sns create-topic --name devops-webapp-alerts --query 'TopicArn' --output text)
    print_success "Created SNS topic: $TOPIC_ARN"
    
    # Subscribe email to topic
    print_warning "Please replace 'your-email@example.com' with your actual email in the script"
    read -p "Enter your email for alerts: " USER_EMAIL
    
    if [ ! -z "$USER_EMAIL" ]; then
        aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$USER_EMAIL"
        print_success "Email subscription created. Check your email and confirm the subscription!"
    fi
    
    echo "$TOPIC_ARN" > .sns-topic-arn
}

# Create CloudWatch alarms
create_cloudwatch_alarms() {
    print_status "Creating CloudWatch alarms..."
    
    TOPIC_ARN=$(cat .sns-topic-arn)
    
    # High CPU alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "DevOps-WebApp-HighCPU" \
        --alarm-description "Alert when CPU exceeds 80%" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --threshold 80 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 2 \
        --alarm-actions "$TOPIC_ARN" \
        --dimensions Name=InstanceId,Value="$INSTANCE_ID"
    
    print_success "Created High CPU alarm"
    
    # Instance status check alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "DevOps-WebApp-StatusCheck" \
        --alarm-description "Alert when instance fails status check" \
        --metric-name StatusCheckFailed \
        --namespace AWS/EC2 \
        --statistic Maximum \
        --period 300 \
        --threshold 1 \
        --comparison-operator GreaterThanOrEqualToThreshold \
        --evaluation-periods 2 \
        --alarm-actions "$TOPIC_ARN" \
        --dimensions Name=InstanceId,Value="$INSTANCE_ID"
    
    print_success "Created Status Check alarm"
    
    # Memory usage alarm (requires custom metric)
    print_status "Note: Memory monitoring requires CloudWatch agent installation"
}

# Install CloudWatch agent on EC2
install_cloudwatch_agent() {
    print_status "Installing CloudWatch agent on EC2 instance..."
    
    # Create CloudWatch agent config
    cat > cloudwatch-config.json << 'EOF'
{
    "metrics": {
        "namespace": "CWAgent",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60,
                "totalcpu": false
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/httpd/access_log",
                        "log_group_name": "devops-webapp-access-logs",
                        "log_stream_name": "{instance_id}-access",
                        "timezone": "UTC"
                    },
                    {
                        "file_path": "/var/log/httpd/error_log",
                        "log_group_name": "devops-webapp-error-logs",
                        "log_stream_name": "{instance_id}-error",
                        "timezone": "UTC"
                    }
                ]
            }
        }
    }
}
EOF

    # Copy config to server
    scp -i "$KEY_FILE" cloudwatch-config.json "$SSH_USER@$INSTANCE_IP:/tmp/"
    
    # Install and configure CloudWatch agent
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        # Download and install CloudWatch agent
        wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
        sudo rpm -U ./amazon-cloudwatch-agent.rpm
        
        # Move config file
        sudo mv /tmp/cloudwatch-config.json /opt/aws/amazon-cloudwatch-agent/etc/
        
        # Start CloudWatch agent
        sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
            -a fetch-config \
            -m ec2 \
            -c file:/opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json \
            -s
        
        # Enable CloudWatch agent to start on boot
        sudo systemctl enable amazon-cloudwatch-agent
        
        echo "CloudWatch agent installed and configured"
EOF
    
    # Clean up local config file
    rm cloudwatch-config.json
    
    print_success "CloudWatch agent installed and configured"
}

# Create custom health check script
create_health_check() {
    print_status "Creating application health check..."
    
    # Create health check script for the server
    cat > health-check.sh << 'EOF'
#!/bin/bash

# Application Health Check Script
# Runs on the server to monitor application health

LOGFILE="/var/log/webapp-health.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Function to log with timestamp
log_message() {
    echo "[$TIMESTAMP] $1" >> "$LOGFILE"
}

# Check Apache status
check_apache() {
    if systemctl is-active httpd > /dev/null 2>&1; then
        log_message "HEALTH_CHECK: Apache is running"
        return 0
    else
        log_message "ERROR: Apache is not running"
        return 1
    fi
}

# Check HTTP response
check_http() {
    HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
    if [ "$HTTP_STATUS" = "200" ]; then
        log_message "HEALTH_CHECK: HTTP response OK ($HTTP_STATUS)"
        return 0
    else
        log_message "ERROR: HTTP response failed ($HTTP_STATUS)"
        return 1
    fi
}

# Check disk space
check_disk() {
    DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$DISK_USAGE" -lt 90 ]; then
        log_message "HEALTH_CHECK: Disk usage OK ($DISK_USAGE%)"
        return 0
    else
        log_message "WARNING: High disk usage ($DISK_USAGE%)"
        return 1
    fi
}

# Check memory
check_memory() {
    MEM_USAGE=$(free | awk 'FNR==2{printf "%.0f", $3/($3+$4)*100}')
    if [ "$MEM_USAGE" -lt 90 ]; then
        log_message "HEALTH_CHECK: Memory usage OK ($MEM_USAGE%)"
        return 0
    else
        log_message "WARNING: High memory usage ($MEM_USAGE%)"
        return 1
    fi
}

# Main health check
main() {
    log_message "Starting health check..."
    
    ERRORS=0
    
    check_apache || ERRORS=$((ERRORS + 1))
    check_http || ERRORS=$((ERRORS + 1))
    check_disk || ERRORS=$((ERRORS + 1))
    check_memory || ERRORS=$((ERRORS + 1))
    
    if [ $ERRORS -eq 0 ]; then
        log_message "HEALTH_CHECK: All checks passed"
        # Send custom metric to CloudWatch
        aws cloudwatch put-metric-data \
            --namespace "DevOps/WebApp" \
            --metric-data MetricName=HealthCheck,Value=1,Unit=Count \
            --region ap-southeast-1 2>/dev/null || true
    else
        log_message "HEALTH_CHECK: $ERRORS errors found"
        # Send custom metric to CloudWatch
        aws cloudwatch put-metric-data \
            --namespace "DevOps/WebApp" \
            --metric-data MetricName=HealthCheck,Value=0,Unit=Count \
            --region ap-southeast-1 2>/dev/null || true
    fi
    
    log_message "Health check completed"
}

main "$@"
EOF

    # Copy health check to server
    scp -i "$KEY_FILE" health-check.sh "$SSH_USER@$INSTANCE_IP:/tmp/"
    
    # Install health check on server
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        # Move script to proper location
        sudo mv /tmp/health-check.sh /usr/local/bin/
        sudo chmod +x /usr/local/bin/health-check.sh
        
        # Create log file
        sudo touch /var/log/webapp-health.log
        sudo chown ec2-user:ec2-user /var/log/webapp-health.log
        
        # Add to crontab (run every 5 minutes)
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/health-check.sh") | crontab -
        
        # Run initial health check
        /usr/local/bin/health-check.sh
        
        echo "Health check installed and scheduled"
EOF
    
    # Clean up local file
    rm health-check.sh
    
    print_success "Health check script installed and scheduled"
}

# Create dashboard
create_dashboard() {
    print_status "Creating CloudWatch dashboard..."
    
    cat > dashboard-config.json << EOF
{
    "widgets": [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "CPUUtilization", "InstanceId", "$INSTANCE_ID" ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "ap-southeast-1",
                "title": "EC2 CPU Utilization",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "DevOps/WebApp", "HealthCheck" ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "ap-southeast-1",
                "title": "Application Health",
                "period": 300
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 6,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE 'devops-webapp-access-logs' | fields @timestamp, @message\n| sort @timestamp desc\n| limit 20",
                "region": "ap-southeast-1",
                "title": "Recent Access Logs",
                "view": "table"
            }
        }
    ]
}
EOF

    # Create dashboard
    aws cloudwatch put-dashboard \
        --dashboard-name "DevOps-WebApp-Monitoring" \
        --dashboard-body file://dashboard-config.json
    
    rm dashboard-config.json
    
    print_success "CloudWatch dashboard created"
}

# Show monitoring summary
show_monitoring_summary() {
    print_success "=== MONITORING SETUP COMPLETE ==="
    echo ""
    echo "🎛️ CloudWatch Dashboard:"
    echo "   https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=DevOps-WebApp-Monitoring"
    echo ""
    echo "📊 CloudWatch Alarms:"
    echo "   - High CPU Usage (>80%)"
    echo "   - Instance Status Check Failed"
    echo ""
    echo "📧 SNS Alerts:"
    echo "   Topic ARN: $(cat .sns-topic-arn 2>/dev/null || echo 'Not configured')"
    echo "   Don't forget to confirm your email subscription!"
    echo ""
    echo "🔍 Health Checks:"
    echo "   - Automated every 5 minutes"
    echo "   - Logs: /var/log/webapp-health.log"
    echo "   - Custom metrics in CloudWatch"
    echo ""
    echo "📝 Log Groups:"
    echo "   - devops-webapp-access-logs"
    echo "   - devops-webapp-error-logs"
    echo ""
    echo "🛠️ Useful Commands:"
    echo "   View health logs: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP 'tail -f /var/log/webapp-health.log'"
    echo "   View Apache logs: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP 'sudo tail -f /var/log/httpd/access_log'"
    echo "   Manual health check: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP '/usr/local/bin/health-check.sh'"
    echo ""
}

# Main function
main() {
    echo "================================================"
    echo "    DevOps Learning - Monitoring Setup"
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
    
    # Execute setup steps
    get_instance_info
    setup_sns_alerts
    create_cloudwatch_alarms
    install_cloudwatch_agent
    create_health_check
    create_dashboard
    show_monitoring_summary
    
    print_success "🎉 Monitoring setup completed successfully!"
}

# Run main function
main "$@"