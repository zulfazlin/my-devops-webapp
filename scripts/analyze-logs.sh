#!/bin/bash

# Log Analysis Script
# Analyzes web server logs and provides insights

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
    echo -e "${BLUE}$1${NC}"
}

print_stat() {
    echo -e "${GREEN}[STAT]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Get instance IP
get_instance_ip() {
    INSTANCE_IP=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [ "$INSTANCE_IP" = "None" ]; then
        echo "No running instance found"
        exit 1
    fi
}

# Analyze Apache access logs
analyze_access_logs() {
    print_header "=== APACHE ACCESS LOG ANALYSIS ==="
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        if [ ! -f /var/log/httpd/access_log ]; then
            echo "Access log not found"
            exit 1
        fi
        
        echo "📊 Traffic Statistics (Last 24 hours):"
        echo "========================================"
        
        # Total requests
        TOTAL_REQUESTS=$(grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | wc -l)
        echo "   Total Requests: $TOTAL_REQUESTS"
        
        # Unique visitors (by IP)
        UNIQUE_IPS=$(grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk '{print $1}' | sort | uniq | wc -l)
        echo "   Unique Visitors: $UNIQUE_IPS"
        
        # Status code breakdown
        echo ""
        echo "📈 HTTP Status Codes:"
        echo "===================="
        grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk '{print $9}' | sort | uniq -c | sort -nr | head -10 | while read count code; do
            echo "   $code: $count requests"
        done
        
        # Top requesting IPs
        echo ""
        echo "🌍 Top Requesting IPs:"
        echo "====================="
        grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk '{print $1}' | sort | uniq -c | sort -nr | head -10 | while read count ip; do
            echo "   $ip: $count requests"
        done
        
        # Most requested pages
        echo ""
        echo "📄 Most Requested Pages:"
        echo "========================"
        grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk '{print $7}' | sort | uniq -c | sort -nr | head -10 | while read count page; do
            echo "   $page: $count requests"
        done
        
        # User agents (browsers)
        echo ""
        echo "🖥️ Top User Agents:"
        echo "=================="
        grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk -F'"' '{print $6}' | sort | uniq -c | sort -nr | head -5 | while read count agent; do
            echo "   $agent: $count requests"
        done
        
        # Peak hours
        echo ""
        echo "⏰ Traffic by Hour:"
        echo "=================="
        grep "$(date +'%d/%b/%Y')" /var/log/httpd/access_log | awk '{print $4}' | cut -c14-15 | sort | uniq -c | sort -k2 -n | while read count hour; do
            printf "   %02d:00: %s requests\n" $hour $count
        done
        
        # Response times (if available)
        echo ""
        echo "⚡ Recent Response Analysis:"
        echo "==========================="
        tail -100 /var/log/httpd/access_log | awk '{print $10}' | awk '$1 > 0 {sum+=$1; count++} END {if(count>0) printf "   Average response size: %.0f bytes\n", sum/count}'
        
EOF
}

# Analyze error logs
analyze_error_logs() {
    print_header "=== APACHE ERROR LOG ANALYSIS ==="
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        if [ ! -f /var/log/httpd/error_log ]; then
            echo "Error log not found"
            exit 1
        fi
        
        echo "🚨 Error Summary (Last 24 hours):"
        echo "================================="
        
        # Count errors by type
        TODAY=$(date +'%a %b %d')
        
        ERROR_COUNT=$(grep "$TODAY" /var/log/httpd/error_log | wc -l)
        echo "   Total Errors: $ERROR_COUNT"
        
        if [ $ERROR_COUNT -gt 0 ]; then
            echo ""
            echo "🔍 Error Types:"
            echo "==============="
            grep "$TODAY" /var/log/httpd/error_log | awk -F']' '{print $3}' | awk -F'[' '{print $1}' | sort | uniq -c | sort -nr | head -10 | while read count error; do
                echo "   $error: $count occurrences"
            done
            
            echo ""
            echo "🕐 Recent Errors (Last 10):"
            echo "=========================="
            tail -10 /var/log/httpd/error_log | while read line; do
                echo "   $line"
            done
        else
            echo "   ✅ No errors found in the last 24 hours!"
        fi
        
EOF
}

# Analyze system health logs
analyze_health_logs() {
    print_header "=== APPLICATION HEALTH ANALYSIS ==="
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        if [ ! -f /var/log/webapp-health.log ]; then
            echo "Health log not found - run health checks first"
            exit 1
        fi
        
        echo "💊 Health Check Summary:"
        echo "======================="
        
        # Count successful vs failed checks
        TOTAL_CHECKS=$(grep "HEALTH_CHECK:" /var/log/webapp-health.log | wc -l)
        PASSED_CHECKS=$(grep "All checks passed" /var/log/webapp-health.log | wc -l)
        FAILED_CHECKS=$((TOTAL_CHECKS - PASSED_CHECKS))
        
        echo "   Total Health Checks: $TOTAL_CHECKS"
        echo "   Passed: $PASSED_CHECKS"
        echo "   Failed: $FAILED_CHECKS"
        
        if [ $TOTAL_CHECKS -gt 0 ]; then
            SUCCESS_RATE=$(echo "scale=2; $PASSED_CHECKS * 100 / $TOTAL_CHECKS" | bc -l 2>/dev/null || echo "0")
            echo "   Success Rate: ${SUCCESS_RATE}%"
        fi
        
        echo ""
        echo "⚠️ Recent Issues:"
        echo "================"
        grep -E "ERROR|WARNING" /var/log/webapp-health.log | tail -5 | while read line; do
            echo "   $line"
        done
        
        echo ""
        echo "📊 Last 10 Health Checks:"
        echo "========================"
        tail -10 /var/log/webapp-health.log | while read line; do
            echo "   $line"
        done
        
EOF
}

# Generate performance report
generate_performance_report() {
    print_header "=== PERFORMANCE REPORT ==="
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        echo "🖥️ System Performance:"
        echo "====================="
        
        # CPU usage
        echo "   CPU Usage: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')"
        
        # Memory usage
        echo "   Memory Usage: $(free | awk 'FNR==2{printf "%.1f%%", $3/($3+$4)*100}')"
        
        # Disk usage
        echo "   Disk Usage: $(df / | tail -1 | awk '{print $5}')"
        
        # Load average
        echo "   Load Average: $(uptime | awk -F'load average:' '{print $2}')"
        
        # Network connections
        CONNECTIONS=$(ss -tun | wc -l)
        echo "   Active Connections: $CONNECTIONS"
        
        # Apache processes
        APACHE_PROCESSES=$(ps aux | grep httpd | grep -v grep | wc -l)
        echo "   Apache Processes: $APACHE_PROCESSES"
        
        echo ""
        echo "🌐 Web Server Stats:"
        echo "=================="
        
        # Test response time
        RESPONSE_TIME=$(curl -o /dev/null -s -w '%{time_total}' http://localhost)
        echo "   Response Time: ${RESPONSE_TIME}s"
        
        # Check if Apache is responding
        HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
        if [ "$HTTP_STATUS" = "200" ]; then
            echo "   Status: ✅ Healthy (HTTP $HTTP_STATUS)"
        else
            echo "   Status: ❌ Issues (HTTP $HTTP_STATUS)"
        fi
        
EOF
}

# Generate recommendations
generate_recommendations() {
    print_header "=== RECOMMENDATIONS ==="
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        echo "💡 Optimization Suggestions:"
        echo "==========================="
        
        # Check disk space
        DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
        if [ $DISK_USAGE -gt 80 ]; then
            echo "   ⚠️ High disk usage ($DISK_USAGE%) - Consider cleanup or larger storage"
        else
            echo "   ✅ Disk usage acceptable ($DISK_USAGE%)"
        fi
        
        # Check memory
        MEM_USAGE=$(free | awk 'FNR==2{printf "%.0f", $3/($3+$4)*100}')
        if [ $MEM_USAGE -gt 80 ]; then
            echo "   ⚠️ High memory usage ($MEM_USAGE%) - Consider optimizing or upgrading"
        else
            echo "   ✅ Memory usage acceptable ($MEM_USAGE%)"
        fi
        
        # Check log rotation
        ACCESS_LOG_SIZE=$(ls -lh /var/log/httpd/access_log | awk '{print $5}')
        echo "   📄 Access log size: $ACCESS_LOG_SIZE"
        
        # Check for security
        FAILED_LOGINS=$(grep "Failed password" /var/log/secure 2>/dev/null | wc -l || echo "0")
        if [ $FAILED_LOGINS -gt 10 ]; then
            echo "   🔒 Security: $FAILED_LOGINS failed login attempts - consider security hardening"
        else
            echo "   🔒 Security: No significant failed login attempts"
        fi
        
        echo ""
        echo "🚀 Next Steps:"
        echo "============="
        echo "   • Set up log rotation for Apache logs"
        echo "   • Consider implementing HTTPS/SSL"
        echo "   • Add automated backups"
        echo "   • Implement rate limiting"
        echo "   • Consider using a CDN for static content"
        
EOF
}

# Export logs for analysis
export_logs() {
    print_header "=== EXPORTING LOGS ==="
    echo ""
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    EXPORT_DIR="logs_export_$TIMESTAMP"
    mkdir -p "$EXPORT_DIR"
    
    echo "📁 Exporting logs to: $EXPORT_DIR"
    
    # Download recent logs
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "sudo tail -1000 /var/log/httpd/access_log" > "$EXPORT_DIR/access_log_recent.txt" 2>/dev/null || echo "Could not export access log"
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "sudo tail -500 /var/log/httpd/error_log" > "$EXPORT_DIR/error_log_recent.txt" 2>/dev/null || echo "Could not export error log"
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "cat /var/log/webapp-health.log" > "$EXPORT_DIR/health_log.txt" 2>/dev/null || echo "Could not export health log"
    
    # Create analysis summary
    cat > "$EXPORT_DIR/analysis_summary.txt" << EOF
Log Analysis Summary
Generated: $(date)
Instance IP: $INSTANCE_IP

Files exported:
- access_log_recent.txt: Last 1000 Apache access log entries
- error_log_recent.txt: Last 500 Apache error log entries  
- health_log.txt: Complete application health check log

Use these files for:
- Traffic pattern analysis
- Error investigation
- Performance trending
- Security audit
EOF
    
    echo "✅ Logs exported successfully to: $EXPORT_DIR"
    echo "📊 Files created:"
    ls -la "$EXPORT_DIR/"
}

# Main menu
show_menu() {
    echo ""
    echo "=== LOG ANALYSIS MENU ==="
    echo "1. Analyze Access Logs"
    echo "2. Analyze Error Logs" 
    echo "3. Analyze Health Logs"
    echo "4. Performance Report"
    echo "5. Generate Recommendations"
    echo "6. Export Logs"
    echo "7. Full Analysis Report"
    echo "8. Exit"
    echo ""
    read -p "Select option (1-8): " choice
}

# Full analysis report
full_analysis() {
    echo "================================================"
    echo "    COMPLETE LOG ANALYSIS REPORT"
    echo "    Generated: $(date)"
    echo "================================================"
    
    analyze_access_logs
    echo ""
    analyze_error_logs
    echo ""
    analyze_health_logs
    echo ""
    generate_performance_report
    echo ""
    generate_recommendations
    
    echo ""
    echo "================================================"
    echo "    ANALYSIS COMPLETE"
    echo "================================================"
}

# Main function
main() {
    echo "================================================"
    echo "    DevOps Learning - Log Analysis Tool"
    echo "================================================"
    
    # Get instance info
    get_instance_ip
    echo "📡 Connected to instance: $INSTANCE_IP"
    
    # Check if interactive mode
    if [ $# -eq 0 ]; then
        # Interactive menu
        while true; do
            show_menu
            case $choice in
                1) analyze_access_logs ;;
                2) analyze_error_logs ;;
                3) analyze_health_logs ;;
                4) generate_performance_report ;;
                5) generate_recommendations ;;
                6) export_logs ;;
                7) full_analysis ;;
                8) echo "Goodbye!"; exit 0 ;;
                *) echo "Invalid option. Please try again." ;;
            esac
            echo ""
            read -p "Press Enter to continue..."
        done
    else
        # Command line mode
        case "$1" in
            "access") analyze_access_logs ;;
            "error") analyze_error_logs ;;
            "health") analyze_health_logs ;;
            "performance") generate_performance_report ;;
            "recommendations") generate_recommendations ;;
            "export") export_logs ;;
            "full") full_analysis ;;
            *) 
                echo "Usage: $0 [access|error|health|performance|recommendations|export|full]"
                echo "   Or run without arguments for interactive menu"
                exit 1
                ;;
        esac
    fi
}

# Run main function
main "$@"