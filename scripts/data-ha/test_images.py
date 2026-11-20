"""Artifact handoff safety tests; no Packer build, AWS or Terraform calls."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('images', Path(__file__).with_name('images.py'))
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


class ArtifactHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for index, service in enumerate(images.SERVICES):
            self.write(service, {
                'last_run_uuid': 'current',
                'builds': [{'packer_run_uuid': 'current', 'builder_type': 'amazon-ebs',
                            'artifact_id': f'ap-northeast-2:ami-{index+1:017x}',
                            'custom_data': {'data_ha_service': service, 'architecture': 'arm64',
                                            'base_ami': 'ami-00000000000000009'}}]})

    def write(self, service, data):
        (self.root / f'manifest-{service}.json').write_text(json.dumps(data), encoding='utf-8')

    def change(self, field, value):
        path = self.root / 'manifest-rabbitmq.json'
        data = json.loads(path.read_text())
        data['builds'][0][field] = value
        self.write('rabbitmq', data)

    def export(self, through='mongodb', output='review.tfvars.json'):
        return images.export_inputs(self.root, 'ap-northeast-2', through, self.root / output)

    def assert_rejected(self):
        with self.assertRaises(ValueError):
            self.export()
        self.assertFalse((self.root / 'review.tfvars.json').exists())

    def test_complete_stage_has_three_distinct_images_and_flags(self):
        result = self.export()
        self.assertEqual(len(result['ha_ami_ids']), 3)
        self.assertTrue(all(result[f'enable_{s}_ha'] for s in images.SERVICES))
        self.assertFalse(result['allow_redis_initial_primary'])

    def test_redis_only_does_not_enable_later_services(self):
        result = self.export('redis')
        self.assertEqual(list(result['ha_ami_ids']), ['redis'])
        self.assertFalse(result['enable_rabbitmq_ha'])
        self.assertFalse(result['enable_mongodb_ha'])

    def test_wrong_region_rejected_before_writing(self):
        self.change('artifact_id', 'us-east-1:ami-00000000000000002')
        self.assert_rejected()

    def test_stale_run_rejected(self):
        self.change('packer_run_uuid', 'older-run')
        self.assert_rejected()

    def test_wrong_service_or_architecture_rejected(self):
        self.change('custom_data', {'data_ha_service': 'mongodb', 'architecture': 'amd64'})
        self.assert_rejected()

    def test_non_ami_builder_rejected(self):
        self.change('builder_type', 'docker')
        self.assert_rejected()

    def test_same_image_for_different_services_rejected(self):
        self.change('artifact_id', 'ap-northeast-2:ami-00000000000000001')
        self.assert_rejected()

    def test_existing_review_file_preserved(self):
        path = self.root / 'review.tfvars.json'
        path.write_text('preserve me')
        with self.assertRaises(FileExistsError):
            self.export()
        self.assertEqual(path.read_text(), 'preserve me')

    def test_autoload_filename_rejected(self):
        for name in ('unsafe.auto.tfvars.json', 'unsafe.auto.tfvars', 'terraform.tfvars.json', 'terraform.tfvars'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.export(output=name)
            self.assertFalse((self.root / name).exists())

    def test_build_does_not_execute_without_cloud_flag(self):
        import contextlib
        import io
        from unittest.mock import patch
        with patch('sys.argv', ['images.py', 'build']), patch.object(images, 'invoke') as invoke, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                images.main()
            self.assertEqual(result.exception.code, 2)
            invoke.assert_not_called()
