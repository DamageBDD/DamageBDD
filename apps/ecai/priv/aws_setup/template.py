"""ECAI-owned CloudFormation plan. No caller-supplied templates or IAM documents."""
from __future__ import annotations
import hashlib
import json
import re

VERSION = "ecai-aws-fargate/v1"
PROFILES = {"cpu-small": (1, 2048), "cpu-medium": (2, 4096)}

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)

def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()

def require(condition, message):
    if not condition:
        raise ValueError(message)

def validate_config(config):
    require(isinstance(config, dict), "invalid_operator_config")
    role = config.get("coordinator_role_arn", "")
    require(re.fullmatch(r"arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+", role) is not None,
            "coordinator_role_not_configured")
    image = config.get("worker_image", "")
    require(isinstance(image, str) and len(image) <= 255 and re.fullmatch(
        r"[A-Za-z0-9._/-]+@sha256:[a-f0-9]{64}", image) is not None, "pinned_worker_image_required")
    command = config.get("worker_command", [])
    require(isinstance(command, list) and 0 < len(command) <= 16 and all(
        isinstance(x, str) and 0 < len(x) <= 512 and "\x00" not in x for x in command), "invalid_worker_command")
    require(isinstance(config.get("regions"), list) and config["regions"] and all(
        re.fullmatch(r"[a-z]{2}-[a-z]+-\d", r) and not r.startswith(("cn-", "us-gov-"))
        for r in config["regions"]), "commercial_regions_required")
    return config

def validate_options(options):
    require(isinstance(options, dict) and not (set(options) - {
        "profile", "max_vcpus", "log_retention_days", "job_timeout_seconds"}), "invalid_plan_options")
    result = {"profile": "cpu-small", "max_vcpus": 1, "log_retention_days": 14,
              "job_timeout_seconds": 900, **options}
    require(result["profile"] in PROFILES, "invalid_compute_profile")
    require(type(result["max_vcpus"]) is int and result["max_vcpus"] in (1, 2, 4, 8), "invalid_capacity")
    require(result["max_vcpus"] >= PROFILES[result["profile"]][0], "capacity_below_job_size")
    require(type(result["log_retention_days"]) is int and result["log_retention_days"] in (7, 14, 30), "invalid_log_retention")
    require(type(result["job_timeout_seconds"]) is int and 300 <= result["job_timeout_seconds"] <= 3600, "invalid_job_timeout")
    return result

def make_plan(request):
    config = validate_config(request["config"])
    options = validate_options(request.get("options", {}))
    op, account, region = request["operation_id"], request["account_id"], request["region"]
    require(re.fullmatch(r"[a-f0-9]{32}", op) is not None, "invalid_operation_id")
    require(re.fullmatch(r"[0-9]{12}", account) is not None, "invalid_aws_account")
    require(region in config["regions"], "region_not_allowed")
    external = request["external_id"]
    require(re.fullmatch(r"[A-Fa-f0-9]{48}", external) is not None, "invalid_external_id")
    prefix = "ecai-auto-" + op
    vcpu, memory = PROFILES[options["profile"]]
    arn = lambda service, suffix: f"arn:aws:{service}:{region}:{account}:{suffix}"
    iam_arn = lambda name: f"arn:aws:iam::{account}:role/{name}"
    bucket = f"ecai-auto-{account}-{op}"
    # Max bucket name length = 10 + 12 + 1 + 32 = 55; unique per operation.
    queue_name, job_name, probe_name = prefix + "-queue", prefix + "-worker", prefix + "-probe"
    log_name = "/ecai/aws-setup/" + op
    logs_arn = arn("logs", "log-group:" + log_name)
    ref = lambda k: {"Ref": k}
    attr = lambda k, name: {"Fn::GetAtt": [k, name]}
    tags = [{"Key": "ecai:setup-id", "Value": op}, {"Key": "ecai:component", "Value": "automatic-aws"}]
    policy = lambda statements: {"Version": "2012-10-17", "Statement": statements}
    allow = lambda actions, resources, **kw: {"Effect": "Allow", "Action": actions, "Resource": resources, **kw}
    ecs_trust = policy([{"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                         "Action": "sts:AssumeRole", "Condition": {"StringEquals": {"aws:SourceAccount": account},
                         "ArnLike": {"aws:SourceArn": arn("ecs", "*")}}}])
    s3_statements = [allow(["s3:GetBucketLocation"], [f"arn:aws:s3:::{bucket}"]),
        allow(["s3:ListBucket"], [f"arn:aws:s3:::{bucket}"], Condition={"StringLike": {"s3:prefix": ["staging/", "staging/*"]}}),
        allow(["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], [f"arn:aws:s3:::{bucket}/staging/*"])]
    runtime_statements = s3_statements + [
        allow(["batch:SubmitJob"], [ref("Queue"), ref("WorkerDefinition"), ref("ProbeDefinition")]),
        # These Batch Describe operations require Resource:*; they are read-only.
        allow(["batch:DescribeJobs", "batch:DescribeJobDefinitions", "batch:DescribeJobQueues", "batch:ListJobs"], ["*"]),
        allow(["batch:TerminateJob"], [arn("batch", "job/*")], Condition={"StringEquals": {"aws:ResourceTag/ecai:setup-id": op}}),
        allow(["logs:GetLogEvents", "logs:DescribeLogStreams"], [logs_arn + ":*"])]
    execution_statements = [allow(["logs:CreateLogStream", "logs:PutLogEvents"], [logs_arn + ":*"])]
    private_ecr = re.fullmatch(r"([0-9]{12})\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/(.+)@sha256:[a-f0-9]{64}", config["worker_image"])
    if private_ecr:
        owner, registry_region, repository = private_ecr.groups()
        execution_statements += [allow(["ecr:GetAuthorizationToken"], ["*"]),
            allow(["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"],
                  [f"arn:aws:ecr:{registry_region}:{owner}:repository/{repository}"])]
    resources = {
        "Network": {"Type": "AWS::EC2::VPC", "Properties": {"CidrBlock": "10.74.0.0/16", "EnableDnsHostnames": True, "EnableDnsSupport": True, "Tags": tags}},
        "Gateway": {"Type": "AWS::EC2::InternetGateway", "Properties": {"Tags": tags}},
        "GatewayAttachment": {"Type": "AWS::EC2::VPCGatewayAttachment", "Properties": {"VpcId": ref("Network"), "InternetGatewayId": ref("Gateway")}},
        "Routes": {"Type": "AWS::EC2::RouteTable", "Properties": {"VpcId": ref("Network"), "Tags": tags}},
        "InternetRoute": {"Type": "AWS::EC2::Route", "DependsOn": "GatewayAttachment", "Properties": {"RouteTableId": ref("Routes"), "DestinationCidrBlock": "0.0.0.0/0", "GatewayId": ref("Gateway")}},
        "Workers": {"Type": "AWS::EC2::SecurityGroup", "Properties": {"VpcId": ref("Network"), "GroupDescription": "ECAI workers: no inbound access, outbound HTTPS only", "SecurityGroupIngress": [], "SecurityGroupEgress": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "CidrIp": "0.0.0.0/0"}], "Tags": tags}},
        "Artifacts": {"Type": "AWS::S3::Bucket", "DeletionPolicy": "Retain", "UpdateReplacePolicy": "Retain", "Properties": {
            "BucketName": bucket, "PublicAccessBlockConfiguration": {"BlockPublicAcls": True, "IgnorePublicAcls": True, "BlockPublicPolicy": True, "RestrictPublicBuckets": True},
            "OwnershipControls": {"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]},
            "BucketEncryption": {"ServerSideEncryptionConfiguration": [{"ServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]},
            "LifecycleConfiguration": {"Rules": [{"Id": "abort-incomplete", "Status": "Enabled", "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}}]}, "Tags": tags}},
        "ArtifactPolicy": {"Type": "AWS::S3::BucketPolicy", "DeletionPolicy": "Retain", "UpdateReplacePolicy": "Retain", "Properties": {"Bucket": ref("Artifacts"), "PolicyDocument": policy([
            {"Effect": "Deny", "Principal": "*", "Action": "s3:*", "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"], "Condition": {"Bool": {"aws:SecureTransport": "false"}}}])}},
        "Logs": {"Type": "AWS::Logs::LogGroup", "Properties": {"LogGroupName": log_name, "RetentionInDays": options["log_retention_days"], "Tags": tags}},
        "RuntimeRole": {"Type": "AWS::IAM::Role", "Properties": {"RoleName": prefix + "-runtime", "MaxSessionDuration": 3600, "AssumeRolePolicyDocument": policy([
            {"Effect": "Allow", "Principal": {"AWS": config["coordinator_role_arn"]}, "Action": "sts:AssumeRole", "Condition": {"StringEquals": {"sts:ExternalId": external}}}]),
            "Policies": [{"PolicyName": "EcaiRuntime", "PolicyDocument": policy(runtime_statements)}], "Tags": tags}},
        "ExecutionRole": {"Type": "AWS::IAM::Role", "Properties": {"RoleName": prefix + "-execution", "AssumeRolePolicyDocument": ecs_trust, "Policies": [{"PolicyName": "PullAndLog", "PolicyDocument": policy(execution_statements)}], "Tags": tags}},
        "TaskRole": {"Type": "AWS::IAM::Role", "Properties": {"RoleName": prefix + "-task", "AssumeRolePolicyDocument": ecs_trust, "Policies": [{"PolicyName": "StagingOnly", "PolicyDocument": policy(s3_statements)}], "Tags": tags}}
    }
    for n in (0, 1):
        key = "Subnet" + str(n)
        resources[key] = {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": ref("Network"), "CidrBlock": f"10.74.{n+1}.0/24", "AvailabilityZone": {"Fn::Select": [n, {"Fn::GetAZs": ""}]}, "MapPublicIpOnLaunch": False, "Tags": tags}}
        resources[key + "Routes"] = {"Type": "AWS::EC2::SubnetRouteTableAssociation", "Properties": {"SubnetId": ref(key), "RouteTableId": ref("Routes")}}
    resources["Compute"] = {"Type": "AWS::Batch::ComputeEnvironment", "DependsOn": ["InternetRoute", "Subnet0Routes", "Subnet1Routes"], "Properties": {
        "Type": "MANAGED", "State": "ENABLED", "ComputeEnvironmentName": prefix + "-compute",
        "ComputeResources": {"Type": "FARGATE", "MaxvCpus": options["max_vcpus"], "Subnets": [ref("Subnet0"), ref("Subnet1")], "SecurityGroupIds": [attr("Workers", "GroupId")]},
        "Tags": {t["Key"]: t["Value"] for t in tags}}}
    resources["Queue"] = {"Type": "AWS::Batch::JobQueue", "Properties": {"JobQueueName": queue_name, "Priority": 1, "State": "ENABLED", "ComputeEnvironmentOrder": [{"Order": 1, "ComputeEnvironment": ref("Compute")}], "Tags": {t["Key"]: t["Value"] for t in tags}}}
    def job_definition(name, command, cpu, mem, timeout):
        return {"Type": "AWS::Batch::JobDefinition", "Properties": {"Type": "container", "JobDefinitionName": name, "PlatformCapabilities": ["FARGATE"], "RetryStrategy": {"Attempts": 1}, "Timeout": {"AttemptDurationSeconds": timeout}, "PropagateTags": True, "Tags": {t["Key"]: t["Value"] for t in tags},
            "ContainerProperties": {"Image": config["worker_image"], "Command": command, "ExecutionRoleArn": attr("ExecutionRole", "Arn"), "JobRoleArn": attr("TaskRole", "Arn"),
            "ResourceRequirements": [{"Type": "VCPU", "Value": str(cpu)}, {"Type": "MEMORY", "Value": str(mem)}],
            "NetworkConfiguration": {"AssignPublicIp": "ENABLED"}, "RuntimePlatform": {"OperatingSystemFamily": "LINUX", "CpuArchitecture": "X86_64"},
            "LogConfiguration": {"LogDriver": "awslogs", "Options": {"awslogs-group": ref("Logs"), "awslogs-region": region, "awslogs-stream-prefix": "ecai"}}}}}
    resources["WorkerDefinition"] = job_definition(job_name, config["worker_command"], vcpu, memory, options["job_timeout_seconds"])
    resources["ProbeDefinition"] = job_definition(probe_name, ["python3", "/opt/ecai/aws_smoke.py"], 1, 2048, 300)
    outputs = {"RoleArn": attr("RuntimeRole", "Arn"), "QueueArn": ref("Queue"), "JobDefinitionArn": ref("WorkerDefinition"), "ProbeDefinitionArn": ref("ProbeDefinition"), "Bucket": ref("Artifacts"), "LogGroup": ref("Logs")}
    template = {"AWSTemplateFormatVersion": "2010-09-09", "Description": "ECAI automatic AWS CPU environment. No indexing job is submitted by deployment.", "Resources": resources, "Outputs": {k: {"Value": v} for k, v in outputs.items()}}
    plan = {"version": VERSION, "operation_id": op, "account_id": account, "region": region, "stack_name": prefix,
            "external_id": external, "coordinator_role_arn": config["coordinator_role_arn"], "worker_image": config["worker_image"], "worker_command": list(config["worker_command"]),
            "options": options, "template": template, "template_sha256": digest(template),
            "connection": {"role_arn": iam_arn(prefix + "-runtime"), "region": region, "job_queue": queue_name, "job_definition": job_name, "bucket": bucket},
            "resources": [{"logical_id": k, "type": v["Type"]} for k, v in resources.items()],
            "warnings": ["Creates IAM roles, a VPC, two public subnets, a private bucket, logs and Batch resources.",
                         "Workers have no inbound access and use public IPv4 with outbound HTTPS; public IP, storage, logs and transfer may incur charges.",
                         "No NAT gateway is created. No indexing job is launched. AWS bills are not capped by ECAI reservations.",
                         "The S3 bucket and TLS-only bucket policy are retained on deletion or rollback. Stored objects continue to incur charges.",
                         "Verification jobs are separately approved, chargeable diagnostics outside the indexing reservation ledger."]}
    require(len(canonical(template).encode()) <= 51200, "template_too_large")
    plan["plan_sha256"] = digest(plan)
    return plan

def check_plan(plan):
    require(isinstance(plan, dict), "invalid_plan")
    original = dict(plan)
    claimed = original.pop("plan_sha256", None)
    require(claimed == digest(original) and digest(plan["template"]) == plan["template_sha256"], "plan_hash_mismatch")
    return plan
