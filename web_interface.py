#!/usr/bin/env python3
"""Ricoh SP 200 & CUPS Print Management Console.

Professional, enterprise-grade network print portal and CUPS administration.
"""

import os
import io
import time
import json
import re
import socket
import subprocess
import cups
from datetime import datetime
from flask import Flask, render_template_string, request, redirect, url_for, flash, Response
import qrcode
import qrcode.image.svg

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "ricoh-cups-mgmt-2026")

CUPS_HOST = os.getenv("RICOH_CUPS_HOST", "localhost")
DEFAULT_PRINTER = os.getenv("RICOH_PRINTER", "Ricoh_SP_200_DDST")
HISTORY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".job_history.json")

try:
    LOCAL_COMPUTER_NAME = subprocess.check_output(["scutil", "--get", "ComputerName"]).decode("utf-8").strip()
except Exception:
    LOCAL_COMPUTER_NAME = socket.gethostname()

JOB_STATES = {
    3: ("Pending", "badge-pending"),
    4: ("Held", "badge-neutral"),
    5: ("Processing", "badge-active"),
    6: ("Stopped", "badge-danger"),
    7: ("Canceled", "badge-neutral"),
    8: ("Aborted", "badge-danger"),
    9: ("Completed", "badge-success")
}

PRINTER_STATES = {
    3: ("Ready", "badge-success"),
    4: ("Processing", "badge-active"),
    5: ("Paused", "badge-danger")
}

SCALING_MODES = {
    "fit": "Fit to Page (Proportional Resize)",
    "none": "Actual Size (100% Scale)",
    "fill": "Fill Entire Sheet (Edge-to-Edge)",
    "auto-fit": "Shrink Oversized Only"
}

def load_job_history():
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_job_history(job_id, info):
    history = load_job_history()
    history[str(job_id)] = info
    try:
        with open(HISTORY_FILE, "w") as f:
            json.dump(history, f, indent=2)
    except Exception as e:
        app.logger.error(f"Error saving job history: {e}")

def get_cups_connection():
    try:
        return cups.Connection(host=CUPS_HOST)
    except Exception as e:
        app.logger.error(f"Failed to connect to CUPS server: {e}")
        return None

def check_system_statuses():
    conn = get_cups_connection()
    if not conn:
        return False, "Daemon Offline", False, "Offline"
    
    server_on = True
    server_msg = "Scheduler Active"
    
    try:
        printers = conn.getPrinters()
        p = printers.get(DEFAULT_PRINTER, {})
        reasons = p.get('printer-state-reasons', [])
        if isinstance(reasons, str):
            reasons = [reasons]
            
        is_offline = any(r in ('offline-report', 'connecting-to-device', 'offline', 'media-empty-warning') for r in reasons)
        
        try:
            res = subprocess.run(["ioreg", "-p", "IOUSB", "-l"], capture_output=True, text=True, timeout=2)
            usb_present = "ricoh" in res.stdout.lower() or "sp 200" in res.stdout.lower()
        except Exception:
            usb_present = not is_offline
            
        if usb_present and not is_offline:
            printer_on = True
            printer_msg = "Ready (USB Connected)"
        else:
            printer_on = False
            printer_msg = "Standby / Powered Off"
    except Exception as e:
        printer_on = False
        printer_msg = f"Error: {e}"
        
    return server_on, server_msg, printer_on, printer_msg

def clean_doc_title(title):
    if not title:
        return None
    title = str(title).strip()
    if title.lower() in ('none', 'untitled', '', '(null)'):
        return None
    title = re.sub(r'^ricoh_print_\d+_', '', title)
    return title

def get_network_client_ip(time_creation, size_kb):
    """Parses /var/log/cups/access_log to extract real remote client IP for network jobs."""
    server_ip = get_lan_ip()
    try:
        if os.path.exists("/var/log/cups/access_log"):
            with open("/var/log/cups/access_log", "r") as f:
                lines = f.readlines()
            for line in reversed(lines):
                if any(action in line for action in ['Print-Job', 'Create-Job', 'Send-Document']):
                    parts = line.split()
                    if parts:
                        ip = parts[0]
                        if ip not in ('localhost', '127.0.0.1', '::1', server_ip):
                            return ip
    except Exception:
        pass
    return None

def resolve_job_title(job_id, attrs):
    # 1. Check persistent history store from web uploads
    history = load_job_history()
    if str(job_id) in history:
        stored_title = history[str(job_id)].get("title")
        if stored_title:
            return stored_title

    # 2. Check metadata keys populated by applications (macOS, Windows, Chrome)
    for key in [
        'document-name-supplied',
        'com.apple.print.JobInfo.PMJobName',
        'job-name',
        'job-originating-file-name',
        'document-name'
    ]:
        val = clean_doc_title(attrs.get(key))
        if val and not val.startswith("Job #") and not val.startswith("smbprn."):
            return val

    # 3. Intelligent fallback title from format, pages, and size
    fmt = attrs.get('document-format', '') or attrs.get('document-format-supplied', '')
    pages = attrs.get('job-impressions-completed', attrs.get('job-media-sheets-completed', 0)) or attrs.get('job-impressions', 0)
    size_kb = int(attrs.get('job-k-octets', 0))

    fmt_label = "PDF Document" if "pdf" in fmt.lower() else ("PostScript File" if "postscript" in fmt.lower() else "Document")
    if pages > 0 and size_kb > 0:
        return f"{fmt_label} ({pages} {'page' if pages == 1 else 'pages'}, {size_kb} KB)"
    elif size_kb > 0:
        return f"{fmt_label} ({size_kb} KB)"
    return f"{fmt_label} #{job_id}"

def resolve_job_source(job_id, attrs):
    # 1. Check persistent history
    history = load_job_history()
    if str(job_id) in history and history[str(job_id)].get("source"):
        return history[str(job_id)]["source"]

    # 2. Check application info (macOS / Desktop print dialogs)
    app_name = attrs.get('com.apple.print.JobInfo.PMApplicationName')
    if app_name:
        app_name = app_name.replace(" Helper", "").replace(" (Renderer)", "").strip()
    owner = attrs.get('com.apple.print.JobInfo.PMJobOwner') or attrs.get('job-originating-user-name')
    if not owner or str(owner).lower() in ('none', 'anonymous', ''):
        owner = "client"

    if app_name:
        return f"{owner} ({app_name} @ {LOCAL_COMPUTER_NAME})"

    # 3. Check for remote network client (e.g. Android phone or remote PC)
    client_ip = get_network_client_ip(attrs.get('time-at-creation'), int(attrs.get('job-k-octets', 0)))
    if client_ip:
        return f"Android / Mobile ({client_ip})"

    # 4. Hostname from CUPS job attributes
    host = attrs.get('job-originating-host-name')
    if host and host not in ('localhost', '127.0.0.1', get_lan_ip()):
        return f"{owner} @ {host}"

    if owner and owner != 'client':
        return f"{owner} @ {LOCAL_COMPUTER_NAME}"

    return f"Local System ({LOCAL_COMPUTER_NAME})"

def get_lan_ip():
    override = os.getenv("RICOH_SERVER_IP")
    if override:
        return override
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

def fetch_all_printers():
    conn = get_cups_connection()
    if not conn:
        return {}
    try:
        return conn.getPrinters()
    except Exception as e:
        app.logger.error(f"Error fetching printers: {e}")
        return {}

def fetch_jobs(which='all'):
    conn = get_cups_connection()
    if not conn:
        return []
    try:
        jobs_dict = conn.getJobs(which_jobs=which)
        jobs_list = []
        for job_id in sorted(jobs_dict.keys(), reverse=True):
            try:
                attrs = conn.getJobAttributes(job_id)
                state_code = attrs.get('job-state', 0)
                state_name, badge_class = JOB_STATES.get(state_code, (f"State {state_code}", "badge-neutral"))
                
                time_creation = attrs.get('time-at-creation')
                created_str = datetime.fromtimestamp(time_creation).strftime('%Y-%m-%d %H:%M:%S') if time_creation else "—"
                
                size_kb = int(attrs.get('job-k-octets', 0))
                doc_format = attrs.get('document-format', attrs.get('document-format-detected', 'Unknown'))
                doc_title = resolve_job_title(job_id, attrs)
                doc_source = resolve_job_source(job_id, attrs)
                
                jobs_list.append({
                    "id": job_id,
                    "title": doc_title,
                    "source": doc_source,
                    "state_code": state_code,
                    "state_name": state_name,
                    "badge_class": badge_class,
                    "size_kb": size_kb,
                    "created_at": created_str,
                    "printer": attrs.get('job-printer-uri', '').split('/')[-1] or DEFAULT_PRINTER,
                    "format": doc_format
                })
            except Exception:
                jobs_list.append({
                    "id": job_id,
                    "title": f"Document #{job_id}",
                    "source": "network-client",
                    "state_code": 0,
                    "state_name": "Unknown",
                    "badge_class": "badge-neutral",
                    "size_kb": 0,
                    "created_at": "—",
                    "printer": DEFAULT_PRINTER,
                    "format": "Unknown"
                })
        return jobs_list
    except Exception as e:
        app.logger.error(f"Error fetching jobs: {e}")
        return []

HTML_LAYOUT = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{ page_title }} - Ricoh Print Management</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-main: #0b0f17;
      --bg-surface: #121824;
      --bg-surface-raised: #182232;
      --bg-subtle: #1e293b;
      --border-color: #243144;
      --border-focus: #3b82f6;
      --text-primary: #f8fafc;
      --text-secondary: #94a3b8;
      --text-muted: #64748b;
      --accent-blue: #2563eb;
      --accent-blue-hover: #1d4ed8;
      --status-success: #10b981;
      --status-success-bg: rgba(16, 185, 129, 0.12);
      --status-danger: #ef4444;
      --status-danger-bg: rgba(239, 68, 68, 0.12);
      --status-warning: #f59e0b;
      --status-warning-bg: rgba(245, 158, 11, 0.12);
      --status-neutral: #64748b;
      --status-neutral-bg: rgba(100, 116, 139, 0.12);
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }

    body {
      background-color: var(--bg-main);
      color: var(--text-primary);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      font-size: 14px;
      line-height: 1.5;
    }

    header {
      background-color: var(--bg-surface);
      border-bottom: 1px solid var(--border-color);
      position: sticky;
      top: 0;
      z-index: 50;
    }

    .header-inner {
      max-width: 1200px;
      margin: 0 auto;
      padding: 0.75rem 1.5rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 1rem;
    }

    .brand-group {
      display: flex;
      align-items: center;
      gap: 1.25rem;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 0.6rem;
      color: var(--text-primary);
      text-decoration: none;
      font-weight: 700;
      font-size: 1rem;
      letter-spacing: -0.01em;
    }

    .brand-badge {
      background-color: var(--bg-subtle);
      border: 1px solid var(--border-color);
      color: var(--text-secondary);
      font-size: 0.75rem;
      font-weight: 600;
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      font-family: 'JetBrains Mono', monospace;
    }

    .status-indicators {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .status-tag {
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.25rem 0.6rem;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: 600;
      border: 1px solid transparent;
      font-family: 'JetBrains Mono', monospace;
    }

    .status-tag-online {
      background: var(--status-success-bg);
      border-color: rgba(16, 185, 129, 0.3);
      color: var(--status-success);
    }

    .status-tag-offline {
      background: var(--status-danger-bg);
      border-color: rgba(239, 68, 68, 0.3);
      color: var(--status-danger);
    }

    .indicator-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background-color: currentColor;
    }

    nav {
      display: flex;
      align-items: center;
      gap: 0.25rem;
    }

    .nav-btn {
      padding: 0.4rem 0.75rem;
      color: var(--text-secondary);
      text-decoration: none;
      font-weight: 500;
      font-size: 0.85rem;
      border-radius: 6px;
      transition: color 0.15s, background-color 0.15s;
    }

    .nav-btn:hover {
      color: var(--text-primary);
      background-color: var(--bg-surface-raised);
    }

    .nav-btn.active {
      color: #ffffff;
      background-color: var(--bg-subtle);
      border: 1px solid var(--border-color);
    }

    main {
      flex: 1;
      max-width: 1200px;
      width: 100%;
      margin: 0 auto;
      padding: 1.75rem 1.5rem;
    }

    .page-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 1.5rem;
      flex-wrap: wrap;
      gap: 1rem;
    }

    .page-title h1 {
      font-size: 1.35rem;
      font-weight: 700;
      letter-spacing: -0.02em;
    }

    .page-title p {
      color: var(--text-secondary);
      font-size: 0.85rem;
      margin-top: 0.15rem;
    }

    .metrics-row {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 1rem;
      margin-bottom: 1.5rem;
    }

    .metric-card {
      background-color: var(--bg-surface);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      padding: 1rem 1.25rem;
    }

    .metric-label {
      color: var(--text-secondary);
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .metric-value {
      font-size: 1.25rem;
      font-weight: 700;
      margin-top: 0.35rem;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .metric-subtext {
      color: var(--text-muted);
      font-size: 0.75rem;
      margin-top: 0.25rem;
    }

    .panel {
      background-color: var(--bg-surface);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      margin-bottom: 1.5rem;
      overflow: hidden;
    }

    .panel-header {
      padding: 0.85rem 1.25rem;
      border-bottom: 1px solid var(--border-color);
      display: flex;
      justify-content: space-between;
      align-items: center;
      background-color: var(--bg-surface-raised);
    }

    .panel-header h2 {
      font-size: 0.95rem;
      font-weight: 600;
    }

    .panel-body {
      padding: 1.25rem;
    }

    .table-container {
      overflow-x: auto;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      text-align: left;
      font-size: 0.85rem;
    }

    th {
      background-color: var(--bg-surface-raised);
      color: var(--text-secondary);
      padding: 0.65rem 1rem;
      font-weight: 600;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      border-bottom: 1px solid var(--border-color);
    }

    td {
      padding: 0.8rem 1rem;
      border-bottom: 1px solid var(--border-color);
      color: var(--text-primary);
      vertical-align: middle;
    }

    tr:last-child td {
      border-bottom: none;
    }

    tr:hover td {
      background-color: rgba(255, 255, 255, 0.02);
    }

    .mono {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.8rem;
    }

    .doc-title {
      font-weight: 600;
      color: #ffffff;
      word-break: break-word;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 0.35rem;
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      font-size: 0.72rem;
      font-weight: 600;
      font-family: 'JetBrains Mono', monospace;
      border: 1px solid transparent;
    }

    .badge-success {
      background: var(--status-success-bg);
      color: var(--status-success);
      border-color: rgba(16, 185, 129, 0.3);
    }

    .badge-danger {
      background: var(--status-danger-bg);
      color: var(--status-danger);
      border-color: rgba(239, 68, 68, 0.3);
    }

    .badge-active {
      background: rgba(37, 99, 235, 0.15);
      color: #60a5fa;
      border-color: rgba(37, 99, 235, 0.3);
    }

    .badge-pending {
      background: var(--status-warning-bg);
      color: var(--status-warning);
      border-color: rgba(245, 158, 11, 0.3);
    }

    .badge-neutral {
      background: var(--status-neutral-bg);
      color: #94a3b8;
      border-color: rgba(100, 116, 139, 0.3);
    }

    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 0.4rem;
      padding: 0.45rem 0.9rem;
      font-size: 0.82rem;
      font-weight: 500;
      border-radius: 6px;
      cursor: pointer;
      text-decoration: none;
      border: 1px solid transparent;
      transition: background-color 0.15s, border-color 0.15s;
    }

    .btn-sm {
      padding: 0.25rem 0.55rem;
      font-size: 0.75rem;
    }

    .btn-primary {
      background-color: var(--accent-blue);
      color: #ffffff;
      border-color: var(--accent-blue);
    }

    .btn-primary:hover {
      background-color: var(--accent-blue-hover);
      border-color: var(--accent-blue-hover);
    }

    .btn-secondary {
      background-color: var(--bg-surface-raised);
      color: var(--text-primary);
      border-color: var(--border-color);
    }

    .btn-secondary:hover {
      background-color: var(--bg-subtle);
      border-color: var(--text-muted);
    }

    .btn-danger {
      background-color: var(--status-danger-bg);
      color: var(--status-danger);
      border-color: rgba(239, 68, 68, 0.3);
    }

    .btn-danger:hover {
      background-color: var(--status-danger);
      color: #ffffff;
    }

    .btn-group {
      display: flex;
      gap: 0.4rem;
    }

    .form-group {
      margin-bottom: 1.25rem;
    }

    .form-label {
      display: block;
      margin-bottom: 0.35rem;
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .form-control, .form-select {
      width: 100%;
      padding: 0.55rem 0.75rem;
      background-color: var(--bg-main);
      border: 1px solid var(--border-color);
      border-radius: 6px;
      color: var(--text-primary);
      font-size: 0.85rem;
      transition: border-color 0.15s;
    }

    .form-control:focus, .form-select:focus {
      outline: none;
      border-color: var(--border-focus);
    }

    .form-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 1rem;
    }

    .file-dropzone {
      border: 2px dashed var(--border-color);
      border-radius: 8px;
      padding: 2rem 1.5rem;
      text-align: center;
      background-color: var(--bg-main);
      position: relative;
      cursor: pointer;
      transition: border-color 0.15s;
    }

    .file-dropzone:hover {
      border-color: var(--border-focus);
    }

    .file-dropzone input[type=file] {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      opacity: 0;
      cursor: pointer;
    }

    .network-banner {
      background-color: var(--bg-surface);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      padding: 1.25rem;
      margin-bottom: 1.5rem;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 1.25rem;
    }

    .qr-box {
      width: 72px;
      height: 72px;
      background-color: #ffffff;
      padding: 4px;
      border-radius: 6px;
    }

    .alerts-wrapper {
      margin-bottom: 1.25rem;
    }

    .alert {
      padding: 0.75rem 1rem;
      border-radius: 6px;
      margin-bottom: 0.5rem;
      font-size: 0.82rem;
      border: 1px solid transparent;
    }

    .alert-success {
      background-color: var(--status-success-bg);
      border-color: rgba(16, 185, 129, 0.3);
      color: var(--status-success);
    }

    .alert-danger {
      background-color: var(--status-danger-bg);
      border-color: rgba(239, 68, 68, 0.3);
      color: var(--status-danger);
    }

    .alert-info {
      background-color: rgba(37, 99, 235, 0.12);
      border-color: rgba(37, 99, 235, 0.3);
      color: #60a5fa;
    }

    footer {
      background-color: var(--bg-surface);
      border-top: 1px solid var(--border-color);
      padding: 1rem 1.5rem;
      color: var(--text-muted);
      font-size: 0.75rem;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 0.5rem;
    }

    .empty-message {
      padding: 2.5rem;
      text-align: center;
      color: var(--text-muted);
    }
  </style>
</head>
<body>
  <header>
    <div class="header-inner">
      <div class="brand-group">
        <a href="{{ url_for('index') }}" class="brand">
          <span>Ricoh Print Management</span>
          <span class="brand-badge">SP 200</span>
        </a>
        <div class="status-indicators">
          <div class="status-tag {% if server_is_on %}status-tag-online{% else %}status-tag-offline{% endif %}" title="{{ server_msg }}">
            <span class="indicator-dot"></span>
            <span>SERVER: {% if server_is_on %}ONLINE{% else %}OFFLINE{% endif %}</span>
          </div>
          <div class="status-tag {% if printer_is_on %}status-tag-online{% else %}status-tag-offline{% endif %}" title="{{ printer_msg }}">
            <span class="indicator-dot"></span>
            <span>PRINTER: {% if printer_is_on %}READY{% else %}OFFLINE{% endif %}</span>
          </div>
        </div>
      </div>
      <nav>
        <a href="{{ url_for('index') }}" class="nav-btn {% if active_tab == 'dashboard' %}active{% endif %}">Dashboard</a>
        <a href="{{ url_for('upload_page') }}" class="nav-btn {% if active_tab == 'upload' %}active{% endif %}">Submit Job</a>
        <a href="{{ url_for('jobs_page') }}" class="nav-btn {% if active_tab == 'jobs' %}active{% endif %}">Queue</a>
        <a href="{{ url_for('printers_page') }}" class="nav-btn {% if active_tab == 'printers' %}active{% endif %}">Printers</a>
        <a href="{{ url_for('admin_page') }}" class="nav-btn {% if active_tab == 'admin' %}active{% endif %}">Endpoints</a>
      </nav>
    </div>
  </header>

  <main>
    <div class="alerts-wrapper">
      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="alert alert-{{ category if category != 'message' else 'info' }}">
              {{ message }}
            </div>
          {% endfor %}
        {% endif %}
      {% endwith %}
    </div>

    {{ content | safe }}
  </main>

  <footer>
    <div>CUPS Server: <code class="mono">{{ host_name }}</code> &bull; Network URL: <code class="mono">http://{{ lan_ip }}:{{ port }}/</code></div>
    <div>Ricoh Universal DDST Driver System</div>
  </footer>

  <script>
    function copyUrl() {
      const url = "http://{{ lan_ip }}:{{ port }}/";
      navigator.clipboard.writeText(url).then(() => {
        alert("Copied portal URL: " + url);
      });
    }

    if (window.location.pathname === '/' || window.location.pathname === '/jobs') {
      setTimeout(() => {
        const fileInput = document.querySelector('input[type=file]');
        if (!fileInput || !fileInput.files.length) {
          window.location.reload();
        }
      }, 5000);
    }
  </script>
</body>
</html>
"""

@app.route('/qr.svg')
def qr_code():
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    url = f"http://{lan_ip}:{port}/"
    factory = qrcode.image.svg.SvgPathImage
    img = qrcode.make(url, image_factory=factory)
    stream = io.BytesIO()
    img.save(stream)
    return Response(stream.getvalue(), mimetype='image/svg+xml')

@app.route('/')
def index():
    printers = fetch_all_printers()
    jobs = fetch_jobs(which='not-completed')
    all_jobs = fetch_jobs(which='all')
    server_on, server_msg, printer_on, printer_msg = check_system_statuses()
    
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    active_jobs_count = len(jobs)
    completed_jobs_count = len([j for j in all_jobs if j['state_code'] == 9])
    
    content = f"""
    <div class="network-banner">
      <div>
        <div style="font-weight:600; font-size:0.95rem; margin-bottom:0.25rem;">Network Access Portal</div>
        <div style="color:var(--text-secondary); font-size:0.82rem; margin-bottom:0.5rem;">
          Connect any device on the local network to print without installing client drivers.
        </div>
        <div style="display:flex; align-items:center; gap:0.5rem;">
          <code class="mono" style="background:var(--bg-main); padding:0.3rem 0.6rem; border:1px solid var(--border-color); border-radius:4px; color:var(--text-primary);">http://{lan_ip}:{port}/</code>
          <button onclick="copyUrl()" class="btn btn-sm btn-secondary">Copy</button>
        </div>
      </div>
      <div style="display:flex; align-items:center; gap:0.75rem;">
        <img class="qr-box" src="{url_for('qr_code')}" alt="QR Code">
        <div style="font-size:0.75rem; color:var(--text-muted); line-height:1.4;">
          <strong>Scan to Open</strong><br>Instant Mobile Printing
        </div>
      </div>
    </div>

    <div class="metrics-row">
      <div class="metric-card">
        <div class="metric-label">Print Server (CUPS)</div>
        <div class="metric-value" style="color: {'var(--status-success)' if server_on else 'var(--status-danger)'};">
          <span class="indicator-dot"></span>
          {'ONLINE' if server_on else 'OFFLINE'}
        </div>
        <div class="metric-subtext">{server_msg}</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Printer Hardware</div>
        <div class="metric-value" style="color: {'var(--status-success)' if printer_on else 'var(--status-danger)'};">
          <span class="indicator-dot"></span>
          {'READY' if printer_on else 'OFFLINE'}
        </div>
        <div class="metric-subtext">{printer_msg}</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Active Queue</div>
        <div class="metric-value" style="color: {'var(--status-warning)' if active_jobs_count > 0 else 'var(--text-primary)'};">
          {active_jobs_count}
        </div>
        <div class="metric-subtext">Pending jobs</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Completed Jobs</div>
        <div class="metric-value">{completed_jobs_count}</div>
        <div class="metric-subtext">Processed successfully</div>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <h2>Active Print Queue</h2>
        <div class="btn-group">
          <a href="{url_for('upload_page')}" class="btn btn-sm btn-primary">Submit File</a>
          <a href="{url_for('jobs_page')}" class="btn btn-sm btn-secondary">View All</a>
        </div>
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th style="width:70px;">Job ID</th>
              <th>Document Name</th>
              <th>Source / Origin</th>
              <th>Size</th>
              <th>Status</th>
              <th style="width:100px;">Action</th>
            </tr>
          </thead>
          <tbody>
    """

    if not jobs:
        content += """
            <tr>
              <td colspan="6" class="empty-message">No active print jobs in queue.</td>
            </tr>
        """
    else:
        for job in jobs:
            content += f"""
            <tr>
              <td class="mono">#{job['id']}</td>
              <td class="doc-title">{job['title']}</td>
              <td class="mono" style="color:var(--text-secondary);">{job['source']}</td>
              <td>{job['size_kb']} KB</td>
              <td><span class="badge {job['badge_class']}">{job['state_name']}</span></td>
              <td>
                <form method="POST" action="{url_for('cancel_job_route', job_id=job['id'])}" style="display:inline;">
                  <button type="submit" class="btn btn-sm btn-danger">Cancel</button>
                </form>
              </td>
            </tr>
            """

    content += """
          </tbody>
        </table>
      </div>
    </div>
    """
    
    return render_template_string(
        HTML_LAYOUT,
        content=content,
        page_title="Dashboard",
        active_tab="dashboard",
        lan_ip=lan_ip,
        port=port,
        host_name=LOCAL_COMPUTER_NAME,
        server_is_on=server_on,
        server_msg=server_msg,
        printer_is_on=printer_on,
        printer_msg=printer_msg
    )

@app.route('/upload')
def upload_page():
    printers = fetch_all_printers()
    server_on, server_msg, printer_on, printer_msg = check_system_statuses()
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    
    content = f"""
    <div class="page-header">
      <div class="page-title">
        <h1>Submit Print Job</h1>
        <p>Upload a document or photo for automatic processing and dispatch</p>
      </div>
    </div>

    <div class="panel" style="max-width: 650px; margin: 0 auto;">
      <div class="panel-header">
        <h2>Job Configuration</h2>
      </div>
      <div class="panel-body">
        <form method="POST" action="{url_for('upload')}" enctype="multipart/form-data" id="print-form">
          <div class="form-group">
            <label class="form-label" for="file-picker">Select Document or Image</label>
            <div class="file-dropzone" id="dropzone">
              <div style="font-weight:600; margin-bottom:0.25rem;" id="file-label">Choose File or Drop Here</div>
              <div style="font-size:0.75rem; color:var(--text-muted);">PDF, Word, PostScript, Plain Text, PNG, JPEG</div>
              <input type="file" name="file" id="file-picker" required accept=".pdf,.ps,.txt,.png,.jpg,.jpeg,.doc,.docx">
            </div>
          </div>

          <div class="form-group">
            <label class="form-label" for="input-title">Document Name (Optional)</label>
            <input type="text" class="form-control mono" name="title" id="input-title" placeholder="Auto-populated from filename">
          </div>

          <div class="form-group">
            <label class="form-label" for="select-printer">Target Printer Queue</label>
            <select class="form-select" name="printer" id="select-printer" required>
    """
    
    for name in printers.keys():
        selected = "selected" if name == DEFAULT_PRINTER else ""
        content += f'<option value="{name}" {selected}>{name}</option>'
        
    if not printers:
        content += f'<option value="{DEFAULT_PRINTER}" selected>{DEFAULT_PRINTER}</option>'

    content += """
            </select>
          </div>

          <div class="form-grid">
            <div class="form-group">
              <label class="form-label" for="input-copies">Copies</label>
              <input type="number" class="form-control" name="copies" id="input-copies" value="1" min="1" max="100">
            </div>
            <div class="form-group">
              <label class="form-label" for="select-media">Paper Size</label>
              <select class="form-select" name="media" id="select-media">
                <option value="A4" selected>A4 (210 x 297 mm)</option>
                <option value="Letter">US Letter (8.5 x 11 in)</option>
                <option value="Legal">US Legal (8.5 x 14 in)</option>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label" for="select-scaling">Paper Scaling</label>
              <select class="form-select" name="scaling_mode" id="select-scaling">
                <option value="fit" selected>Fit to Page (Auto-Resize)</option>
                <option value="none">Actual Size (100%)</option>
                <option value="fill">Fill Entire Sheet</option>
                <option value="auto-fit">Shrink Oversized Only</option>
              </select>
            </div>
          </div>

          <div style="margin-top: 1.5rem;">
            <button type="submit" class="btn btn-primary" style="width: 100%; padding: 0.65rem; font-size: 0.9rem;">
              Send Print Job
            </button>
          </div>
        </form>
      </div>
    </div>

    <script>
      const fileInput = document.getElementById('file-picker');
      const fileLabel = document.getElementById('file-label');
      const titleInput = document.getElementById('input-title');
      const dropzone = document.getElementById('dropzone');

      if (fileInput) {
        fileInput.addEventListener('change', function() {
          if (fileInput.files.length > 0) {
            const fileName = fileInput.files[0].name;
            const sizeKb = (fileInput.files[0].size / 1024).toFixed(1);
            fileLabel.textContent = fileName + ' (' + sizeKb + ' KB)';
            if (!titleInput.value) {
              titleInput.value = fileName;
            }
            dropzone.style.borderColor = 'var(--status-success)';
          }
        });
      }
    </script>
    """
    
    return render_template_string(
        HTML_LAYOUT,
        content=content,
        page_title="Submit Job",
        active_tab="upload",
        lan_ip=lan_ip,
        port=port,
        host_name=LOCAL_COMPUTER_NAME,
        server_is_on=server_on,
        server_msg=server_msg,
        printer_is_on=printer_on,
        printer_msg=printer_msg
    )

@app.route('/jobs')
def jobs_page():
    all_jobs = fetch_jobs(which='all')
    active_jobs = [j for j in all_jobs if j['state_code'] in (3, 4, 5, 6)]
    completed_jobs = [j for j in all_jobs if j['state_code'] in (7, 8, 9)]
    server_on, server_msg, printer_on, printer_msg = check_system_statuses()
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    
    content = f"""
    <div class="page-header">
      <div class="page-title">
        <h1>Print Queue & History</h1>
        <p>Live spooler state, client origin tracking, and cancellation controls</p>
      </div>
      <div>
        <a href="{url_for('upload_page')}" class="btn btn-primary">Submit Job</a>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <h2>Active Spool ({len(active_jobs)})</h2>
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th style="width:70px;">Job ID</th>
              <th>Document Name</th>
              <th>Source / Origin</th>
              <th>Size</th>
              <th>Submitted</th>
              <th>Status</th>
              <th style="width:100px;">Action</th>
            </tr>
          </thead>
          <tbody>
    """
    
    if not active_jobs:
        content += """
            <tr>
              <td colspan="7" class="empty-message">No pending jobs currently in spool.</td>
            </tr>
        """
    else:
        for job in active_jobs:
            content += f"""
            <tr>
              <td class="mono">#{job['id']}</td>
              <td class="doc-title">{job['title']}</td>
              <td class="mono" style="color:var(--text-secondary);">{job['source']}</td>
              <td>{job['size_kb']} KB</td>
              <td class="mono">{job['created_at']}</td>
              <td><span class="badge {job['badge_class']}">{job['state_name']}</span></td>
              <td>
                <form method="POST" action="{url_for('cancel_job_route', job_id=job['id'])}" style="display:inline;">
                  <button type="submit" class="btn btn-sm btn-danger">Cancel</button>
                </form>
              </td>
            </tr>
            """
            
    content += f"""
          </tbody>
        </table>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <h2>Job History ({len(completed_jobs)})</h2>
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th style="width:70px;">Job ID</th>
              <th>Document Name</th>
              <th>Source / Origin</th>
              <th>Size</th>
              <th>Timestamp</th>
              <th>Status</th>
              <th style="width:100px;">Action</th>
            </tr>
          </thead>
          <tbody>
    """
    
    if not completed_jobs:
        content += """
            <tr>
              <td colspan="7" class="empty-message">No historical jobs recorded.</td>
            </tr>
        """
    else:
        for job in completed_jobs[:35]:
            content += f"""
            <tr>
              <td class="mono">#{job['id']}</td>
              <td class="doc-title">{job['title']}</td>
              <td class="mono" style="color:var(--text-secondary);">{job['source']}</td>
              <td>{job['size_kb']} KB</td>
              <td class="mono">{job['created_at']}</td>
              <td><span class="badge {job['badge_class']}">{job['state_name']}</span></td>
              <td>
                <form method="POST" action="{url_for('restart_job_route', job_id=job['id'])}" style="display:inline;">
                  <button type="submit" class="btn btn-sm btn-secondary">Reprint</button>
                </form>
              </td>
            </tr>
            """
            
    content += """
          </tbody>
        </table>
      </div>
    </div>
    """
    
    return render_template_string(
        HTML_LAYOUT,
        content=content,
        page_title="Queue",
        active_tab="jobs",
        lan_ip=lan_ip,
        port=port,
        host_name=LOCAL_COMPUTER_NAME,
        server_is_on=server_on,
        server_msg=server_msg,
        printer_is_on=printer_on,
        printer_msg=printer_msg
    )

@app.route('/printers')
def printers_page():
    printers = fetch_all_printers()
    server_on, server_msg, printer_on, printer_msg = check_system_statuses()
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    
    content = f"""
    <div class="page-header">
      <div class="page-title">
        <h1>Printer Hardware & Queues</h1>
        <p>CUPS printer configurations, physical connection states, and maintenance</p>
      </div>
    </div>
    """
    
    for name, info in printers.items():
        state_code = info.get('printer-state', 3)
        state_name, badge_class = PRINTER_STATES.get(state_code, (f"State {state_code}", "badge-neutral"))
        is_shared = info.get('printer-is-shared', False)
        device_uri = info.get('device-uri', 'Unknown')
        model = info.get('printer-make-and-model', 'Ricoh SP 200 DDST')
        
        p_badge = '<span class="status-tag status-tag-online"><span class="indicator-dot"></span> CONNECTED</span>' if printer_on else '<span class="status-tag status-tag-offline"><span class="indicator-dot"></span> OFFLINE</span>'
        
        content += f"""
        <div class="panel">
          <div class="panel-header">
            <div>
              <span style="font-weight:600; font-size:1rem;">{name}</span>
              <span style="color:var(--text-muted); font-size:0.8rem; margin-left:0.5rem;">({model})</span>
            </div>
            <div class="btn-group">
              <form method="POST" action="{url_for('print_test_page', printer_name=name)}" style="display:inline;">
                <button type="submit" class="btn btn-sm btn-secondary">Print Test Page</button>
              </form>
              <form method="POST" action="{url_for('toggle_printer_state', printer_name=name)}" style="display:inline;">
                <button type="submit" class="btn btn-sm {'btn-secondary' if state_code == 5 else 'btn-danger'}">
                  {'Resume' if state_code == 5 else 'Pause'}
                </button>
              </form>
            </div>
          </div>
          <div class="table-container">
            <table>
              <tbody>
                <tr>
                  <td style="width:25%; color:var(--text-secondary);">Hardware Power</td>
                  <td>{p_badge} &bull; <span style="font-size:0.8rem; color:var(--text-muted);">{printer_msg}</span></td>
                </tr>
                <tr>
                  <td style="color:var(--text-secondary);">Spooler Status</td>
                  <td><span class="badge {badge_class}">{state_name}</span></td>
                </tr>
                <tr>
                  <td style="color:var(--text-secondary);">Device URI</td>
                  <td class="mono">{device_uri}</td>
                </tr>
                <tr>
                  <td style="color:var(--text-secondary);">Direct IPP Endpoint</td>
                  <td class="mono">http://{lan_ip}:631/printers/{name}</td>
                </tr>
                <tr>
                  <td style="color:var(--text-secondary);">Network Sharing</td>
                  <td>{'<span class="badge badge-success">AirPrint & IPP Active</span>' if is_shared else '<span class="badge badge-neutral">Local Only</span>'}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        """
        
    return render_template_string(
        HTML_LAYOUT,
        content=content,
        page_title="Printers",
        active_tab="printers",
        lan_ip=lan_ip,
        port=port,
        host_name=LOCAL_COMPUTER_NAME,
        server_is_on=server_on,
        server_msg=server_msg,
        printer_is_on=printer_on,
        printer_msg=printer_msg
    )

@app.route('/admin')
def admin_page():
    server_on, server_msg, printer_on, printer_msg = check_system_statuses()
    lan_ip = get_lan_ip()
    port = os.getenv('RICOH_WEB_PORT', '5000')
    
    content = f"""
    <div class="page-header">
      <div class="page-title">
        <h1>Network Client Configuration</h1>
        <p>Connection strings and network protocols for iOS, Android, macOS, and Windows</p>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <h2>Connection Endpoints by Platform</h2>
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th>Client Platform</th>
              <th>Setup Method</th>
              <th>Endpoint / URI</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td><strong>Web Portal (Zero Install)</strong></td>
              <td>Open web browser on any device or scan QR code</td>
              <td class="mono">http://{lan_ip}:{port}/</td>
            </tr>
            <tr>
              <td><strong>Apple iOS / iPadOS (AirPrint)</strong></td>
              <td>Share &rarr; Print &rarr; Select Ricoh</td>
              <td class="mono">Automatic mDNS / Bonjour</td>
            </tr>
            <tr>
              <td><strong>Android Print Service</strong></td>
              <td>Settings &rarr; Default Print Service &rarr; Add Printer</td>
              <td class="mono">http://{lan_ip}:631/printers/{DEFAULT_PRINTER}</td>
            </tr>
            <tr>
              <td><strong>Windows 10 / 11</strong></td>
              <td>Add Printer &rarr; Select a shared printer by name</td>
              <td class="mono">http://{lan_ip}:631/printers/{DEFAULT_PRINTER}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
    return render_template_string(
        HTML_LAYOUT,
        content=content,
        page_title="Endpoints",
        active_tab="admin",
        lan_ip=lan_ip,
        port=port,
        host_name=LOCAL_COMPUTER_NAME,
        server_is_on=server_on,
        server_msg=server_msg,
        printer_is_on=printer_on,
        printer_msg=printer_msg
    )

@app.route('/upload', methods=['POST'])
def upload():
    if 'file' not in request.files:
        flash('No file selected for upload', 'danger')
        return redirect(url_for('upload_page'))
    
    file = request.files['file']
    if file.filename == '':
        flash('No file selected', 'danger')
        return redirect(url_for('upload_page'))
    
    printer_name = request.form.get('printer', DEFAULT_PRINTER)
    doc_title = request.form.get('title', '').strip()
    if not doc_title:
        doc_title = file.filename
        
    copies = request.form.get('copies', '1')
    media = request.form.get('media', 'A4')
    scaling_mode = request.form.get('scaling_mode', 'fit')
    
    client_ip = request.remote_addr
    user_agent = request.user_agent.string if request.user_agent else ""
    client_type = "Web Client"
    if "Android" in user_agent:
        client_type = "Android Web"
    elif "iPhone" in user_agent:
        client_type = "iPhone Web"
    elif "iPad" in user_agent:
        client_type = "iPad Web"
    elif "Macintosh" in user_agent:
        client_type = "Mac Web"
    elif "Windows" in user_agent:
        client_type = "Windows Web"
    
    source_str = f"{client_type} ({client_ip})" if client_ip not in ('127.0.0.1', 'localhost') else f"Local Web ({LOCAL_COMPUTER_NAME})"
    
    options = {
        'copies': str(copies),
        'media': str(media),
        'PageSize': str(media)
    }
    
    if scaling_mode == 'fit':
        options['fit-to-page'] = 'true'
        options['fitplot'] = 'true'
        options['print-scaling'] = 'fit'
    elif scaling_mode == 'fill':
        options['fit-to-page'] = 'true'
        options['print-scaling'] = 'fill'
    elif scaling_mode == 'none':
        options['fit-to-page'] = 'false'
        options['print-scaling'] = 'none'
        options['scaling'] = '100'
    elif scaling_mode == 'auto-fit':
        options['fit-to-page'] = 'true'
        options['print-scaling'] = 'auto-fit'
    
    scaling_desc = SCALING_MODES.get(scaling_mode, scaling_mode)
    safe_filename = "".join([c for c in file.filename if c.isalnum() or c in "._- "])
    tmp_path = os.path.join("/tmp", f"ricoh_print_{int(time.time())}_{safe_filename}")
    
    try:
        file.save(tmp_path)
        conn = get_cups_connection()
        if not conn:
            flash("Could not connect to CUPS server", "danger")
            return redirect(url_for('upload_page'))
            
        job_id = conn.printFile(printer_name, tmp_path, doc_title, options)
        
        save_job_history(job_id, {
            "title": doc_title,
            "filename": file.filename,
            "source": source_str,
            "size_kb": int(os.path.getsize(tmp_path) / 1024),
            "timestamp": datetime.now().isoformat(),
            "printer": printer_name,
            "scaling_mode": scaling_mode
        })
        
        flash(f"Print job #{job_id} ('{doc_title}') submitted successfully to {printer_name} ({scaling_desc}, {media}).", "success")
        return redirect(url_for('jobs_page'))
    except Exception as e:
        flash(f"Failed to submit print job: {e}", "danger")
        return redirect(url_for('upload_page'))
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass

@app.route('/printer/<printer_name>/test-page', methods=['POST'])
def print_test_page(printer_name):
    conn = get_cups_connection()
    if not conn:
        flash("Could not connect to CUPS server", "danger")
        return redirect(url_for('printers_page'))
    
    try:
        job_id = conn.printTestPage(printer_name)
        save_job_history(job_id, {"title": f"Ricoh SP 200 Test Page ({printer_name})", "source": f"Admin ({LOCAL_COMPUTER_NAME})"})
        flash(f"Test page submitted (Job #{job_id}) on {printer_name}.", "success")
    except Exception as e:
        try:
            ps_test = f"""%!PS
/Helvetica-Bold findfont 24 scalefont setfont
100 700 moveto
(Ricoh SP 200 Test Page) show
/Helvetica findfont 12 scalefont setfont
100 660 moveto
(CUPS Server Host: {CUPS_HOST}) show
100 640 moveto
(Queue Name: {printer_name}) show
100 620 moveto
(Host Computer: {LOCAL_COMPUTER_NAME}) show
100 600 moveto
(Page Handling: Fit to A4) show
100 580 moveto
(Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}) show
showpage
"""
            tmp_test = f"/tmp/ricoh_test_{int(time.time())}.ps"
            with open(tmp_test, "w") as f:
                f.write(ps_test)
            job_id = conn.printFile(printer_name, tmp_test, "Ricoh SP 200 Test Page", {"media": "A4", "fit-to-page": "true"})
            os.remove(tmp_test)
            save_job_history(job_id, {"title": f"Ricoh SP 200 Test Page ({printer_name})", "source": f"Admin ({LOCAL_COMPUTER_NAME})"})
            flash(f"Test page generated and submitted (Job #{job_id}) on {printer_name}.", "success")
        except Exception as e2:
            flash(f"Could not print test page: {e2}", "danger")
            
    return redirect(url_for('printers_page'))

@app.route('/printer/<printer_name>/toggle-state', methods=['POST'])
def toggle_printer_state(printer_name):
    conn = get_cups_connection()
    if not conn:
        flash("Could not connect to CUPS server", "danger")
        return redirect(url_for('printers_page'))
    
    printers = conn.getPrinters()
    info = printers.get(printer_name, {})
    state_code = info.get('printer-state', 3)
    
    try:
        if state_code == 5:
            conn.enablePrinter(printer_name)
            flash(f"Printer '{printer_name}' resumed.", "success")
        else:
            conn.disablePrinter(printer_name, reason="Paused from Console")
            flash(f"Printer '{printer_name}' paused.", "warning")
    except Exception as e:
        flash(f"Failed to toggle printer state: {e}", "danger")
        
    return redirect(url_for('printers_page'))

@app.route('/jobs/<int:job_id>/cancel', methods=['POST'])
def cancel_job_route(job_id):
    conn = get_cups_connection()
    if not conn:
        flash("Could not connect to CUPS server", "danger")
        return redirect(url_for('jobs_page'))
    
    try:
        conn.cancelJob(job_id)
        flash(f"Job #{job_id} cancelled.", "info")
    except Exception as e:
        flash(f"Could not cancel job #{job_id}: {e}", "danger")
        
    return redirect(url_for('jobs_page'))

@app.route('/jobs/<int:job_id>/restart', methods=['POST'])
def restart_job_route(job_id):
    conn = get_cups_connection()
    if not conn:
        flash("Could not connect to CUPS server", "danger")
        return redirect(url_for('jobs_page'))
    
    try:
        conn.restartJob(job_id)
        flash(f"Job #{job_id} restarted.", "success")
    except Exception as e:
        flash(f"Could not restart job #{job_id}: {e}", "danger")
        
    return redirect(url_for('jobs_page'))

if __name__ == '__main__':
    port = int(os.getenv('RICOH_WEB_PORT', '5000'))
    lan_ip = get_lan_ip()
    print(f"============================================================")
    print(f" Ricoh Print Management Console                              ")
    print(f" Host:        {LOCAL_COMPUTER_NAME}                         ")
    print(f" Local URL:   http://localhost:{port}/                      ")
    print(f" Network URL: http://{lan_ip}:{port}/                       ")
    print(f"============================================================")
    app.run(host='0.0.0.0', port=port, debug=False)
