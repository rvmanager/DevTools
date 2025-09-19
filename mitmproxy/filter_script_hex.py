#!/usr/bin/env python3
"""
Enhanced Mitmproxy script to capture all traffic with full data display.
Shows text content as-is and binary content in hex format.
Save as filter_script.py and use with: mitmdump -s filter_script.py
"""

import mitmproxy.http
from mitmproxy import ctx
import time
import binascii

# Binary MIME types that should be displayed in hex
BINARY_TYPES = {
    'image/', 'video/', 'audio/', 'application/octet-stream',
    'application/pdf', 'application/zip', 'application/gzip',
    'application/x-', 'font/', 'application/wasm', 'application/msword',
    'application/vnd.', 'application/x-protobuf', 'multipart/'
}

def format_hex_dump(data: bytes, max_bytes: int = 512) -> str:
    """Format binary data as hex dump with ASCII representation."""
    if not data:
        return "(empty)"
    
    # Limit the amount of data shown
    data_to_show = data[:max_bytes]
    truncated = len(data) > max_bytes
    
    lines = []
    for i in range(0, len(data_to_show), 16):
        chunk = data_to_show[i:i+16]
        
        # Hex representation
        hex_part = ' '.join(f'{b:02x}' for b in chunk)
        hex_part = hex_part.ljust(47)  # 16 bytes * 2 chars + 15 spaces
        
        # ASCII representation
        ascii_part = ''.join(chr(b) if 32 <= b <= 126 else '.' for b in chunk)
        
        # Offset
        offset = f'{i:08x}'
        
        lines.append(f'{offset}: {hex_part} |{ascii_part}|')
    
    result = '\n'.join(lines)
    if truncated:
        result += f'\n... (showing first {max_bytes} bytes of {len(data)} total)'
    
    return result

def is_binary_content(content_type: str, data: bytes) -> bool:
    """Determine if content should be treated as binary."""
    if any(content_type.lower().startswith(bt) for bt in BINARY_TYPES):
        return True
    
    # Also check if data contains non-printable bytes (heuristic)
    if data and len(data) > 0:
        try:
            # Try to decode as UTF-8, if it fails or contains many control chars, treat as binary
            decoded = data.decode('utf-8', errors='strict')
            control_chars = sum(1 for c in decoded if ord(c) < 32 and c not in '\t\n\r')
            return control_chars > len(decoded) * 0.1  # More than 10% control chars
        except UnicodeDecodeError:
            return True
    
    return False

def log_headers(headers: dict, prefix: str) -> None:
    """Log HTTP headers."""
    if headers:
        ctx.log.info(f"    {prefix} Headers:")
        for name, value in headers.items():
            ctx.log.info(f"      {name}: {value}")

def log_data(data: bytes, content_type: str, prefix: str, max_text_bytes: int = 2048) -> None:
    """Log request/response data, with hex for binary and text for text content."""
    if not data:
        ctx.log.info(f"    {prefix} Body: (empty)")
        return
    
    ctx.log.info(f"    {prefix} Body ({len(data)} bytes):")
    
    if is_binary_content(content_type, data):
        # Binary content - show hex dump
        hex_dump = format_hex_dump(data)
        ctx.log.info(f"      [HEX DUMP]")
        for line in hex_dump.split('\n'):
            ctx.log.info(f"      {line}")
    else:
        # Text content - show as text
        try:
            # Limit text display for very large responses
            data_to_show = data[:max_text_bytes]
            text = data_to_show.decode('utf-8', errors='replace')
            truncated = len(data) > max_text_bytes
            
            ctx.log.info(f"      [TEXT CONTENT]")
            for line in text.split('\n'):
                ctx.log.info(f"      {line}")
            
            if truncated:
                ctx.log.info(f"      ... (showing first {max_text_bytes} bytes of {len(data)} total)")
                
        except Exception as e:
            # Fallback to hex if text decoding fails
            ctx.log.info(f"      [TEXT DECODE ERROR: {e}, showing as hex]")
            hex_dump = format_hex_dump(data)
            for line in hex_dump.split('\n'):
                ctx.log.info(f"      {line}")

def request(flow: mitmproxy.http.HTTPFlow) -> None:
    """Called when a client request has been made."""
    
    timestamp = time.strftime("%H:%M:%S", time.localtime())
    method = flow.request.method
    url = flow.request.pretty_url
    content_type = flow.request.headers.get("content-type", "")
    content_length = len(flow.request.content) if flow.request.content else 0
    
    ctx.log.info(f"\n{'='*80}")
    ctx.log.info(f"[{timestamp}] REQUEST: {method} {url}")
    ctx.log.info(f"    Content-Type: {content_type or 'none'}")
    ctx.log.info(f"    Content-Length: {content_length}")
    
    # Log request headers
    log_headers(dict(flow.request.headers), "Request")
    
    # Log request body if present
    if flow.request.content:
        log_data(flow.request.content, content_type, "Request")
    else:
        ctx.log.info(f"    Request Body: (none)")

def response(flow: mitmproxy.http.HTTPFlow) -> None:
    """Called when a server response has been received."""
    
    timestamp = time.strftime("%H:%M:%S", time.localtime())
    status = flow.response.status_code
    content_type = flow.response.headers.get("content-type", "")
    content_length = len(flow.response.content) if flow.response.content else 0
    
    ctx.log.info(f"[{timestamp}] RESPONSE: {status} {flow.response.reason}")
    ctx.log.info(f"    Content-Type: {content_type or 'none'}")
    ctx.log.info(f"    Content-Length: {content_length}")
    
    # Log response headers
    log_headers(dict(flow.response.headers), "Response")
    
    # Log response body if present
    if flow.response.content:
        log_data(flow.response.content, content_type, "Response")
    else:
        ctx.log.info(f"    Response Body: (none)")
    
    ctx.log.info(f"{'='*80}")

def error(flow: mitmproxy.http.HTTPFlow) -> None:
    """Called when an error occurs."""
    timestamp = time.strftime("%H:%M:%S", time.localtime())
    ctx.log.error(f"[{timestamp}] ERROR: {flow.error}")
