import importlib.util
from pathlib import Path
import unittest
import urllib.error

spec=importlib.util.spec_from_file_location('quorum',Path(__file__).with_name('quorum_exporter.py'))
quorum=importlib.util.module_from_spec(spec);spec.loader.exec_module(quorum)

class QuorumCollectorTests(unittest.TestCase):
    def rows(self, mutate=None):
        calls=[]
        def get(path):
            calls.append(path)
            if path=='nodes':return [{'running':True,'partitions':[]} for _ in range(3)]
            data={'type':'quorum','members':['a','b','c'],'online':['a','b','c'],'leader':'a'}
            if mutate:mutate(data)
            return data
        rows=quorum.sample(get)
        self.assertEqual(len(calls),4)
        self.assertTrue(all(p=='nodes' or p.startswith('queues/%2F/notification.delivery.') for p in calls))
        return rows

    def test_three_members_majority_two(self):
        rows=self.rows()
        self.assertTrue(all(v==2 for n,l,v in rows if n.endswith('required_majority')))
        self.assertEqual(sum(n.endswith('online_members') and v==3 for n,l,v in rows),3)

    def test_one_online_does_not_shrink_majority(self):
        rows=self.rows(lambda d:d.update(online=['a']))
        self.assertTrue(all(v==2 for n,l,v in rows if n.endswith('required_majority')))
        self.assertTrue(all(v==1 for n,l,v in rows if n.endswith('online_members')))

    def test_missing_online_is_unknown_not_healthy(self):
        with self.assertRaises(ValueError):self.rows(lambda d:d.pop('online'))

    def test_missing_members_is_unknown(self):
        with self.assertRaises(ValueError):self.rows(lambda d:d.update(members=[]))

    def test_classic_queue_is_not_declared_healthy_quorum(self):
        rows=self.rows(lambda d:d.update(type='classic'))
        self.assertEqual(sum(n.endswith('is_quorum') and v==0 for n,l,v in rows),3)
        self.assertFalse(any(n.endswith('online_members') for n,l,v in rows))

    def test_404_is_queue_absence_not_scrape_success(self):
        def get(path):
            if path=='nodes':return []
            raise urllib.error.HTTPError('http://local-only',404,'Not found',{},None)
        rows=quorum.sample(get)
        self.assertEqual(sum(n.endswith('present') and v==0 for n,l,v in rows),3)

    def test_unreachable_api_propagates_for_probe_failure(self):
        def get(path):raise TimeoutError('fixture')
        with self.assertRaises(TimeoutError):quorum.sample(get)

if __name__=='__main__':unittest.main()
