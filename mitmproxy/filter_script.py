#!/usr/bin/env python3
"""
Mitmproxy script to capture all traffic with MIME type indicators
but filter out binary content display for images/videos/etc.
Save as filter_script.py and use with: mitmdump -s filter_script.py
"""

import mitmproxy.http
from mitmproxy import ctx
import time

# Binary MIME types to filter display for
BINARY_TYPES = {
    'image/', 'video/', 'audio/', 'application/octet-stream',
    'application/pdf', 'application/zip', 'application/gzip',
    'application/x-', 'font/', 'application/wasm', 'application/msword'
}

def response(flow: mitmproxy.http.HTTPFlow) -> None:
    """Called when a server response has been received."""
    
    # Get content info
    content_type = flow.response.headers.get("content-type", "unknown")
    content_length = flow.response.headers.get("content-length", "unknown")
    
    # Check if it's binary content
    is_binary = any(content_type.lower().startswith(bt) for bt in BINARY_TYPES)
    
    # Get timing and size info
    method = flow.request.method
    url = flow.request.pretty_url
    status = flow.response.status_code
    timestamp = time.strftime("%H:%M:%S", time.localtime())
    
    # Create summary line
    if is_binary:
        ctx.log.info(f"[{timestamp}] [BINARY] {method} {url}")
        ctx.log.info(f"    └─ Response: {status} | Type: {content_type} | Size: {content_length}")
    else:
        ctx.log.info(f"[{timestamp}] [TEXT] {method} {url}")
        ctx.log.info(f"    └─ Response: {status} | Type: {content_type} | Size: {content_length}")
        
        # Show preview of text content if small
        if hasattr(flow.response, 'text') and len(flow.response.content) < 1000:
            preview = (flow.response.text or "")[:100].replace('\n', ' ')
            if preview:
                ctx.log.info(f"    └─ Preview: {preview}...")

def request(flow: mitmproxy.http.HTTPFlow) -> None:
    """Called when a client request has been made."""
    
    content_type = flow.request.headers.get("content-type", "")
    content_length = flow.request.headers.get("content-length", "0")
    timestamp = time.strftime("%H:%M:%S", time.localtime())
    
    # Log uploads with size > 0
    if content_type and int(content_length or 0) > 0:
        is_binary_upload = any(content_type.lower().startswith(bt) for bt in BINARY_TYPES)
        upload_type = "BINARY UPLOAD" if is_binary_upload else "TEXT UPLOAD"
        
        ctx.log.info(f"[{timestamp}] [{upload_type}] {flow.request.method} {flow.request.pretty_url}")
        ctx.log.info(f"    └─ Upload Type: {content_type} | Size: {content_length}")
