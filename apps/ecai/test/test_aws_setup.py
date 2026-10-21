"""Offline AWS provisioning tests. No live AWS requests or credentials required."""
from __future__ import annotations
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP / 'priv/aws_setup'))
import template
import bridge
import boto3
from botocore.stub import Stubber
from botocore.exceptions import ClientError

CONFIG = {'coordinator_role_arn':'arn:aws:iam::210987654321:role/EcaiCoordinator',
          'worker_image':'123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/ecai-worker@sha256:'+'a'*64,
          'worker_command':['/opt/ecai/run-index-worker'], 'regions':['ap-southeast-2'], 'probe_enabled':True}
REQUEST = {'operation_id':'1'*32, 'account_id':'123456789012', 'region':'ap-southeast-2',
           'external_id':'a'*48, 'config':CONFIG, 'options':{}}
PLAN = template.make_plan(REQUEST)
BASE = 'arn:aws:batch:ap-southeast-2:123456789012:'
OUTPUTS = {'RoleArn':PLAN['connection']['role_arn'], 'QueueArn':BASE+'job-queue/'+PLAN['connection']['job_queue'],
           'JobDefinitionArn':BASE+'job-definition/'+PLAN['connection']['job_definition']+':1',
           'ProbeDefinitionArn':BASE+'job-definition/'+PLAN['stack_name']+'-probe:1',
           'Bucket':PLAN['connection']['bucket'], 'LogGroup':'/ecai/aws-setup/'+'1'*32}
STACK_ID = 'arn:aws:cloudformation:ap-southeast-2:123456789012:stack/'+PLAN['stack_name']+'/00000000-0000-0000-0000-000000000000'

def fake_client(service):
    # Explicit dummy credentials avoid IMDS/provider-chain lookup even before
    # botocore Stubber is installed on the client.
    return boto3.Session(aws_access_key_id='AKIA'+'A'*16, aws_secret_access_key='S'*40,
                         region_name='ap-southeast-2').client(service, endpoint_url='https://'+service+'.ap-southeast-2.amazonaws.com')

def bootstrap(cf):
    obj = bridge.Bootstrap.__new__(bridge.Bootstrap)
    obj.identity = {'account_id':'123456789012', 'caller_arn':'arn:aws:iam::123456789012:user/Setup'}
    obj.region = 'ap-southeast-2'; obj.config = CONFIG; obj.cf = cf
    return obj

def stack(status='CREATE_COMPLETE', **overrides):
    import datetime
    return {'StackId':STACK_ID, 'StackName':PLAN['stack_name'], 'CreationTime':datetime.datetime(2026, 1, 1),
            'StackStatus':status, 'Tags':[{'Key':'ecai:setup-id','Value':PLAN['operation_id']},
                                        {'Key':'ecai:plan-hash','Value':PLAN['plan_sha256']}],
            'Outputs':[{'OutputKey':key,'OutputValue':value} for key,value in OUTPUTS.items()], **overrides}

class TemplateTests(unittest.TestCase):
    def test_plan_is_stable_and_tamper_evident(self):
        self.assertEqual(PLAN, template.make_plan(copy.deepcopy(REQUEST)))
        self.assertIs(template.check_plan(PLAN), PLAN)
        changed = copy.deepcopy(PLAN); changed['connection']['bucket']='other'
        with self.assertRaisesRegex(ValueError, 'plan_hash_mismatch'): template.check_plan(changed)

    def test_structure_and_independent_roles(self):
        resources=PLAN['template']['Resources']
        self.assertEqual(len([r for r in resources.values() if r['Type']=='AWS::IAM::Role']),3)
        self.assertNotIn('AWS::EC2::NatGateway', [r['Type'] for r in resources.values()])
        trust=resources['RuntimeRole']['Properties']['AssumeRolePolicyDocument']['Statement'][0]
        self.assertEqual(trust['Principal']['AWS'],CONFIG['coordinator_role_arn'])
        self.assertEqual(trust['Condition']['StringEquals']['sts:ExternalId'],'a'*48)
        self.assertEqual(resources['Workers']['Properties']['SecurityGroupIngress'],[])
        self.assertEqual(resources['Artifacts']['DeletionPolicy'],'Retain')
        self.assertEqual(resources['ArtifactPolicy']['DeletionPolicy'],'Retain')
        self.assertTrue(all(resources['Artifacts']['Properties']['PublicAccessBlockConfiguration'].values()))

    def test_worker_and_probe_are_bounded_and_contain_no_setup_keys(self):
        resources=PLAN['template']['Resources']
        for name in ['WorkerDefinition','ProbeDefinition']:
            job=resources[name]['Properties']
            self.assertEqual(job['RetryStrategy']['Attempts'],1)
            self.assertEqual(job['ContainerProperties']['Image'],CONFIG['worker_image'])
            self.assertEqual(job['ContainerProperties']['NetworkConfiguration']['AssignPublicIp'],'ENABLED')
            self.assertNotIn('Environment',job['ContainerProperties'])
        self.assertEqual(resources['ProbeDefinition']['Properties']['Timeout']['AttemptDurationSeconds'],300)
        raw=template.canonical(PLAN)
        for key in ['secret_access_key','session_token','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY']:self.assertNotIn(key,raw)

    def test_invalid_options_fail_instead_of_silent_clamping(self):
        for opts in [{'max_vcpus':True},{'max_vcpus':16},{'profile':'gpu'}, {'profile':'cpu-medium','max_vcpus':1},
                     {'job_timeout_seconds':299},{'log_retention_days':365}, {'template_url':'https://attacker.test/x'}]:
            with self.subTest(options=opts), self.assertRaises(ValueError): template.make_plan({**REQUEST,'options':opts})

    def test_unpinned_image_wildcard_trust_and_unknown_region_rejected(self):
        for cfg in [{**CONFIG,'worker_image':'worker:latest'}, {**CONFIG,'coordinator_role_arn':'*'}, {**CONFIG,'worker_command':[]}]:
            with self.assertRaises(ValueError): template.make_plan({**REQUEST,'config':cfg})
        with self.assertRaises(ValueError): template.make_plan({**REQUEST,'region':'cn-north-1'})

    def test_resources_names_are_unique_and_within_aws_limits(self):
        other=template.make_plan({**REQUEST,'operation_id':'2'*32})
        self.assertNotEqual(PLAN['connection']['bucket'],other['connection']['bucket'])
        self.assertLessEqual(len(PLAN['connection']['bucket']),63)
        for r in PLAN['template']['Resources'].values():
            if r['Type']=='AWS::IAM::Role': self.assertLessEqual(len(r['Properties']['RoleName']),64)
        self.assertLess(len(template.canonical(PLAN['template'])),51200)

    def test_no_unrestricted_runtime_write_policies(self):
        statements=PLAN['template']['Resources']['RuntimeRole']['Properties']['Policies'][0]['PolicyDocument']['Statement']
        for s in statements:
            if s['Resource']==['*']:
                self.assertTrue(all(a.startswith(('batch:Describe','batch:List')) for a in s['Action']))
        self.assertFalse(any('iam:PassRole' in s['Action'] or 'cloudformation:CreateStack' in s['Action'] for s in statements))

class CredentialTests(unittest.TestCase):
    def test_explicit_credentials_only_and_temporary_token_required(self):
        with patch.object(bridge.boto3,'Session') as session:
            bridge.session_from_credentials({'access_key_id':'AKIA'+'A'*16,'secret_access_key':'S'*40})
            session.assert_called_once_with(aws_access_key_id='AKIA'+'A'*16,aws_secret_access_key='S'*40,aws_session_token=None)
        with self.assertRaisesRegex(ValueError,'session_token_required'):
            bridge.session_from_credentials({'access_key_id':'ASIA'+'A'*16,'secret_access_key':'S'*40})
        with self.assertRaisesRegex(ValueError,'invalid_aws_credentials'):
            bridge.session_from_credentials({'access_key_id':'AKIA'+'A'*16,'secret_access_key':'S'*40,'endpoint_url':'https://evil.test'})

    def test_root_identity_rejected(self):
        sts=fake_client('sts')
        with Stubber(sts) as stub, patch.object(bridge,'client',return_value=sts):
            stub.add_response('get_caller_identity',{'Account':'123456789012','Arn':'arn:aws:iam::123456789012:root','UserId':'root'}, {})
            with self.assertRaisesRegex(ValueError,'root_credentials_rejected'): bridge.public_identity(object(),'ap-southeast-2')

    def test_identity_does_not_claim_provisioning_permissions(self):
        sts=fake_client('sts')
        with Stubber(sts) as stub, patch.object(bridge,'client',return_value=sts):
            stub.add_response('get_caller_identity',{'Account':'123456789012','Arn':'arn:aws:iam::123456789012:user/Setup','UserId':'setup'}, {})
            result=bridge.public_identity(object(),'ap-southeast-2')
            self.assertEqual(set(result),{'account_id','caller_arn'})

    def test_error_redaction(self):
        secret='THIS_IS_A_FAKE_TEST_SECRET'
        exc=ClientError({'Error':{'Code':'AccessDenied','Message':secret},'ResponseMetadata':{'HTTPHeaders':{'x-secret':secret}}},'CreateStack')
        self.assertEqual(bridge.error_code(exc),'AccessDenied')
        self.assertEqual(bridge.error_code(RuntimeError(secret)),'aws_setup_failed')
        exc=ClientError({'Error':{'Code':secret,'Message':secret}},'CreateStack')
        self.assertEqual(bridge.error_code(exc),'aws_api_error')

    def test_endpoints_and_retry_policy_cannot_be_overridden_by_request(self):
        session=Mock()
        bridge.client(session,'batch','ap-southeast-2',no_retry=True)
        kwargs=session.client.call_args.kwargs
        self.assertEqual(kwargs['endpoint_url'],'https://batch.ap-southeast-2.amazonaws.com')
        self.assertEqual(kwargs['config'].retries['total_max_attempts'],1)
        self.assertTrue(kwargs['config'].ignore_configured_endpoint_urls)
        self.assertEqual(kwargs['config'].proxies,{})

    def test_node_role_matching_is_account_and_role_specific(self):
        expected=CONFIG['coordinator_role_arn']
        self.assertTrue(bridge.matches_coordinator('arn:aws:sts::210987654321:assumed-role/EcaiCoordinator/session',expected))
        self.assertFalse(bridge.matches_coordinator('arn:aws:sts::123456789012:assumed-role/EcaiCoordinator/session',expected))
        self.assertFalse(bridge.matches_coordinator('arn:aws:sts::210987654321:assumed-role/Other/session',expected))
        self.assertFalse(bridge.matches_coordinator('arn:aws:iam::210987654321:root',expected))

class CloudFormationTests(unittest.TestCase):
    def test_create_stack_uses_approved_template_and_stable_request_token(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_client_error('describe_stacks','ValidationError','Stack does not exist',expected_params={'StackName':PLAN['stack_name']})
            stub.add_response('create_stack',{'StackId':STACK_ID},{'StackName':PLAN['stack_name'],'TemplateBody':template.canonical(PLAN['template']),
                'Capabilities':['CAPABILITY_NAMED_IAM'],'OnFailure':'ROLLBACK','TimeoutInMinutes':40,'ClientRequestToken':PLAN['operation_id'],
                'Tags':[{'Key':'ecai:setup-id','Value':PLAN['operation_id']},{'Key':'ecai:plan-hash','Value':PLAN['plan_sha256']}]})
            self.assertEqual(runner.deploy({'plan':PLAN})['stack_status'],'CREATE_IN_PROGRESS')
            stub.assert_no_pending_responses()

    def test_permission_denial_is_not_treated_as_absent_stack(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_client_error('describe_stacks','AccessDenied','Denied',expected_params={'StackName':PLAN['stack_name']})
            with self.assertRaises(ClientError): runner.deploy({'plan':PLAN})

    def test_reconcile_in_progress_does_not_create_again(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            for _ in range(2): stub.add_response('describe_stacks',{'Stacks':[stack('CREATE_IN_PROGRESS')]},{'StackName':PLAN['stack_name']})
            stub.add_response('describe_stack_events',{'StackEvents':[]},{'StackName':STACK_ID})
            self.assertEqual(runner.deploy({'plan':PLAN})['stack_status'],'CREATE_IN_PROGRESS')
            stub.assert_no_pending_responses()

    def test_foreign_or_modified_stack_is_never_adopted(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_response('describe_stacks',{'Stacks':[stack(Tags=[])]},{'StackName':PLAN['stack_name']})
            with self.assertRaisesRegex(ValueError,'stack_ownership_mismatch'): runner.owned_stack(PLAN)

    def test_account_mismatch_fails_before_cloud_call(self):
        runner=bootstrap(Mock()); runner.identity['account_id']='999999999999'
        with self.assertRaisesRegex(ValueError,'aws_account_or_region_mismatch'): runner.owned_stack(PLAN)
        runner.cf.describe_stacks.assert_not_called()

    def test_success_imports_only_expected_outputs_and_template(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_response('describe_stacks',{'Stacks':[stack()]},{'StackName':PLAN['stack_name']})
            stub.add_response('describe_stack_events',{'StackEvents':[]},{'StackName':STACK_ID})
            stub.add_response('get_template',{'TemplateBody':template.canonical(PLAN['template'])},{'StackName':STACK_ID,'TemplateStage':'Original'})
            result=runner.observe({'plan':PLAN})
            self.assertEqual(result['outputs'],OUTPUTS)
            self.assertNotIn('Credentials',template.canonical(result))

    def test_changed_template_fails_before_import(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_response('describe_stacks',{'Stacks':[stack()]},{'StackName':PLAN['stack_name']})
            stub.add_response('describe_stack_events',{'StackEvents':[]},{'StackName':STACK_ID})
            stub.add_response('get_template',{'TemplateBody':'{}'},{'StackName':STACK_ID,'TemplateStage':'Original'})
            with self.assertRaisesRegex(ValueError,'deployed_template_changed'): runner.observe({'plan':PLAN})

    def test_output_arn_and_bucket_tampering_is_rejected(self):
        bridge.validate_outputs(PLAN,OUTPUTS)
        for key in OUTPUTS:
            with self.subTest(key=key),self.assertRaises(ValueError): bridge.validate_outputs(PLAN,{**OUTPUTS,key:'unexpected'})

    def test_delete_only_uses_recorded_owned_stack(self):
        cf=fake_client('cloudformation'); runner=bootstrap(cf)
        with Stubber(cf) as stub:
            stub.add_response('describe_stacks',{'Stacks':[stack()]},{'StackName':PLAN['stack_name']})
            stub.add_response('delete_stack',{}, {'StackName':STACK_ID,'ClientRequestToken':'delete-'+PLAN['operation_id']})
            self.assertEqual(runner.delete({'plan':PLAN})['stack_status'],'DELETE_IN_PROGRESS')

class RuntimeProbeTests(unittest.TestCase):
    def runner(self):
        runner=bridge.Runtime.__new__(bridge.Runtime)
        runner.plan=PLAN;runner.outputs=OUTPUTS;runner.region=PLAN['region'];runner.session=Mock()
        runner.batch=Mock();runner.s3=Mock()
        return runner

    def test_verified_probe_checks_nonce_and_expected_hash(self):
        runner=self.runner();probe={'probe_id':'b'*32,'job_id':'job-test'}
        runner.batch.describe_jobs.return_value={'jobs':[{'jobId':'job-test','status':'SUCCEEDED','tags':{'ecai:setup-id':PLAN['operation_id'],'ecai:probe-id':probe['probe_id']},'jobQueue':OUTPUTS['QueueArn'],'jobDefinition':OUTPUTS['ProbeDefinitionArn']}]}
        payload=template.canonical({'schema':'ecai-aws-probe/v1','nonce':probe['probe_id'],'text':'ECAI synthetic AWS setup probe'}).encode()
        stream=io.BytesIO(json.dumps({'nonce':probe['probe_id'],'input_sha256':hashlib.sha256(payload).hexdigest()}).encode())
        runner.s3.get_object.return_value={'Body':stream}
        self.assertEqual(runner.probe_observe({'probe':probe})['status'],'VERIFIED')
        self.assertTrue(stream.closed)

    def test_bad_probe_output_is_not_success(self):
        runner=self.runner();probe={'probe_id':'b'*32,'job_id':'job-test'}
        runner.batch.describe_jobs.return_value={'jobs':[{'status':'SUCCEEDED','tags':{'ecai:setup-id':PLAN['operation_id'],'ecai:probe-id':probe['probe_id']},'jobQueue':OUTPUTS['QueueArn'],'jobDefinition':OUTPUTS['ProbeDefinitionArn']}]}
        runner.s3.get_object.return_value={'Body':io.BytesIO(b'{"nonce":"wrong","input_sha256":"wrong"}')}
        with self.assertRaisesRegex(ValueError,'probe_output_verification_failed'): runner.probe_observe({'probe':probe})

    def test_ambiguous_submission_is_not_retried(self):
        runner=self.runner(); runner.batch.list_jobs.return_value={'jobSummaryList':[]}
        with self.assertRaisesRegex(ValueError,'probe_submission_needs_reconciliation'): runner.probe_observe({'probe':{'probe_id':'b'*32}})
        runner.batch.submit_job.assert_not_called()

    def test_submit_passes_no_customer_keys_and_has_one_attempt(self):
        runner=self.runner();runner.verify=Mock(return_value={});runner.batch.submit_job.return_value={'jobId':'job-test'}
        with patch.object(bridge,'client',return_value=runner.batch) as factory:
            result=runner.probe_submit({'probe_id':'b'*32})
        self.assertEqual(result['status'],'SUBMITTED')
        self.assertTrue(factory.call_args.kwargs['no_retry'])
        params=runner.batch.submit_job.call_args.kwargs
        self.assertEqual(params['retryStrategy'],{'attempts':1})
        self.assertEqual(params['timeout'],{'attemptDurationSeconds':300})
        env={v['name']:v['value'] for v in params['containerOverrides']['environment']}
        self.assertEqual(set(env),{'ECAI_PROBE_BUCKET','ECAI_PROBE_PREFIX'})

class SourceContractTests(unittest.TestCase):
    def test_scoped_auth_and_credential_boundary(self):
        source=(APP/'src/ecai_aws_setup_http.erl').read_text()
        for required in ['process_flag(sensitive, true)','explicit_bearer_required','auth_mode := custodial',
                         'aws_setup_trusted_proxy_ips','https_same_origin_required','16384','<<"cache-control">> => <<"no-store">>']:
            self.assertIn(required,source)
        session_source=(APP/'src/ecai_aws_setup_session.erl').read_text()
        self.assertNotIn('os:putenv',session_source)
        self.assertNotIn('stderr_to_stdout',session_source)
        self.assertIn('{args, ["-I", "-u", ecai_aws_setup_config:script()]}',session_source)
        self.assertIn('redacted',session_source)

    def test_ui_routes_and_assets_are_wired(self):
        js=(APP/'priv/static/js/ecai-aws-setup.js').read_text()
        fragment=(APP/'priv/templates/ui/dashboard/compute_settings.mustache').read_text()
        shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        import re
        ids=set(re.findall(r'id="([^"]+)"',fragment))
        for name in re.findall(r"\$\('([^']+)'\)",js):self.assertIn(name,ids)
        for path in ['css/ecai-aws-setup.css','js/ecai-aws-setup.js']:
            self.assertIn('/static/'+path+'?v=automatic-aws-v1',shell)
        for token in ['localStorage','sessionStorage','innerHTML']:
            self.assertNotIn(token,js)
        self.assertIn('currentToken',js)
        self.assertIn('clearSecrets()',js)
        self.assertIn('epoch !== generation',js)
        self.assertIn('computeAwsManual',fragment)

if __name__=='__main__':unittest.main(verbosity=2)
