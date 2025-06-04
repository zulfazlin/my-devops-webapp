#!/bin/bash

# DevOps Learning Project - Automated Deployment Script
# This script automates the deployment of our web application to AWS EC2

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTANCE_TAG_NAME="my-webapp-server"
KEY_FILE="../scripts/my-devops-key.pem"
SSH_USER="ec2-user"
LOCAL_HTML_FILE="../src/index.html"
REMOTE_HTML_PATH="/var/www/html/"

# Function to print colored output
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

# Function to get instance IP
get_instance_ip() {
    print_status "Getting EC2 instance IP address..."
    
    INSTANCE_IP=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [ "$INSTANCE_IP" = "None" ] || [ -z "$INSTANCE_IP" ]; then
        print_error "Could not find running instance with tag Name=$INSTANCE_TAG_NAME"
        exit 1
    fi
    
    print_success "Found instance IP: $INSTANCE_IP"
    return 0
}

# Function to check if instance is reachable
check_instance_connectivity() {
    print_status "Checking SSH connectivity to instance..."
    
    # Test SSH connection
    if ssh -i "$KEY_FILE" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$INSTANCE_IP" "echo 'SSH connection successful'" > /dev/null 2>&1; then
        print_success "SSH connection successful"
    else
        print_error "Cannot connect to instance via SSH"
        print_warning "Please check:"
        echo "  - Instance is running"
        echo "  - Security group allows SSH (port 22)"
        echo "  - Key file permissions: chmod 400 $KEY_FILE"
        exit 1
    fi
}

# Function to backup current deployment
backup_current_deployment() {
    print_status "Creating backup of current deployment..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/var/www/html/backups"
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << EOF
        sudo mkdir -p $BACKUP_DIR
        if [ -f /var/www/html/index.html ]; then
            sudo cp /var/www/html/index.html $BACKUP_DIR/index.html.$TIMESTAMP
            echo "Backup created: $BACKUP_DIR/index.html.$TIMESTAMP"
        else
            echo "No existing deployment to backup"
        fi
EOF
    
    print_success "Backup completed"
}

# Function to deploy application
deploy_application() {
    print_status "Deploying application to EC2 instance..."
    
    # Check if local file exists
    if [ ! -f "$LOCAL_HTML_FILE" ]; then
        print_error "Local HTML file not found: $LOCAL_HTML_FILE"
        exit 1
    fi
    
    # Copy file to server
    print_status "Copying files to server..."
    scp -i "$KEY_FILE" "$LOCAL_HTML_FILE" "$SSH_USER@$INSTANCE_IP:/tmp/"
    
    # Move file to web directory with proper permissions
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << 'EOF'
        # Move file to web directory
        sudo mv /tmp/index.html /var/www/html/
        
        # Set proper ownership and permissions
        sudo chown apache:apache /var/www/html/index.html
        sudo chmod 644 /var/www/html/index.html
        
        # Restart Apache to ensure everything is loaded
        sudo systemctl restart httpd
        
        # Verify Apache is running
        if sudo systemctl is-active httpd > /dev/null; then
            echo "Apache is running successfully"
        else
            echo "Error: Apache failed to start"
            exit 1
        fi
EOF
    
    print_success "Application deployed successfully"
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    # Test HTTP response
    HTTP_STATUS=$(ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "curl -s -o /dev/null -w '%{http_code}' http://localhost")
    
    if [ "$HTTP_STATUS" = "200" ]; then
        print_success "HTTP test passed (Status: $HTTP_STATUS)"
    else
        print_error "HTTP test failed (Status: $HTTP_STATUS)"
        exit 1
    fi
    
    # Check if our content is served
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "curl -s http://localhost | grep -q 'DevOps Learning Journey'"
    
    if [ $? -eq 0 ]; then
        print_success "Content verification passed"
    else
        print_error "Content verification failed"
        exit 1
    fi
}

# Function to show deployment info
show_deployment_info() {
    print_success "=== DEPLOYMENT COMPLETED SUCCESSFULLY ==="
    echo ""
    echo "🌐 Your application is now live at:"
    echo "   http://$INSTANCE_IP"
    echo ""
    echo "📊 Server Information:"
    echo "   Instance IP: $INSTANCE_IP"
    echo "   SSH Access: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP"
    echo ""
    echo "🔧 Quick Commands:"
    echo "   View logs: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP 'sudo tail -f /var/log/httpd/access_log'"
    echo "   Restart Apache: ssh -i $KEY_FILE $SSH_USER@$INSTANCE_IP 'sudo systemctl restart httpd'"
    echo ""
}

# Main deployment function
main() {
    echo "================================================"
    echo "    DevOps Learning Project - Auto Deployment"
    echo "================================================"
    echo ""
    
    # Pre-flight checks
    print_status "Starting automated deployment..."
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        print_error "AWS CLI not configured. Run 'aws configure' first."
        exit 1
    fi
    
    # Check if key file exists
    if [ ! -f "$KEY_FILE" ]; then
        print_error "Key file not found: $KEY_FILE"
        print_warning "Make sure you're running this script from the scripts directory"
        exit 1
    fi
    
    # Execute deployment steps
    get_instance_ip
    check_instance_connectivity
    backup_current_deployment
    deploy_application
    verify_deployment
    show_deployment_info
    
    print_success "🚀 Deployment completed successfully!"
}

# Check if script is being run directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi