#!/bin/bash

# Rollback Script - Restore previous deployment
# This script helps you rollback to a previous version in case of issues

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
BACKUP_DIR="/var/www/html/backups"

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

# Get instance IP
get_instance_ip() {
    INSTANCE_IP=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [ "$INSTANCE_IP" = "None" ] || [ -z "$INSTANCE_IP" ]; then
        print_error "Could not find running instance"
        exit 1
    fi
}

# List available backups
list_backups() {
    print_status "Available backups:"
    echo ""
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << EOF
if [ -d "$BACKUP_DIR" ]; then
    echo "📁 Backup files in $BACKUP_DIR:"
    ls -la $BACKUP_DIR/ | grep index.html | nl -v0
    echo ""
else
    echo "❌ No backup directory found"
    exit 1
fi
EOF
}

# Perform rollback
perform_rollback() {
    local backup_file="$1"
    
    if [ -z "$backup_file" ]; then
        print_error "No backup file specified"
        exit 1
    fi
    
    print_status "Rolling back to: $backup_file"
    
    ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" << EOF
# Check if backup file exists
if [ ! -f "$BACKUP_DIR/$backup_file" ]; then
    echo "❌ Backup file not found: $BACKUP_DIR/$backup_file"
    exit 1
fi

# Create backup of current version before rollback
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
if [ -f /var/www/html/index.html ]; then
    sudo cp /var/www/html/index.html $BACKUP_DIR/index.html.pre-rollback.\$TIMESTAMP
    echo "✓ Current version backed up as: index.html.pre-rollback.\$TIMESTAMP"
fi

# Restore the backup
sudo cp $BACKUP_DIR/$backup_file /var/www/html/index.html

# Set proper permissions
sudo chown apache:apache /var/www/html/index.html
sudo chmod 644 /var/www/html/index.html

# Restart Apache
sudo systemctl restart httpd

# Verify
if sudo systemctl is-active httpd > /dev/null; then
    echo "✓ Apache restarted successfully"
    
    # Test HTTP response
    HTTP_STATUS=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
    if [ "\$HTTP_STATUS" = "200" ]; then
        echo "✓ HTTP test passed (Status: \$HTTP_STATUS)"
        echo "✅ Rollback completed successfully!"
    else
        echo "❌ HTTP test failed (Status: \$HTTP_STATUS)"
        exit 1
    fi
else
    echo "❌ Apache failed to start"
    exit 1
fi
EOF
    
    print_success "Rollback completed!"
    echo "🌐 Check your site: http://$INSTANCE_IP"
}

# Interactive backup selection
select_backup_interactive() {
    # Get backup list
    BACKUP_LIST=$(ssh -i "$KEY_FILE" "$SSH_USER@$INSTANCE_IP" "ls -t $BACKUP_DIR/index.html.* 2>/dev/null || echo ''")
    
    if [ -z "$BACKUP_LIST" ]; then
        print_error "No backups found"
        exit 1
    fi
    
    echo "Available backups (newest first):"
    echo ""
    
    # Convert to array
    IFS=$'\n' read -d '' -r -a backup_array <<< "$BACKUP_LIST" || true
    
    # Display numbered list
    for i in "${!backup_array[@]}"; do
        backup_name=$(basename "${backup_array[i]}")
        # Extract timestamp from filename
        timestamp=$(echo "$backup_name" | sed 's/index.html.//' | sed 's/\..*$//')
        echo "  [$i] $backup_name ($timestamp)"
    done
    
    echo ""
    read -p "Select backup number to restore (or 'q' to quit): " selection
    
    if [ "$selection" = "q" ]; then
        echo "Rollback cancelled"
        exit 0
    fi
    
    # Validate selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -lt "${#backup_array[@]}" ]; then
        selected_backup=$(basename "${backup_array[$selection]}")
        echo ""
        print_warning "You are about to rollback to: $selected_backup"
        read -p "Are you sure? (y/N): " confirm
        
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            perform_rollback "$selected_backup"
        else
            echo "Rollback cancelled"
        fi
    else
        print_error "Invalid selection"
        exit 1
    fi
}

# Main function
main() {
    echo "================================================"
    echo "       Deployment Rollback Tool"
    echo "================================================"
    echo ""
    
    get_instance_ip
    
    if [ $# -eq 0 ]; then
        # Interactive mode
        list_backups
        select_backup_interactive
    else
        # Command line mode
        backup_file="$1"
        perform_rollback "$backup_file"
    fi
}

# Show usage if --help
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 [backup_file]"
    echo ""
    echo "Options:"
    echo "  No arguments    - Interactive mode (shows list of backups)"
    echo "  backup_file     - Rollback to specific backup file"
    echo "  --help, -h      - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                              # Interactive mode"
    echo "  $0 index.html.20241201_143022   # Rollback to specific backup"
    exit 0
fi

main "$@"