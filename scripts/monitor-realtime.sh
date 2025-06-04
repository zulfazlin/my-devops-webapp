#!/bin/bash

# Real-time Monitoring Dashboard
# Provides live monitoring of your web application

# Colors for dashboard
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configuration
INSTANCE_TAG_NAME="my-webapp-server"
KEY_FILE="my-devops-key.pem"
SSH_USER="ec2-user"
REFRESH_INTERVAL=5

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

# Clear screen and show header
show_header() {
    clear
    echo -e "${WHITE}================================================================${NC}"
    echo -e "${WHITE}           DevOps Learning - Real-time Monitor${NC}"
    echo -e "${WHITE}================================================================${NC}"
    echo -e "${CYAN}Instance: ${INSTANCE_IP}${NC} | ${CYAN}Updated: $(date)${NC} | ${CYAN}Refresh: ${REFRESH_INTERVAL}s${NC}"
    echo -e "${WHITE}================================================================${NC}"
    echo ""
}

# Get system metrics
get_system_metrics() {
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        # System metrics in one go for efficiency
        echo "METRICS_START"
        
        # CPU usage
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
        echo "CPU:$cpu_usage"
        
        # Memory usage
        mem_info=$(free | awk 'FNR==2{printf "%.1f:%.1f", $3/1024/1024, ($3+$4)/1024/1024}')
        echo "MEM:$mem_info"
        
        # Disk usage
        disk_usage=$(df / | tail -1 | awk '{print $5":"$4}')
        echo "DISK:$disk_usage"
        
        # Load average
        load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
        echo "LOAD:$load_avg"
        
        # Apache status
        if systemctl is-active httpd > /dev/null 2>&1; then
            apache_status="RUNNING"
            apache_processes=$(ps aux | grep httpd | grep -v grep | wc -l)
        else
            apache_status="STOPPED"
            apache_processes="0"
        fi
        echo "APACHE:$apache_status:$apache_processes"
        
        # HTTP response
        http_response=$(curl -s -o /dev/null -w '%{http_code}:%{time_total}' http://localhost)
        echo "HTTP:$http_response"
        
        # Recent connections
        connections=$(ss -tun | grep :80 | wc -l)
        echo "CONN:$connections"
        
        # Recent access log entries (last 10 minutes)
        recent_hits=$(awk -v d=$(date -d '10 minutes ago' +'%d/%b/%Y:%H:%M') '$4 >= "["d {count++} END {print count+0}' /var/log/httpd/access_log 2>/dev/null)
        echo "HITS:$recent_hits"
        
        # Error count (last hour)
        error_count=$(grep "$(date +'%a %b %d %H')" /var/log/httpd/error_log 2>/dev/null | wc -l)
        echo "ERRORS:$error_count"
        
        echo "METRICS_END"
EOF
}

# Parse and display metrics
display_metrics() {
    local metrics_data="$1"
    
    # Parse metrics
    cpu_usage=$(echo "$metrics_data" | grep "CPU:" | cut -d: -f2)
    mem_info=$(echo "$metrics_data" | grep "MEM:" | cut -d: -f2)
    disk_info=$(echo "$metrics_data" | grep "DISK:" | cut -d: -f2)
    load_avg=$(echo "$metrics_data" | grep "LOAD:" | cut -d: -f2)
    apache_info=$(echo "$metrics_data" | grep "APACHE:" | cut -d: -f2-)
    http_info=$(echo "$metrics_data" | grep "HTTP:" | cut -d: -f2)
    connections=$(echo "$metrics_data" | grep "CONN:" | cut -d: -f2)
    recent_hits=$(echo "$metrics_data" | grep "HITS:" | cut -d: -f2)
    error_count=$(echo "$metrics_data" | grep "ERRORS:" | cut -d: -f2)
    
    # Parse individual values
    mem_used=$(echo "$mem_info" | cut -d: -f1)
    mem_total=$(echo "$mem_info" | cut -d: -f2)
    disk_percent=$(echo "$disk_info" | cut -d: -f1 | sed 's/%//')
    disk_available=$(echo "$disk_info" | cut -d: -f2)
    apache_status=$(echo "$apache_info" | cut -d: -f1)
    apache_processes=$(echo "$apache_info" | cut -d: -f2)
    http_code=$(echo "$http_info" | cut -d: -f1)
    response_time=$(echo "$http_info" | cut -d: -f2)
    
    # Display System Status
    echo -e "${BLUE}🖥️  SYSTEM STATUS${NC}"
    echo -e "${WHITE}─────────────────${NC}"
    
    # CPU with color coding
    cpu_num=$(echo "$cpu_usage" | sed 's/[^0-9.]//g')
    if (( $(echo "$cpu_num > 80" | bc -l 2>/dev/null || echo 0) )); then
        cpu_color=$RED
    elif (( $(echo "$cpu_num > 60" | bc -l 2>/dev/null || echo 0) )); then
        cpu_color=$YELLOW
    else
        cpu_color=$GREEN
    fi
    echo -e "CPU Usage:    ${cpu_color}${cpu_usage}${NC}"
    
    # Memory with color coding
    if (( $(echo "$mem_used > $mem_total * 0.8" | bc -l 2>/dev/null || echo 0) )); then
        mem_color=$RED
    elif (( $(echo "$mem_used > $mem_total * 0.6" | bc -l 2>/dev/null || echo 0) )); then
        mem_color=$YELLOW
    else
        mem_color=$GREEN
    fi
    echo -e "Memory:       ${mem_color}${mem_used}GB / ${mem_total}GB${NC}"
    
    # Disk with color coding
    if [ "$disk_percent" -gt 80 ]; then
        disk_color=$RED
    elif [ "$disk_percent" -gt 60 ]; then
        disk_color=$YELLOW
    else
        disk_color=$GREEN
    fi
    echo -e "Disk Usage:   ${disk_color}${disk_percent}%${NC} (${disk_available} available)"
    echo -e "Load Average: ${CYAN}${load_avg}${NC}"
    
    echo ""
    
    # Web Server Status
    echo -e "${BLUE}🌐 WEB SERVER STATUS${NC}"
    echo -e "${WHITE}────────────────────${NC}"
    
    # Apache status
    if [ "$apache_status" = "RUNNING" ]; then
        apache_color=$GREEN
        status_icon="✅"
    else
        apache_color=$RED
        status_icon="❌"
    fi
    echo -e "Apache:       ${apache_color}${status_icon} ${apache_status}${NC} (${apache_processes} processes)"
    
    # HTTP response
    if [ "$http_code" = "200" ]; then
        http_color=$GREEN
        http_icon="✅"
    else
        http_color=$RED
        http_icon="❌"
    fi
    echo -e "HTTP Status:  ${http_color}${http_icon} ${http_code}${NC} (${response_time}s response)"
    echo -e "Connections:  ${CYAN}${connections}${NC} active"
    
    echo ""
    
    # Traffic & Errors
    echo -e "${BLUE}📊 TRAFFIC & ERRORS${NC}"
    echo -e "${WHITE}───────────────────${NC}"
    echo -e "Recent Hits:  ${CYAN}${recent_hits}${NC} (last 10 min)"
    
    if [ "$error_count" -gt 0 ]; then
        error_color=$YELLOW
        error_icon="⚠️"
    else
        error_color=$GREEN
        error_icon="✅"
    fi
    echo -e "Errors:       ${error_color}${error_icon} ${error_count}${NC} (last hour)"
}

# Display recent activity
display_activity() {
    echo ""
    echo -e "${BLUE}📝 RECENT ACTIVITY${NC}"
    echo -e "${WHITE}──────────────────${NC}"
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        echo "Last 5 access log entries:"
        if [ -f /var/log/httpd/access_log ]; then
            tail -5 /var/log/httpd/access_log | while read line; do
                echo "  $line"
            done
        else
            echo "  No access log available"
        fi
        
        echo ""
        echo "Last 3 health check results:"
        if [ -f /var/log/webapp-health.log ]; then
            tail -3 /var/log/webapp-health.log | while read line; do
                echo "  $line"
            done
        else
            echo "  No health log available"
        fi
EOF
}

# Display controls
display_controls() {
    echo ""
    echo -e "${WHITE}================================================================${NC}"
    echo -e "${YELLOW}Controls: [R] Refresh Now | [Q] Quit | [L] View Logs | [H] Health Check${NC}"
    echo -e "${WHITE}================================================================${NC}"
}

# Manual health check
run_health_check() {
    echo -e "\n${BLUE}Running manual health check...${NC}"
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" '/usr/local/bin/health-check.sh 2>/dev/null || echo "Health check script not found"'
    echo -e "${GREEN}Health check completed${NC}"
    sleep 2
}

# View recent logs
view_logs() {
    clear
    echo -e "${WHITE}================================================================${NC}"
    echo -e "${WHITE}                    RECENT LOGS${NC}"
    echo -e "${WHITE}================================================================${NC}"
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        echo "=== LAST 20 ACCESS LOG ENTRIES ==="
        tail -20 /var/log/httpd/access_log 2>/dev/null || echo "Access log not available"
        
        echo ""
        echo "=== LAST 10 ERROR LOG ENTRIES ==="
        tail -10 /var/log/httpd/error_log 2>/dev/null || echo "Error log not available"
        
        echo ""
        echo "=== HEALTH CHECK LOG ==="
        tail -10 /var/log/webapp-health.log 2>/dev/null || echo "Health log not available"
EOF
    
    echo ""
    read -p "Press Enter to return to dashboard..."
}

# Main monitoring loop
main_loop() {
    while true; do
        # Get and display metrics
        metrics_data=$(get_system_metrics)
        
        show_header
        display_metrics "$metrics_data"
        display_activity
        display_controls
        
        # Check for user input with timeout
        read -t $REFRESH_INTERVAL -n 1 input
        case $input in
            [Qq]) 
                clear
                echo "Monitoring stopped. Goodbye!"
                exit 0
                ;;
            [Rr])
                continue
                ;;
            [Ll])
                view_logs
                ;;
            [Hh])
                run_health_check
                ;;
        esac
    done
}

# Signal handler for clean exit
cleanup() {
    clear
    echo "Monitoring stopped."
    exit 0
}

# Main function
main() {
    # Set up signal handlers
    trap cleanup SIGINT SIGTERM
    
    echo "Starting real-time monitoring..."
    echo "Getting instance information..."
    
    get_instance_ip
    
    # Test connectivity
    if ! ssh -i "$KEY_FILE" -o ConnectTimeout=5 "$SSH_USER@$INSTANCE_IP" "echo 'Connection test'" > /dev/null 2>&1; then
        echo "❌ Cannot connect to instance. Please check:"
        echo "   - Instance is running"
        echo "   - SSH key is correct"
        echo "   - Security group allows SSH"
        exit 1
    fi
    
    echo "✅ Connected to $INSTANCE_IP"
    echo "Starting dashboard in 3 seconds..."
    sleep 3
    
    main_loop
}

# Show help
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "DevOps Real-time Monitoring Dashboard"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help, -h     Show this help"
    echo "  --interval N   Set refresh interval (default: 5 seconds)"
    echo ""
    echo "Dashboard Controls:"
    echo "  R - Refresh now"
    echo "  Q - Quit"
    echo "  L - View recent logs"
    echo "  H - Run manual health check"
    echo ""
    echo "The dashboard automatically refreshes every $REFRESH_INTERVAL seconds"
    exit 0
fi

# Check for interval option
if [ "$1" = "--interval" ] && [ ! -z "$2" ]; then
    REFRESH_INTERVAL=$2
fi

# Run main function
main "$@"