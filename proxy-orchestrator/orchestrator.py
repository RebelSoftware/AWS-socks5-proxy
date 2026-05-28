#!/usr/bin/env python3
"""
Fargate SOCKS5 Proxy - Local Orchestrator

Manages the lifecycle of Fargate SOCKS5 tasks:
- Monitors running tasks
- Starts new tasks when needed
- Detects IP changes
- Notifies HTTP proxy of endpoint changes
- Provides management API
"""

import os
import sys
import boto3
import time
import json
import logging
import socket
import threading
from datetime import datetime
import requests
from flask import Flask, request
from dotenv import load_dotenv

load_dotenv()

# Configure comprehensive logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - [%(funcName)s:%(lineno)d] - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
    ]
)
logger = logging.getLogger(__name__)

# Configuration from environment
ECS_CLUSTER = os.getenv('ECS_CLUSTER', 'proxy-cluster')
ECS_TASK_DEFINITION = os.getenv('ECS_TASK_DEFINITION', 'go-socks5-proxy')
AWS_REGION = os.getenv('AWS_REGION', 'us-east-1')
TASK_SUBNET = os.getenv('TASK_SUBNET')
TASK_SECURITY_GROUP = os.getenv('TASK_SECURITY_GROUP')
SOCKS5_PORT = int(os.getenv('SOCKS5_PORT', '1080'))
LOCAL_PROXY_PORT = int(os.getenv('LOCAL_PROXY_PORT', '8080'))

# IP Allowlist configuration
IP_ALLOWLIST_ENABLED = os.getenv('IP_ALLOWLIST_ENABLED', 'false').lower() == 'true'
CLIENT_SECURITY_GROUP_ID = os.getenv('CLIENT_SECURITY_GROUP_ID')  # Security group ID to update with client IP
DUAL_IP_RETENTION_MINUTES = int(os.getenv('DUAL_IP_RETENTION_MINUTES', '180'))

# Validation
if not TASK_SUBNET:
    logger.error("TASK_SUBNET environment variable not set")
    sys.exit(1)
if not TASK_SECURITY_GROUP:
    logger.error("TASK_SECURITY_GROUP environment variable not set")
    sys.exit(1)

logger.info(f"Configuration loaded:")
logger.info(f"  ECS_CLUSTER: {ECS_CLUSTER}")
logger.info(f"  ECS_TASK_DEFINITION: {ECS_TASK_DEFINITION}")
logger.info(f"  AWS_REGION: {AWS_REGION}")
logger.info(f"  TASK_SUBNET: {TASK_SUBNET}")
logger.info(f"  TASK_SECURITY_GROUP: {TASK_SECURITY_GROUP}")
logger.info(f"  SOCKS5_PORT: {SOCKS5_PORT}")
logger.info(f"  LOCAL_PROXY_PORT: {LOCAL_PROXY_PORT}")
logger.info(f"  IP_ALLOWLIST_ENABLED: {IP_ALLOWLIST_ENABLED}")
if IP_ALLOWLIST_ENABLED:
    logger.info(f"  CLIENT_SECURITY_GROUP_ID: {CLIENT_SECURITY_GROUP_ID}")
    logger.info(f"  DUAL_IP_RETENTION_MINUTES: {DUAL_IP_RETENTION_MINUTES}")



class FargateProxyOrchestrator:
    """Manages Fargate SOCKS5 task lifecycle with error handling"""
    
    def __init__(self):
        """Initialize AWS clients and state"""
        try:
            self.ecs = boto3.client('ecs', region_name=AWS_REGION)
            self.ec2 = boto3.client('ec2', region_name=AWS_REGION)
            logger.info("AWS clients initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize AWS clients: {e}", exc_info=True)
            raise
        
        self.task_ip = None
        self.task_arn = None
        self.last_update_time = time.time()
        self.connection_errors = 0
        self.max_connection_errors = 5
        
        # IP allowlist tracking for dual-IP support
        self.local_public_ip = None
        self.previous_public_ip = None
        self.previous_ip_timestamp = None  # When previous IP was added
    
    def get_running_tasks(self):
        """Get list of running SOCKS5 tasks with error handling"""
        try:
            logger.debug("Fetching running tasks from ECS...")
            
            response = self.ecs.list_tasks(
                cluster=ECS_CLUSTER,
                desiredStatus='RUNNING'
            )
            
            if not response.get('taskArns'):
                logger.info("No running tasks found in cluster")
                return []
            
            logger.debug(f"Found {len(response['taskArns'])} running tasks")
            
            # Get detailed task information
            tasks = self.ecs.describe_tasks(
                cluster=ECS_CLUSTER,
                tasks=response['taskArns']
            )
            
            if 'failures' in tasks and tasks['failures']:
                logger.warning(f"Task description failures: {tasks['failures']}")
            
            return tasks.get('tasks', [])
        
        except Exception as e:
            logger.error(f"Error listing/describing tasks: {e}", exc_info=True)
            self.connection_errors += 1
            if self.connection_errors > self.max_connection_errors:
                logger.critical(f"Too many connection errors ({self.connection_errors}), restarting")
            return []

    def get_task_public_ip(self, task):
        """Extract public IP from task's ENI with detailed error handling"""
        try:
            task_arn = task.get('taskArn', 'unknown')
            logger.debug(f"Extracting public IP from task {task_arn}")
            
            # Get ENI ID from task attachments
            attachments = task.get('attachments', [])
            if not attachments:
                logger.warning(f"Task {task_arn} has no attachments")
                return None
            
            eni_id = None
            for attachment in attachments:
                # AWS uses 'type' for ENI attachments, not 'name'
                attachment_type = attachment.get('type') or attachment.get('name')
                if attachment_type == 'ElasticNetworkInterface':
                    for detail in attachment.get('details', []):
                        if detail.get('name') == 'networkInterfaceId':
                            eni_id = detail.get('value')
                            logger.debug(f"Found ENI ID: {eni_id}")
                            break
                    if eni_id:
                        break
            
            if not eni_id:
                logger.warning(f"Task {task_arn} has no network interface ID")
                logger.debug(f"Available attachments: {attachments}")
                return None
            
            logger.debug(f"Task {task_arn} ENI: {eni_id}")
            
            # Query EC2 for public IP
            try:
                eni_details = self.ec2.describe_network_interfaces(
                    NetworkInterfaceIds=[eni_id]
                )
            except Exception as e:
                logger.error(f"Failed to describe ENI {eni_id}: {e}")
                return None
            
            if not eni_details.get('NetworkInterfaces'):
                logger.warning(f"ENI {eni_id} not found in EC2")
                return None
            
            eni = eni_details['NetworkInterfaces'][0]
            
            # Check for public IP in multiple possible locations
            public_ip = None
            
            # Standard location
            if 'Association' in eni and eni['Association']:
                public_ip = eni['Association'].get('PublicIp')
            
            # Direct attribute (some configurations)
            if not public_ip:
                public_ip = eni.get('PublicIp')
            
            if public_ip:
                logger.info(f"Task {task_arn} public IP: {public_ip}")
                return public_ip
            else:
                # Log full ENI details for debugging
                logger.warning(f"ENI {eni_id} has no public IP assigned yet")
                logger.debug(f"ENI details: {eni}")
                
                # Check if the task is in a public subnet but hasn't been assigned an IP yet
                subnet_id = None
                for attachment in attachments:
                    for detail in attachment.get('details', []):
                        if detail.get('name') == 'subnetId':
                            subnet_id = detail.get('value')
                            break
                
                if subnet_id:
                    logger.debug(f"Task subnet: {subnet_id}")
                
                return None
        
        except Exception as e:
            logger.error(f"Error extracting task IP: {e}", exc_info=True)
            return None   
    
    def start_new_task(self):
        """Start a new SOCKS5 task on Fargate with detailed error handling"""
        try:
            logger.info(f"Starting new Fargate task from definition: {ECS_TASK_DEFINITION}")
            
            try:
                response = self.ecs.run_task(
                    cluster=ECS_CLUSTER,
                    taskDefinition=ECS_TASK_DEFINITION,
                    launchType='FARGATE',
                    networkConfiguration={
                        'awsvpcConfiguration': {
                            'subnets': [TASK_SUBNET],
                            'securityGroups': [TASK_SECURITY_GROUP],
                            'assignPublicIp': 'ENABLED'
                        }
                    },
                    tags=[
                        {'key': 'Name', 'value': 'socks5-proxy'},
                        {'key': 'ManagedBy', 'value': 'local-proxy-orchestrator'},
                        {'key': 'StartedAt', 'value': datetime.utcnow().isoformat()}
                    ]
                )
            except Exception as e:
                logger.error(f"ECS run_task failed: {e}", exc_info=True)
                return False
            
            if 'failures' in response and response['failures']:
                logger.error(f"Task start failures: {response['failures']}")
                for failure in response['failures']:
                    logger.error(f"  - {failure.get('reason', 'unknown')}: {failure.get('arn', 'unknown')}")
                return False
            
            if not response.get('tasks'):
                logger.error("No tasks returned in run_task response")
                logger.debug(f"Response: {response}")
                return False
            
            self.task_arn = response['tasks'][0]['taskArn']
            task_status = response['tasks'][0].get('lastStatus', 'UNKNOWN')
            
            logger.info(f"Task started successfully: {self.task_arn} (status: {task_status})")
            logger.debug(f"Task definition: {response['tasks'][0].get('taskDefinitionArn', 'unknown')}")
            
            self.connection_errors = 0  # Reset error counter on success
            return True
        
        except Exception as e:
            logger.error(f"Unexpected error starting task: {e}", exc_info=True)
            return False
    
    def wait_for_task_ip(self, max_wait_seconds=300, check_interval=5):
        """Wait for task to get public IP with detailed logging"""
        try:
            logger.info(f"Waiting for task to acquire public IP (timeout: {max_wait_seconds}s)...")
            start_time = time.time()
            check_count = 0
            
            while time.time() - start_time < max_wait_seconds:
                check_count += 1
                elapsed = int(time.time() - start_time)
                
                try:
                    tasks = self.get_running_tasks()
                    
                    if not tasks:
                        logger.debug(f"[{elapsed}s] No running tasks found yet (check #{check_count})")
                        time.sleep(check_interval)
                        continue
                    
                    for task in tasks:
                        ip = self.get_task_public_ip(task)
                        if ip:
                            self.task_ip = ip
                            logger.info(f"Task acquired public IP after {elapsed} seconds: {ip}")
                            return ip
                    
                    logger.debug(f"[{elapsed}s] Tasks found but no IP assigned yet (check #{check_count})")
                
                except Exception as e:
                    logger.warning(f"Error during IP wait check: {e}")
                
                time.sleep(check_interval)
            
            logger.error(f"Timeout waiting for public IP after {max_wait_seconds} seconds")
            return None
        
        except Exception as e:
            logger.error(f"Error in wait_for_task_ip: {e}", exc_info=True)
            return None
    
    def stop_task(self, task_arn):
        """Stop a running task with error handling"""
        try:
            logger.info(f"Stopping task: {task_arn}")
            
            try:
                self.ecs.stop_task(
                    cluster=ECS_CLUSTER,
                    task=task_arn,
                    reason='Manual stop via orchestrator'
                )
                logger.info(f"Stop command sent for task {task_arn}")
            except Exception as e:
                logger.error(f"Error sending stop command: {e}", exc_info=True)
                return False
            
            # Verify task is stopped
            time.sleep(2)
            tasks = self.get_running_tasks()
            if not any(t['taskArn'] == task_arn for t in tasks):
                logger.info(f"Task {task_arn} successfully stopped")
                return True
            else:
                logger.warning(f"Task {task_arn} still running after stop command")
                return False
        
        except Exception as e:
            logger.error(f"Unexpected error stopping task: {e}", exc_info=True)
            return False
    
    def get_local_public_ip(self):
        """Detect local machine's public IP from external service"""
        if not IP_ALLOWLIST_ENABLED:
            return None
        
        try:
            # Use multiple services for redundancy
            ip_services = [
                'https://checkip.amazonaws.com',
                'https://api.ipify.org',
                'https://ident.me'
            ]
            last_error = None
            
            for service in ip_services:
                try:
                    logger.debug(f"Attempting IP detection from {service}...")
                    response = requests.get(service, timeout=10)
                    if response.status_code == 200:
                        ip = response.text.strip()
                        if self._is_valid_ip(ip):
                            logger.info(f"Detected public IP from {service}: {ip}")
                            return ip
                        else:
                            logger.warning(f"Invalid IP format from {service}: '{ip}'")
                    else:
                        logger.warning(f"HTTP {response.status_code} from {service}")
                except requests.exceptions.ConnectTimeout:
                    last_error = f"Connection timed out to {service}"
                    logger.debug(last_error)
                except requests.exceptions.ConnectionError as e:
                    last_error = f"Connection error to {service}: {e}"
                    logger.debug(last_error)
                except Exception as e:
                    last_error = f"Unexpected error from {service}: {e}"
                    logger.debug(last_error)
                    continue
            
            logger.warning(f"Could not detect public IP from any service. Last error: {last_error}")
            return None
        
        except Exception as e:
            logger.error(f"Error detecting public IP: {e}", exc_info=True)
            return None
    
    def _is_valid_ip(self, ip_str):
        """Validate if string is a valid IPv4 address"""
        try:
            parts = ip_str.split('.')
            if len(parts) != 4:
                return False
            for part in parts:
                if not part.isdigit() or not (0 <= int(part) <= 255):
                    return False
            return True
        except:
            return False
    
    def update_security_group_for_ip(self, client_ip):
        """
        Update security group to allow access from client IP.
        Implements dual-IP retention: keeps old IP for DUAL_IP_RETENTION_MINUTES.
        """
        if not IP_ALLOWLIST_ENABLED or not CLIENT_SECURITY_GROUP_ID:
            return True
        
        try:
            ip_cidr = f"{client_ip}/32"
            logger.info(f"Updating security group {CLIENT_SECURITY_GROUP_ID} to allow {ip_cidr}")
            
            # Get current security group rules
            try:
                sg_rules = self.ec2.describe_security_group_rules(
                    Filters=[
                        {'Name': 'group-id', 'Values': [CLIENT_SECURITY_GROUP_ID]},
                    ]
                )
            except Exception as e:
                logger.error(f"Failed to describe security group rules: {e}")
                return False
            
            # Find existing SOCKS5 rules (port 1080, TCP)
            socks5_rules = [
                r for r in sg_rules.get('SecurityGroupRules', [])
                if r.get('IsEgress') == False  # Ingress rules
                and r.get('FromPort') == 1080
                and r.get('ToPort') == 1080
                and r.get('IpProtocol') == 'tcp'
            ]
            
            # Check if new IP is already allowed
            new_ip_allowed = any(r.get('CidrIpv4') == ip_cidr for r in socks5_rules)
            
            if new_ip_allowed:
                logger.info(f"IP {ip_cidr} already allowed in security group")
                self.local_public_ip = client_ip
                return True
            
            # Remove old IP if retention period has passed
            if self.previous_public_ip and self.previous_ip_timestamp:
                time_elapsed = (time.time() - self.previous_ip_timestamp) / 60
                if time_elapsed >= DUAL_IP_RETENTION_MINUTES:
                    old_ip_cidr = f"{self.previous_public_ip}/32"
                    old_rule = next(
                        (r for r in socks5_rules if r.get('CidrIpv4') == old_ip_cidr),
                        None
                    )
                    if old_rule:
                        try:
                            logger.info(f"Removing old IP rule after {time_elapsed:.0f} minutes: {old_ip_cidr}")
                            self.ec2.revoke_security_group_ingress(
                                GroupId=CLIENT_SECURITY_GROUP_ID,
                                SecurityGroupRuleIds=[old_rule['SecurityGroupRuleId']] 
                            )
                        except Exception as e:
                            logger.warning(f"Failed to revoke old IP rule: {e}")
                    self.previous_public_ip = None
                    self.previous_ip_timestamp = None
            
            # Add new IP rule
            try:
                logger.info(f"Adding security group ingress rule for {ip_cidr}")
                self.ec2.authorize_security_group_ingress(
                    GroupId=CLIENT_SECURITY_GROUP_ID,
                    IpPermissions=[{
                        'IpProtocol': 'tcp',
                        'FromPort': 1080,
                        'ToPort': 1080,
                        'IpRanges': [{
                            'CidrIp': ip_cidr,
                            'Description': f'SOCKS5 client IP (added {datetime.utcnow().isoformat()})'
                        }]
                    }]
                )
                
                # Track previous IP for dual-IP retention
                if self.local_public_ip and self.local_public_ip != client_ip:
                    self.previous_public_ip = self.local_public_ip
                    self.previous_ip_timestamp = time.time()
                    logger.info(f"Stored previous IP {self.previous_public_ip} for dual-IP retention")
                
                self.local_public_ip = client_ip
                logger.info(f"Successfully updated security group to allow {ip_cidr}")
                return True
            
            except self.ec2.exceptions.InvalidPermission_Duplicate:
                logger.info(f"Rule already exists for {ip_cidr}")
                self.local_public_ip = client_ip
                return True
            except Exception as e:
                logger.error(f"Failed to authorize security group ingress: {e}", exc_info=True)
                return False
        
        except Exception as e:
            logger.error(f"Error updating security group: {e}", exc_info=True)
            return False
    
    def check_and_update_ip(self):
        """Check if local IP has changed and update security group if needed"""
        if not IP_ALLOWLIST_ENABLED or not CLIENT_SECURITY_GROUP_ID:
            return
        
        try:
            current_ip = self.get_local_public_ip()
            
            if not current_ip:
                logger.warning("Could not detect current public IP")
                return
            
            if self.local_public_ip and current_ip != self.local_public_ip:
                logger.warning(f"Local public IP changed: {self.local_public_ip} -> {current_ip}")
                self.update_security_group_for_ip(current_ip)
            elif not self.local_public_ip:
                logger.info(f"Initializing local public IP: {current_ip}")
                self.update_security_group_for_ip(current_ip)
        
        except Exception as e:
            logger.error(f"Error checking/updating IP: {e}", exc_info=True)
    
    def ensure_task_running(self):
        """Ensure we have a running task with public IP"""
        try:
            logger.debug("Ensuring task is running...")
            tasks = self.get_running_tasks()
            
            if tasks and len(tasks) > 0:
                task = tasks[0]
                task_arn = task.get('taskArn', 'unknown')
                task_status = task.get('lastStatus', 'UNKNOWN')
                
                logger.debug(f"Found running task {task_arn} (status: {task_status})")
                self.task_arn = task_arn
                
                # Try to get IP
                ip = self.get_task_public_ip(task)
                if ip:
                    self.task_ip = ip
                    self.connection_errors = 0
                    logger.info(f"Using running task with IP: {ip}")
                    return ip
                else:
                    logger.warning(f"Running task found but no public IP yet, waiting...")
                    return self.wait_for_task_ip()
            else:
                logger.info("No running tasks found, starting new one...")
                if self.start_new_task():
                    return self.wait_for_task_ip()
                else:
                    logger.error("Failed to start new task")
                    return None
        
        except Exception as e:
            logger.error(f"Error in ensure_task_running: {e}", exc_info=True)
            return None


# Initialize orchestrator and Flask app
orchestrator = FargateProxyOrchestrator()
app = Flask(__name__)

logger.info("Orchestrator and Flask app initialized")


@app.route('/status')
def status():
    """Get current proxy status"""
    try:
        status_data = {
            'status': 'running',
            'remote_ip': orchestrator.task_ip,
            'remote_task': orchestrator.task_arn,
            'local_port': LOCAL_PROXY_PORT,
            'socks5_port': SOCKS5_PORT,
            'timestamp': datetime.utcnow().isoformat()
        }
        
        # Add IP allowlist information if enabled
        if IP_ALLOWLIST_ENABLED:
            status_data['ip_allowlist_enabled'] = True
            status_data['local_public_ip'] = orchestrator.local_public_ip
            if orchestrator.previous_public_ip and orchestrator.previous_ip_timestamp:
                time_elapsed = (time.time() - orchestrator.previous_ip_timestamp) / 60
                status_data['previous_ip'] = orchestrator.previous_public_ip
                status_data['previous_ip_retention_remaining'] = max(0, DUAL_IP_RETENTION_MINUTES - time_elapsed)
        else:
            status_data['ip_allowlist_enabled'] = False
        
        return status_data, 200
    except Exception as e:
        logger.error(f"Error in /status endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/start', methods=['POST'])
def start_proxy():
    """Manually start a new proxy task"""
    try:
        logger.info("Received manual start request")
        ip = orchestrator.ensure_task_running()
        
        if ip:
            return {'status': 'success', 'ip': ip, 'task': orchestrator.task_arn}, 200
        else:
            return {'status': 'error', 'message': 'Failed to start task'}, 500
    except Exception as e:
        logger.error(f"Error in /start endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/stop', methods=['POST'])
def stop_proxy():
    """Stop the current proxy task"""
    try:
        logger.info("Received stop request")
        if orchestrator.task_arn:
            success = orchestrator.stop_task(orchestrator.task_arn)
            orchestrator.task_arn = None
            orchestrator.task_ip = None
            
            if success:
                return {'status': 'success', 'message': 'Task stopped'}, 200
            else:
                return {'status': 'error', 'message': 'Failed to stop task'}, 500
        else:
            return {'status': 'error', 'message': 'No running task'}, 400
    except Exception as e:
        logger.error(f"Error in /stop endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/ip/check', methods=['POST'])
def check_ip():
    """
    Manually check and update local public IP in security group.
    Useful if IP changes mid-session and needs immediate update.
    """
    if not IP_ALLOWLIST_ENABLED:
        return {'status': 'error', 'message': 'IP allowlist not enabled'}, 400
    
    try:
        logger.info("Received manual IP check request")
        orchestrator.check_and_update_ip()
        
        return {
            'status': 'success',
            'local_public_ip': orchestrator.local_public_ip,
            'previous_ip': orchestrator.previous_public_ip,
            'message': 'IP check and security group update completed'
        }, 200
    except Exception as e:
        logger.error(f"Error in /ip/check endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/ip/simulate-change', methods=['POST'])
def simulate_ip_change():
    """
    Simulate an IP change to test dual-IP retention logic.
    Accepts JSON: {"new_ip": "x.x.x.x", "force_cleanup": false}
    Does NOT call external IP services — uses the supplied IP directly.
    """
    if not IP_ALLOWLIST_ENABLED:
        return {'status': 'error', 'message': 'IP allowlist not enabled'}, 400
    
    try:
        data = request.get_json()
        if not data or 'new_ip' not in data:
            return {'status': 'error', 'message': 'Missing new_ip in request body'}, 400
        
        new_ip = data['new_ip']
        force_cleanup = data.get('force_cleanup', False)
        
        # Validate IP format
        if not orchestrator._is_valid_ip(new_ip):
            return {'status': 'error', 'message': f'Invalid IP: {new_ip}'}, 400
        
        logger.info(f"SIMULATED IP change: {orchestrator.local_public_ip} -> {new_ip}")
        
        # Simulate the IP change by updating the SG directly
        # (bypasses get_local_public_ip)
        old_ip = orchestrator.local_public_ip
        success = orchestrator.update_security_group_for_ip(new_ip)
        
        if not success:
            return {'status': 'error', 'message': 'Security group update failed'}, 500
        
        # Optionally force cleanup of previous IP to simulate retention expiry
        if force_cleanup and orchestrator.previous_public_ip:
            old_ip_cidr = f"{orchestrator.previous_public_ip}/32"
            try:
                # Find and remove the old IP rule
                sg_rules = orchestrator.ec2.describe_security_group_rules(
                    Filters=[{'Name': 'group-id', 'Values': [CLIENT_SECURITY_GROUP_ID]}]
                )
                socks5_rules = [
                    r for r in sg_rules.get('SecurityGroupRules', [])
                    if r.get('IsEgress') == False
                    and r.get('FromPort') == 1080
                    and r.get('ToPort') == 1080
                    and r.get('IpProtocol') == 'tcp'
                ]
                old_rule = next(
                    (r for r in socks5_rules if r.get('CidrIpv4') == old_ip_cidr),
                    None
                )
                if old_rule:
                    orchestrator.ec2.revoke_security_group_ingress(
                        GroupId=CLIENT_SECURITY_GROUP_ID,
                        SecurityGroupRuleIds=[old_rule['SecurityGroupRuleId']]
                    )
                    logger.info(f"Force cleaned old IP: {old_ip_cidr}")
                
                orchestrator.previous_public_ip = None
                orchestrator.previous_ip_timestamp = None
            except Exception as e:
                logger.warning(f"Force cleanup failed: {e}")
        
        return {
            'status': 'success',
            'simulated_change': f'{old_ip} -> {new_ip}',
            'current_local_ip': orchestrator.local_public_ip,
            'previous_local_ip': orchestrator.previous_public_ip,
            'force_cleanup_applied': force_cleanup
        }, 200
    except Exception as e:
        logger.error(f"Error in /ip/simulate-change endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/ip/status', methods=['GET'])
def ip_status():
    """Get current IP allowlist status and tracking information"""
    if not IP_ALLOWLIST_ENABLED:
        return {'status': 'error', 'message': 'IP allowlist not enabled'}, 400
    
    try:
        data = {
            'ip_allowlist_enabled': True,
            'current_local_ip': orchestrator.local_public_ip,
            'previous_local_ip': orchestrator.previous_public_ip,
            'dual_ip_retention_minutes': DUAL_IP_RETENTION_MINUTES
        }
        
        if orchestrator.previous_ip_timestamp:
            time_elapsed = (time.time() - orchestrator.previous_ip_timestamp) / 60
            data['previous_ip_time_remaining'] = max(0, DUAL_IP_RETENTION_MINUTES - time_elapsed)
            data['previous_ip_age_minutes'] = time_elapsed
        
        return data, 200
    except Exception as e:
        logger.error(f"Error in /ip/status endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


@app.route('/ip/diagnose', methods=['GET'])
def ip_diagnose():
    """Diagnose connectivity to IP detection services"""
    if not IP_ALLOWLIST_ENABLED:
        return {'status': 'error', 'message': 'IP allowlist not enabled'}, 400
    
    try:
        results = {}
        ip_services = [
            'https://checkip.amazonaws.com',
            'https://api.ipify.org',
            'https://ident.me',
            'https://ifconfig.me'
        ]
        
        for service in ip_services:
            try:
                start = time.time()
                response = requests.get(service, timeout=10)
                elapsed = time.time() - start
                body = response.text.strip()
                is_valid_ip = orchestrator._is_valid_ip(body)
                results[service] = {
                    'reachable': True,
                    'status_code': response.status_code,
                    'response_ms': round(elapsed * 1000),
                    'response_body': body,
                    'valid_ip': is_valid_ip
                }
            except Exception as e:
                results[service] = {
                    'reachable': False,
                    'error': str(e)
                }
        
        return {
            'ip_allowlist_enabled': True,
            'current_local_ip': orchestrator.local_public_ip,
            'ip_detection_services': results
        }, 200
    except Exception as e:
        logger.error(f"Error in /ip/diagnose endpoint: {e}", exc_info=True)
        return {'status': 'error', 'message': str(e)}, 500


def notify_http_proxy(ip, port):
    """Notify HTTP proxy of SOCKS5 endpoint change"""
    try:
        logger.info(f"Notifying HTTP proxy of SOCKS5 endpoint: {ip}:{port}")
        # This is handled internally by the http_proxy reading from orchestrator
        logger.debug("HTTP proxy will detect IP change on next check")
    except Exception as e:
        logger.error(f"Error notifying HTTP proxy: {e}")


def monitor_task():
    """Background thread that monitors task health and IP changes"""
    logger.info("Starting task monitor thread...")
    
    check_interval = 30
    previous_ip = None
    ip_check_counter = 0  # Check local IP every 2nd cycle (60 seconds)
    
    while True:
        try:
            # Ensure we have a running task
            current_ip = orchestrator.ensure_task_running()
            
            # Check if task IP changed
            if current_ip and current_ip != previous_ip:
                if previous_ip:
                    logger.warning(f"SOCKS5 endpoint IP changed: {previous_ip} -> {current_ip}")
                    notify_http_proxy(current_ip, SOCKS5_PORT)
                previous_ip = current_ip
            
            # Check local public IP and update security group (every 60 seconds)
            ip_check_counter += 1
            if ip_check_counter >= 2:
                orchestrator.check_and_update_ip()
                ip_check_counter = 0
            
            logger.debug(f"Monitor check complete - remote IP: {current_ip}, local IP: {orchestrator.local_public_ip}")
            time.sleep(check_interval)
        
        except Exception as e:
            logger.error(f"Error in monitor thread: {e}", exc_info=True)
            time.sleep(check_interval * 2)


def start_monitor_thread():
    """Start the background monitoring thread"""
    try:
        monitor_thread = threading.Thread(target=monitor_task, daemon=True)
        monitor_thread.start()
        logger.info("Monitor thread started")
    except Exception as e:
        logger.error(f"Failed to start monitor thread: {e}", exc_info=True)


if __name__ == '__main__':
    try:
        logger.info("=" * 80)
        logger.info("STARTING ORCHESTRATOR")
        logger.info("=" * 80)
        
        # Start monitor thread
        start_monitor_thread()
        
        # Perform initial IP detection immediately (don't wait for monitor cycle)
        if IP_ALLOWLIST_ENABLED:
            logger.info("Performing initial public IP detection...")
            detected_ip = orchestrator.get_local_public_ip()
            if detected_ip:
                logger.info(f"Initial public IP detected: {detected_ip}")
                orchestrator.update_security_group_for_ip(detected_ip)
            else:
                logger.warning("Initial public IP detection failed")
                logger.warning("Check container can reach: https://checkip.amazonaws.com")
                logger.warning("  docker exec proxy-orchestrator curl -s https://checkip.amazonaws.com")
        
        # Start Flask app
        logger.info("Starting Flask management API on port 5000...")
        app.run(host='0.0.0.0', port=5000, debug=False)
    
    except KeyboardInterrupt:
        logger.info("Orchestrator stopped by user")
        sys.exit(0)
    except Exception as e:
        logger.critical(f"Fatal error in orchestrator: {e}", exc_info=True)
        sys.exit(1)
