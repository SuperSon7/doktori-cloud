import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("check_plan", Path(__file__).with_name("check-plan.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def plan(address, actions):
    return {"resource_changes": [{"address": address, "change": {"actions": actions}}]}


class PlanReviewTest(unittest.TestCase):
    def test_adding_peer_is_allowed(self):
        self.assertEqual([], module.rejected_changes(plan('module.data_compute.aws_instance.this["redis_c"]', ["create"])))

    def test_replacing_primary_is_rejected_in_either_order(self):
        for actions in (["delete", "create"], ["create", "delete"]):
            with self.subTest(actions=actions):
                self.assertTrue(module.rejected_changes(plan('module.data_compute.aws_instance.this["mongodb"]', actions)))

    def test_shrinking_cluster_is_rejected(self):
        self.assertTrue(module.rejected_changes(plan('module.data_compute.aws_instance.this["rabbitmq_b"]', ["delete"])))

    def test_other_layers_are_not_this_gates_scope(self):
        self.assertEqual([], module.rejected_changes(plan("module.storage.aws_s3_bucket.this", ["delete"])))

    def test_missing_or_unknown_actions_fail_closed(self):
        with self.assertRaises(ValueError):
            module.rejected_changes({})
        with self.assertRaises(ValueError):
            module.rejected_changes(plan("module.data_compute.aws_instance.this", []))
        self.assertTrue(module.rejected_changes(plan("module.data_compute.aws_instance.this", ["future-action"])))


if __name__ == "__main__":
    unittest.main()
