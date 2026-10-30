from pathlib import Path
import json
import sys
import time
import unittest
from unittest.mock import patch
from contextlib import nullcontext
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'infra'))
import service_monitor as monitor
import topology
from test_node_inventory import fixture


class ServiceMonitorTests(unittest.TestCase):
    def setUp(self):
        self.public=topology.load(Path(__file__).resolve().parents[1]/'infra/three-vps.example.json')
        self.config={'root':'/srv/voicechat-managed','public':self.public,'inventory':fixture()}

    def test_maintenance_does_not_hide_tls_disk_dns_or_missing_ssh(self):
        for failure in ('a_web_tls','core_disk','a_dns','core_ssh'):
            self.assertEqual(monitor.outcome({failure:'failed'},True),'failed')
        self.assertEqual(monitor.outcome({'core_matrix':'failed','a_route':'failed'},True),'maintenance')
        self.assertEqual(monitor.outcome({'core_matrix':'failed'},False),'failed')
        self.assertEqual(monitor.outcome({'core_matrix':'passed'},False),'healthy')

    def test_network_exceptions_are_redacted_and_expiry_alerts(self):
        self.assertEqual(monitor.probe(lambda: (_ for _ in ()).throw(ValueError('private-token'))),'failed')
        with patch.object(monitor.socket,'getaddrinfo',return_value=[(None,None,None,None,('192.0.2.99',443))]), \
             patch.object(monitor.entry_probe,'ready'), \
             patch.object(monitor.node_diagnostics,'tls',return_value={'status':'passed','renewal_due':True}), \
             patch.object(monitor,'inspect_core',side_effect=ValueError('private-token')):
            value=monitor.monitor(self.config,'/fixture/key')
        self.assertEqual(value['status'],'failed')
        self.assertEqual(value['checks']['b_dns'],'failed')
        self.assertEqual(value['checks']['b_web_tls'],'failed')
        self.assertEqual(value['checks']['core_ssh'],'failed')
        self.assertNotIn('private-token',json.dumps(value))

    def test_ssh_report_requires_identity_freshness_complete_checks_and_no_duplicate_keys(self):
        report={'schema':1,'node':'core','generation':1,'service_id':self.public['service_id'],
                'checked_at':int(time.time()),'checks':{name:{'status':'passed'} for name in
                ('network','matrix','control','core_processes','disk')}}
        value={'report':report,'maintenance':False}
        with patch.object(monitor.host_connection,'connection',return_value=nullcontext(['ssh','pinned'])), \
             patch.object(monitor.subprocess,'run') as run:
            run.return_value=SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
            self.assertEqual(monitor.inspect_core(self.config,'/fixture/key'),value)
            self.assertIn('python3 -B -c',run.call_args.args[0][-1])
            for key,bad in [('schema',True),('node','edge-b'),('generation',True),('generation',2),('checked_at',0),('checks',{})]:
                broken={'report':{**report,key:bad},'maintenance':False}
                run.return_value=SimpleNamespace(returncode=0,stdout=json.dumps(broken).encode())
                with self.assertRaises(ValueError):monitor.inspect_core(self.config,'/fixture/key')
            run.return_value=SimpleNamespace(returncode=0,stdout=b'{"report":{},"report":{},"maintenance":false}')
            with self.assertRaises(ValueError):monitor.inspect_core(self.config,'/fixture/key')
            run.return_value=SimpleNamespace(returncode=0,stdout=b'x'*65537)
            with self.assertRaises(ValueError):monitor.inspect_core(self.config,'/fixture/key')
