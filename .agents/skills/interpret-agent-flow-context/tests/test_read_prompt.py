import importlib.util
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('read_prompt', Path(__file__).parents[1]/'scripts/read-prompt.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class ReadPromptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def pair(self, stem='prompt', text='Exact words\r\n<typed_text> A & B </typed_text>\n'):
        source = self.root/(stem+'.md')
        source.write_bytes(text.encode())
        viewer = self.root/(stem+'.html')
        viewer.write_text(f'<meta content="{source}" name="agent-flow-source"><body>DO NOT READ'+('x'*100_000))
        return viewer, source, text

    def test_complete_canonical_text_is_preserved_not_viewer_body(self):
        viewer, source, text = self.pair()
        self.assertEqual(reader.read_prompts([str(viewer)]), [(source, text)])

    def test_shared_viewer_link_reads_markdown_without_a_running_server(self):
        folder = self.root / 'Library/Application Support/AgentFlow/Prompts'
        folder.mkdir(parents=True)
        name = 'prompt-00000000-0000-0000-0000-000000000000-11111111-1111-1111-1111-111111111111.md'
        raw = 'A <literal> timeline.\r\n'
        source = folder / name
        source.write_bytes(raw.encode())
        link = 'http://127.0.0.1:59343/index.html?prompt=' + name
        with patch.object(reader.Path, 'home', return_value=self.root):
            self.assertEqual(reader.read_prompts([link, str(source)]), [(source, raw)])
            for invalid in (
                link.replace('127.0.0.1', 'example.com'),
                link + '&prompt=' + name,
                link.replace(name, '%2e%2e%2fsecret.md'),
            ):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    reader.canonical_source(invalid)
            source.unlink()
            source.symlink_to(self.root / 'unrelated.md')
            with self.assertRaises(ValueError):
                reader.canonical_source(link)

    def test_single_document_reads_visual_payload_once_and_trailing_skills(self):
        viewer = self.root / 'one.html'
        viewer.write_text(
            '<meta name="agent-flow-document" content="1"><body><main>'
            '<section data-agent-flow-kind="speech"><div class="payload">'
            '<span class="rainbow-word">Ask</span> &amp; answer</div><details>'
            '<dl><dt>start_at</dt><dd>1.000</dd></dl></details></section>'
            '<section data-agent-flow-kind="codex_selection"><div class="payload">'
            '  &lt;literal&gt; &amp;amp; 😀\n  second line</div></section>'
            '<section data-agent-flow-kind="local_screenshot"><a>preview link</a>\n'
            '<img class="screenshot-image" src="data:image/jpeg;base64,PIXELS">\n'
            '<dl><dt>path</dt><dd>/local/Screenshot.png</dd></dl></section>'
            '</main><pre data-agent-flow-guidance="context">Use timeline order.</pre>'
            '<pre data-agent-flow-guidance="response">Use short cues.</pre>',
            encoding='utf-8',
        )
        [(path, text)] = reader.read_prompts([str(viewer), viewer.as_uri()])
        self.assertEqual(path, viewer)
        self.assertFalse(viewer.with_suffix('.md').exists())
        self.assertEqual(text.count('Ask &amp; answer'), 1)
        self.assertIn('<speech start_at="1.000">\n\nAsk &amp; answer', text)
        self.assertIn('  <text>  &lt;literal&gt; &amp;amp; 😀\n  second line</text>', text)
        self.assertIn('<local_screenshot path="/local/Screenshot.png"/>', text)
        self.assertNotIn('PIXELS', text)
        self.assertLess(text.index('Screenshot.png'), text.index('Use timeline order.'))
        self.assertLess(text.index('Use timeline order.'), text.index('Use short cues.'))

    def test_incomplete_single_document_is_rejected(self):
        viewer = self.root / 'one.html'
        viewer.write_text(
            '<meta name="agent-flow-document" content="1"><main>'
            '<section data-agent-flow-kind="speech"><div class="payload">unfinished',
            encoding='utf-8',
        )
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            reader.read_prompts([str(viewer)])

    def test_multiple_prompts_preserve_order_and_full_text(self):
        a = self.pair('first', '<speech>first</speech>')
        b = self.pair('second', '<speech>second</speech>')
        self.assertEqual(reader.read_prompts([str(b[0]), str(a[0])]), [(b[1],b[2]),(a[1],a[2])])

    def test_direct_markdown_is_supported(self):
        _, source, text = self.pair()
        self.assertEqual(reader.read_prompts([str(source)]), [(source,text)])

    def test_file_url_is_supported(self):
        viewer, source, text = self.pair('prompt with spaces')
        self.assertEqual(reader.read_prompts([viewer.as_uri()]), [(source,text)])

    def test_remote_file_url_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'local file'):
            reader.canonical_source('file://other-computer/prompt.html')

    def test_duplicate_links_read_one_archive(self):
        viewer, source, text = self.pair()
        self.assertEqual(reader.read_prompts([str(viewer),str(source)]), [(source,text)])

    def test_cli_marks_complete_output_and_line_continuation(self):
        viewer, source, text = self.pair(text='one\ntwo\nthree\n')
        script=Path(reader.__file__)
        result=subprocess.run([sys.executable,str(script),str(viewer)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertIn('lines: 1..3; complete\n'+text, result.stdout)
        self.assertTrue(result.stdout.endswith(f'END OF CANONICAL PROMPT: {source}\n'))
        result=subprocess.run([sys.executable,str(script),str(viewer),'--from-line','2'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertIn('lines: 2..3; continuation\ntwo\nthree\n',result.stdout)
        self.assertNotIn('DO NOT READ',result.stdout)

    def test_symlink_cannot_escape_archive_directory(self):
        viewer, source, _ = self.pair()
        with tempfile.TemporaryDirectory() as other:
            external=Path(other)/source.name
            external.write_text('unrelated')
            source.unlink()
            source.symlink_to(external)
            with self.assertRaisesRegex(ValueError,'matching'):
                reader.canonical_source(str(viewer))

    def test_percent_encoded_link_and_html_entities_decode_once(self):
        viewer, source, text = self.pair('prompt space &amp; literal')
        import html
        viewer.write_text(f'<meta name="agent-flow-source" content="{html.escape(str(source),quote=True)}"/>')
        self.assertEqual(reader.read_prompts([str(viewer).replace(' ', '%20')]), [(source,text)])

    def test_metadata_after_header_budget_is_not_read(self):
        viewer, source, _ = self.pair()
        viewer.write_text(' '*8192+f'<meta name="agent-flow-source" content="{source}">')
        with self.assertRaisesRegex(ValueError,'first 8 KiB'):
            reader.canonical_source(str(viewer))

    def test_duplicate_metadata_is_rejected(self):
        viewer, source, _ = self.pair()
        tag=f'<meta name="agent-flow-source" content="{source}">'
        viewer.write_text(tag+tag)
        with self.assertRaisesRegex(ValueError,'exactly one'):
            reader.canonical_source(str(viewer))

    def test_duplicate_content_attribute_is_rejected(self):
        viewer, source, _ = self.pair()
        viewer.write_text(f'<meta name="agent-flow-source" content="{source}" content="{source}">')
        with self.assertRaisesRegex(ValueError,'Ambiguous'):
            reader.canonical_source(str(viewer))

    def test_metadata_cannot_redirect_to_an_unrelated_markdown_file(self):
        viewer, _, _ = self.pair()
        unrelated=self.root/'unrelated.md'
        unrelated.write_text('unrelated private text')
        viewer.write_text(f'<meta name="agent-flow-source" content="{unrelated}">')
        with self.assertRaisesRegex(ValueError,'matching'):
            reader.canonical_source(str(viewer))

    def test_missing_second_prompt_fails_the_whole_batch(self):
        viewer, _, _ = self.pair()
        with self.assertRaises(FileNotFoundError):
            reader.read_prompts([str(viewer),str(self.root/'missing.md')])

    def test_relative_path_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'absolute'):
            reader.canonical_source('prompt.html')


if __name__ == '__main__':
    unittest.main()
