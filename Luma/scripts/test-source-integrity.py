#!/usr/bin/env python3
"""Regression tests for cross-platform hashes; does not compile or simulate Swift."""
from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('luma_integrity', ROOT/'scripts/check-preserved-sources.py')
integrity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrity)

class SourceIntegrityTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT/'.build/source-integrity-tests'
        parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def row(self, path, content, mode='lf-text'):
        return {'path':path, 'hash_mode':mode, 'sha256':integrity.hash_content(content,mode)}

    def put(self, path, content):
        target = self.root/path
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(content)

    def test_crlf_and_lf_accept_the_same_source(self):
        body='let title = "Сон"\nlet seconds = 4\n'.encode()
        self.put('Cue.swift',body.replace(b'\n',b'\r\n'))
        self.assertTrue(integrity.verify_file(self.root,self.row('Cue.swift',body))['unchanged'])

    def test_mixed_line_endings_accept_the_same_source(self):
        self.put('Cue.swift',b'let a = 1\nlet b = 2\r\n')
        self.assertTrue(integrity.verify_file(self.root,self.row('Cue.swift',b'let a = 1\nlet b = 2\n'))['unchanged'])

    def test_changed_source_value_is_still_rejected(self):
        self.put('Cue.swift',b'let seconds = 40\n')
        self.assertFalse(integrity.verify_file(self.root,self.row('Cue.swift',b'let seconds = 4\n'))['unchanged'])

    def test_whitespace_changes_are_not_hidden(self):
        self.put('Cue.swift',b'let  seconds = 4\n')
        self.assertFalse(integrity.verify_file(self.root,self.row('Cue.swift',b'let seconds = 4\n'))['unchanged'])

    def test_binary_crlf_bytes_are_never_normalized(self):
        raw=b'RIFF\x00\xff\r\n\x00DATA'
        self.put('tone.wav',raw.replace(b'\r\n',b'\n'))
        self.assertFalse(integrity.verify_file(self.root,self.row('tone.wav',raw,'raw'))['unchanged'])

    def test_binary_cannot_opt_into_text_normalization(self):
        raw=b'RIFF\r\n'
        self.put('tone.wav',raw)
        result=integrity.verify_file(self.root,self.row('tone.wav',raw,'lf-text'))
        self.assertFalse(result['unchanged'])
        self.assertIn('forbidden',result['error'])

    def test_unknown_modes_fail_closed(self):
        self.put('Cue.swift',b'x')
        result=integrity.verify_file(self.root,{'path':'Cue.swift','hash_mode':'ignore','sha256':'0'})
        self.assertFalse(result['unchanged'])
        self.assertIn('Unsupported',result['error'])

    def test_missing_file_fails(self):
        self.assertFalse(integrity.verify_file(self.root,self.row('missing.swift',b'x'))['unchanged'])

    def test_old_manifest_keeps_raw_byte_behavior(self):
        raw=b'let seconds = 4\r\n'
        self.put('Cue.swift',raw)
        item={'path':'Cue.swift','sha256':hashlib.sha256(raw).hexdigest()}
        self.assertTrue(integrity.verify_file(self.root,item)['unchanged'])
        self.put('Cue.swift',raw.replace(b'\r\n',b'\n'))
        self.assertFalse(integrity.verify_file(self.root,item)['unchanged'])

    def test_paths_cannot_escape_project(self):
        result=integrity.verify_file(self.root,{'path':'../outside.swift','sha256':'0'})
        self.assertFalse(result['unchanged'])
        self.assertIn('outside',result['error'])

    def test_bom_or_encoding_change_is_not_hidden(self):
        self.put('Cue.swift',b'\xef\xbb\xbflet a = 1\n')
        self.assertFalse(integrity.verify_file(self.root,self.row('Cue.swift',b'let a = 1\n'))['unchanged'])

    def test_schema_requires_explicit_modes(self):
        with self.assertRaises(ValueError):
            integrity.verify_manifest(self.root,{'schema':2,'files':[{'path':'a.swift','sha256':'0'}]})

    def test_project_manifest_survives_both_git_checkout_styles(self):
        manifest=json.loads((ROOT/'Docs/preserved-sources.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(manifest['schema'],2)
        for style in ['LF','CRLF']:
            with self.subTest(style=style):
                checkout=self.root/style
                for item in manifest['files']:
                    content=(ROOT/item['path']).read_bytes()
                    if item['hash_mode']=='lf-text':
                        content=content.replace(b'\r\n',b'\n')
                        if style=='CRLF':
                            content=content.replace(b'\n',b'\r\n')
                    target=checkout/item['path']
                    target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(content)
                failed=[r for r in integrity.verify_manifest(checkout,manifest) if not r['unchanged']]
                self.assertEqual(failed,[])

if __name__ == '__main__':
    unittest.main(verbosity=2)
