#!/bin/bash

set -e

echo "======================================"
echo "       PANEL ONE-CLICK INSTALLER"
echo "======================================"

# Update packages
apt update -y

# Install Git
apt install -y git

# Clone Panel repository
cd /root
rm -rf Panel
git clone https://github.com/notroboy67-htp/Panel.git

cd /root/Panel

# Install Node.js and npm
apt install -y nodejs npm

# Install unzip
apt install -y unzip

# Extract panel ZIP
if [ -f "mcpanelv1.zip" ]; then
    unzip -o mcpanelv1.zip
else
    echo "ERROR: mcpanelv1.zip not found!"
    exit 1
fi

# Enter panel directory
cd panel

# Install dependencies
npm install
npm i

echo ""
echo "======================================"
echo "       INSTALLATION COMPLETE"
echo "======================================"
echo ""
echo "Starting Panel..."
echo ""

# Start panel
node .
