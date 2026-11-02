#!/usr/bin/env python3
"""Private line protocol over an inherited pipe. Never invoke with credential args.

Bootstrap mode keeps explicitly supplied credentials only in this process for a
bounded lifetime. Runtime mode uses the node's normal credential provider chain,
never bootstrap credentials. Stdout contains allowlisted public results only.
"""
from __future__ import annotations
import hashlib
import json
import logging
import os
import re
import signal
import select
import threading
import sys
import time
from pathlib import Path

# Permit a trusted sibling import even under python -I. The script path itself
# is operator-controlled and is not supplied by any dashboard request.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from template import canonical, check_plan, make_plan, require, validate_config, VERSION

logging.disable(logging.CRITICAL)
try:
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
except (ImportError, ValueError, OSError):
    pass
try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError, BotoCoreError
except ImportError:
    print('{"ok":false,"error":"aws_sdk_not_installed"}', flush=True)
    sys.exit(1)

MAX_INPUT = 98304
MAX_OUTPUT = 131072
SAFE_ERRORS = {
    "AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "ExpiredToken",
    "ExpiredTokenException", "InvalidClientTokenId", "SignatureDoesNotMatch",
    "UnrecognizedClientException", "InsufficientCapabilitiesException", "LimitExceededException",
    "Throttling", "ThrottlingException", "TokenAlreadyExistsException", "AlreadyExistsException",
    "ValidationError", "ResourceNotFoundException", "NoSuchBucket", "NoSuchKey", "404",
}

def error_code(exc):
    # Never return SDK Message, response headers, URLs, request bodies, traceback,
    # credential-provider command output or raw exception string.
    if isinstance(exc, ClientError):
        code = exc.response.get("Error", {}).get("Code", "aws_api_error")
        return code if code in SAFE_ERRORS else "aws_api_error"
    if isinstance(exc, ValueError) and len(exc.args) == 1 and re.fullmatch(r"[a-z][a-z0-9_]{0,79}", str(exc.args[0])):
        return str(exc.args[0])
    if isinstance(exc, BotoCoreError):
        return "aws_transport_or_credentials_error"
    return "aws_setup_failed"

def client(session, service, region, no_retry=False):
    # Fixed HTTPS service endpoints; AWS_ENDPOINT_URL and per-profile overrides
    # cannot redirect a pasted key to a different host. Deliberately no proxy
    # inherited from the hosting process for customer credential operations.
    endpoint = f"https://{service}.{region}.amazonaws.com"
    return session.client(service, region_name=region, endpoint_url=endpoint,
        config=Config(connect_timeout=5, read_timeout=12, retries={"total_max_attempts": 1 if no_retry else 2, "mode": "standard"},
                      proxies={}, ignore_configured_endpoint_urls=True, user_agent_extra="ecai-aws-setup/1"))

def public_identity(session, region):
    result = client(session, "sts", region).get_caller_identity()
    account, arn = result.get("Account", ""), result.get("Arn", "")
    require(re.fullmatch(r"\d{12}", account) is not None and isinstance(arn, str) and len(arn) <= 2048,
            "invalid_caller_identity")
    require(not arn.endswith(":root"), "root_credentials_rejected")
    require(arn.startswith((f"arn:aws:iam::{account}:", f"arn:aws:sts::{account}:")), "unsupported_aws_partition")
    return {"account_id": account, "caller_arn": arn}

def matches_coordinator(actual, expected):
    if actual == expected:
        return True
    match = re.fullmatch(r"arn:aws:iam::(\d{12}):role/(.+)", expected)
    if not match:
        return False
    account, role_path = match.groups()
    # IAM role names are unique within the account; STS omits the IAM role path.
    return re.fullmatch(r"arn:aws:sts::" + account + r":assumed-role/" + re.escape(role_path.split('/')[-1]) + r"/[^/]+", actual) is not None

def session_from_credentials(credentials):
    require(isinstance(credentials, dict) and not (set(credentials) - {"access_key_id", "secret_access_key", "session_token"}), "invalid_aws_credentials")
    key, secret, token = (credentials.get(k, "") for k in ("access_key_id", "secret_access_key", "session_token"))
    require(isinstance(key, str) and re.fullmatch(r"(?:AKIA|ASIA)[A-Z0-9]{16}", key) is not None,
            "invalid_access_key_id")
    require(isinstance(secret, str) and 16 <= len(secret) <= 128 and all(32 < ord(c) < 127 for c in secret), "invalid_secret_access_key")
    require(isinstance(token, str) and len(token) <= 8192 and all(32 < ord(c) < 127 for c in token), "invalid_session_token")
    require(not key.startswith("ASIA") or bool(token), "session_token_required")
    return boto3.Session(aws_access_key_id=key, aws_secret_access_key=secret, aws_session_token=token or None)

class Bootstrap:
    def __init__(self, init):
        self.config = validate_config(init["config"])
        self.region = init["region"]
        require(self.region in self.config["regions"], "region_not_allowed")
        self.session = session_from_credentials(init["credentials"])
        self.identity = public_identity(self.session, self.region)
        self.cf = client(self.session, "cloudformation", self.region)

    def plan(self, args):
        return make_plan({**args, "config": self.config, "region": self.region, **self.identity})

    def owned_stack(self, plan):
        check_plan(plan)
        require(self.identity["account_id"] == plan["account_id"] and self.region == plan["region"], "aws_account_or_region_mismatch")
        try:
            response = self.cf.describe_stacks(StackName=plan["stack_name"])
        except ClientError as error:
            # AWS has no separate not-found code for DescribeStacks. Treat only
            # the documented not-exist response as absent, not permission errors.
            e = error.response.get("Error", {})
            if e.get("Code") == "ValidationError" and "does not exist" in e.get("Message", ""):
                return None
            raise
        stacks = response.get("Stacks", [])
        require(len(stacks) == 1, "unexpected_stack_response")
        stack = stacks[0]
        tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
        require(tags.get("ecai:setup-id") == plan["operation_id"] and tags.get("ecai:plan-hash") == plan["plan_sha256"], "stack_ownership_mismatch")
        require(stack.get("StackName") == plan["stack_name"] and stack.get("StackId", "").startswith(
            f"arn:aws:cloudformation:{plan['region']}:{plan['account_id']}:stack/{plan['stack_name']}/"), "stack_identity_mismatch")
        return stack

    def deploy(self, args):
        plan = args["plan"]
        # Reusing this name+token must never deploy a second stack.
        stack = self.owned_stack(plan)
        if stack is None:
            response = self.cf.create_stack(StackName=plan["stack_name"], TemplateBody=canonical(plan["template"]),
                Capabilities=["CAPABILITY_NAMED_IAM"], OnFailure="ROLLBACK", TimeoutInMinutes=40,
                ClientRequestToken=plan["operation_id"], Tags=[
                    {"Key": "ecai:setup-id", "Value": plan["operation_id"]},
                    {"Key": "ecai:plan-hash", "Value": plan["plan_sha256"]}])
            return {"stack_id": response["StackId"], "stack_status": "CREATE_IN_PROGRESS", "events": []}
        return self.observe({"plan": plan})

    def observe(self, args):
        plan = args["plan"]
        stack = self.owned_stack(plan)
        if stack is None:
            return {"stack_status": "ABSENT", "events": []}
        state = stack["StackStatus"]
        result = {"stack_id": stack["StackId"], "stack_status": state, "events": []}
        # Fixed template has no secret parameters. Still omit status reasons,
        # physical IDs and full AWS events to avoid leaking other API values.
        events = self.cf.describe_stack_events(StackName=stack["StackId"]).get("StackEvents", [])[:30]
        result["events"] = [{"event_id": str(e.get("EventId", ""))[:256], "logical_id": str(e.get("LogicalResourceId", ""))[:256],
                             "status": str(e.get("ResourceStatus", ""))[:80], "resource_type": str(e.get("ResourceType", ""))[:128]} for e in events]
        if state == "CREATE_COMPLETE":
            # Detect out-of-band template changes before importing outputs.
            template = self.cf.get_template(StackName=stack["StackId"], TemplateStage="Original")["TemplateBody"]
            if isinstance(template, str):
                template = json.loads(template)
            require(template == plan["template"], "deployed_template_changed")
            outputs = {v["OutputKey"]: v["OutputValue"] for v in stack.get("Outputs", [])}
            validate_outputs(plan, outputs)
            result["outputs"] = {k: outputs[k] for k in ("RoleArn", "QueueArn", "JobDefinitionArn", "ProbeDefinitionArn", "Bucket", "LogGroup")}
        return result

    def delete(self, args):
        plan = args["plan"]
        stack = self.owned_stack(plan)
        if stack is None:
            return {"stack_status": "ABSENT", "events": []}
        state = stack["StackStatus"]
        require(state in ("CREATE_COMPLETE", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "CREATE_FAILED", "DELETE_FAILED", "DELETE_IN_PROGRESS"), "stack_not_deletable")
        if state != "DELETE_IN_PROGRESS":
            self.cf.delete_stack(StackName=stack["StackId"], ClientRequestToken="delete-" + plan["operation_id"])
        return {"stack_id": stack["StackId"], "stack_status": "DELETE_IN_PROGRESS", "events": []}

    def execute(self, action, args):
        require(action in ("plan", "deploy", "observe", "delete"), "unsupported_setup_action")
        return getattr(self, action)(args)

def validate_outputs(plan, outputs):
    connection = plan["connection"]
    base = f"arn:aws:batch:{plan['region']}:{plan['account_id']}:"
    require(outputs.get("RoleArn") == connection["role_arn"] and outputs.get("Bucket") == connection["bucket"], "unexpected_stack_outputs")
    require(outputs.get("QueueArn") == base + "job-queue/" + connection["job_queue"], "unexpected_queue_output")
    for key, name in (("JobDefinitionArn", connection["job_definition"]), ("ProbeDefinitionArn", plan["stack_name"] + "-probe")):
        require(re.fullmatch(re.escape(base + "job-definition/" + name) + r":\d+", outputs.get(key, "")) is not None, "unexpected_job_definition_output")
    require(outputs.get("LogGroup") == "/ecai/aws-setup/" + plan["operation_id"], "unexpected_log_output")

class Runtime:
    def __init__(self, request):
        self.plan = check_plan(request["plan"])
        self.outputs = request["outputs"]
        validate_outputs(self.plan, self.outputs)
        self.region = self.plan["region"]
        # Only node-supplied AWS credentials/providers can establish this role.
        node = boto3.Session(region_name=self.region)
        identity = public_identity(node, self.region)
        require(matches_coordinator(identity["caller_arn"], self.plan["coordinator_role_arn"]), "node_coordinator_identity_mismatch")
        response = client(node, "sts", self.region).assume_role(RoleArn=self.outputs["RoleArn"],
            ExternalId=self.plan["external_id"], RoleSessionName="ecai-runtime-check", DurationSeconds=900)
        c = response["Credentials"]
        self.session = boto3.Session(aws_access_key_id=c["AccessKeyId"], aws_secret_access_key=c["SecretAccessKey"], aws_session_token=c["SessionToken"], region_name=self.region)
        self.batch = client(self.session, "batch", self.region)
        self.s3 = client(self.session, "s3", self.region)

    def verify(self, args):
        queue = self.batch.describe_job_queues(jobQueues=[self.outputs["QueueArn"]]).get("jobQueues", [])
        require(len(queue) == 1 and queue[0].get("status") == "VALID" and queue[0].get("state") == "ENABLED", "batch_queue_not_ready")
        definitions = self.batch.describe_job_definitions(jobDefinitions=[self.outputs["JobDefinitionArn"]]).get("jobDefinitions", [])
        require(len(definitions) == 1 and definitions[0].get("status") == "ACTIVE", "batch_definition_not_active")
        require(definitions[0].get("containerProperties", {}).get("image") == self.plan["worker_image"], "worker_image_changed")
        self.s3.list_objects_v2(Bucket=self.outputs["Bucket"], Prefix="staging/", MaxKeys=1)
        return {"runtime_status": "verified", "checks": ["assumed_runtime_role", "queue_valid", "definition_active", "image_digest_matches", "staging_read_access"], "index_dispatch": "pending"}

    def probe_submit(self, args):
        nonce = args["probe_id"]
        require(re.fullmatch(r"[a-f0-9]{32}", nonce) is not None, "invalid_probe_id")
        self.verify({})
        payload = canonical({"schema": "ecai-aws-probe/v1", "nonce": nonce, "text": "ECAI synthetic AWS setup probe"}).encode()
        prefix = f"staging/setup-probe/{nonce}/"
        self.s3.put_object(Bucket=self.outputs["Bucket"], Key=prefix + "input.json", Body=payload, ContentType="application/json")
        # SubmitJob has no idempotency token. Disable SDK retries. The durable
        # coordinator fences this action before calling us and never auto-retries.
        job = client(self.session, "batch", self.region, no_retry=True).submit_job(
            jobName="ecai-probe-" + nonce, jobQueue=self.outputs["QueueArn"], jobDefinition=self.outputs["ProbeDefinitionArn"],
            containerOverrides={"environment": [{"name": "ECAI_PROBE_BUCKET", "value": self.outputs["Bucket"]}, {"name": "ECAI_PROBE_PREFIX", "value": prefix}]},
            tags={"ecai:setup-id": self.plan["operation_id"], "ecai:probe-id": nonce}, retryStrategy={"attempts": 1}, timeout={"attemptDurationSeconds": 300})
        return {"probe_id": nonce, "job_id": job["jobId"], "status": "SUBMITTED"}

    def probe_observe(self, args):
        probe = args["probe"]
        job_id = probe.get("job_id")
        # Reconcile an ambiguous submission by the pre-recorded name. Never
        # resubmit automatically just because a query returns no job yet.
        if not job_id:
            matches = self.batch.list_jobs(jobQueue=self.outputs["QueueArn"],
                filters=[{"name": "JOB_NAME", "values": ["ecai-probe-" + probe["probe_id"]]}], maxResults=100).get("jobSummaryList", [])
            exact = [j for j in matches if j.get("jobName") == "ecai-probe-" + probe["probe_id"]]
            require(len(exact) == 1, "probe_submission_needs_reconciliation")
            job_id = exact[0]["jobId"]
        jobs = self.batch.describe_jobs(jobs=[job_id]).get("jobs", [])
        require(len(jobs) == 1, "probe_job_not_found")
        job = jobs[0]
        require(job.get("tags", {}).get("ecai:setup-id") == self.plan["operation_id"] and job.get("tags", {}).get("ecai:probe-id") == probe["probe_id"] and job.get("jobQueue") == self.outputs["QueueArn"] and job.get("jobDefinition") == self.outputs["ProbeDefinitionArn"], "probe_job_identity_mismatch")
        status = job["status"]
        if status == "SUCCEEDED":
            key = f"staging/setup-probe/{probe['probe_id']}/output.json"
            response = self.s3.get_object(Bucket=self.outputs["Bucket"], Key=key)
            try:
                raw = response["Body"].read(4097)
            finally:
                response["Body"].close()
            require(len(raw) <= 4096, "probe_output_too_large")
            output = json.loads(raw)
            expected = canonical({"schema": "ecai-aws-probe/v1", "nonce": probe["probe_id"], "text": "ECAI synthetic AWS setup probe"}).encode()
            require(output.get("nonce") == probe["probe_id"] and output.get("input_sha256") == hashlib.sha256(expected).hexdigest(), "probe_output_verification_failed")
            status = "VERIFIED"
        return {"probe_id": probe["probe_id"], "job_id": job_id, "status": status}

    def execute(self, action, args):
        require(action in ("verify", "probe_submit", "probe_observe"), "unsupported_runtime_action")
        return getattr(self, action)(args)

def write(result):
    raw = canonical(result)
    require(len(raw.encode()) <= MAX_OUTPUT, "bridge_output_too_large")
    print(raw, flush=True)

def read():
    raw = sys.stdin.buffer.readline(MAX_INPUT + 1)
    if not raw:
        raise EOFError
    require(len(raw) <= MAX_INPUT and raw.endswith(b"\n"), "bridge_input_too_large")
    value = json.loads(raw)
    require(isinstance(value, dict), "invalid_bridge_input")
    return value

def watch_pipe():
    # Port closure kills the credential process even while an SDK call is
    # waiting on the network, rather than retaining a key until its next read.
    poller = select.poll()
    poller.register(sys.stdin.fileno(), select.POLLHUP | select.POLLERR)
    while True:
        if any(flags & (select.POLLHUP | select.POLLERR) for _fd, flags in poller.poll(1000)):
            os._exit(0)

def main():
    threading.Thread(target=watch_pipe, daemon=True).start()
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(0))
    # A dead client/forgotten session must not retain bootstrap credentials.
    signal.alarm(900)
    first = read()
    if first.get("mode") == "runtime":
        signal.alarm(60)
        runner = Runtime(first)
        write({"ok": True, "data": runner.execute(first["action"], first.get("args", {}))})
        return
    require(first.get("mode") == "bootstrap", "invalid_bridge_mode")
    runner = Bootstrap(first)
    # Remove the original duplicate dictionary promptly; boto3 still needs its
    # own in-memory copy. Python/BEAM cannot promise cryptographic zeroization.
    first.clear()
    write({"ok": True, "data": runner.identity})
    while True:
        try:
            command = read()
        except EOFError:
            return
        try:
            write({"ok": True, "data": runner.execute(command.get("action"), command.get("args", {}))})
        except Exception as exc:
            write({"ok": False, "error": error_code(exc)})

if __name__ == "__main__":
    try:
        main()
    except EOFError:
        pass
    except Exception as exc:
        write({"ok": False, "error": error_code(exc)})
