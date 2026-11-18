#!/usr/bin/env python3
"""Read the prompt and trailing skills from an Agent Flow link. Older links resolve their matching Markdown archive."""

import argparse
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, unquote, urlsplit


PROMPT_NAME = re.compile(r'prompt-(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-){1}'
                         r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.md')


class SourceMetadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sources = []
        self.documents = []

    def handle_starttag(self, tag, attrs):
        if tag != 'meta':
            return
        names = [value for key, value in attrs if key == 'name']
        values = [value for key, value in attrs if key == 'content']
        if 'agent-flow-document' in names:
            if names != ['agent-flow-document'] or values != ['1']:
                raise ValueError('Unsupported Agent Flow document format')
            self.documents.append(values[0])
            return
        if 'agent-flow-source' not in names:
            return
        if len(names) != 1 or len(values) != 1 or not values[0]:
            raise ValueError('Ambiguous Agent Flow source metadata')
        self.sources.append(values[0])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)



class PromptDocument(HTMLParser):
    """Unwrap the visible timeline and trailing skills without a second text copy."""

    authored = {'speech', 'speech_segment', 'typed_text', 'potential_tts'}
    selections = {'app_selection', 'codex_selection'}
    images = {'local_screenshot', 'app_selection_image'}
    plain = {'opening', 'text'}
    skill_headings = {
        'context': (
            'Agent Flow interpretation guidance for this prompt',
            'Use this copy to interpret the prompt. The skill is supplied here. '
            'Its setup and maintenance steps do not apply to this reply.',
        ),
        'response': (
            'Response preferences for this reply',
            'Apply these supplied response preferences. Use this copy for the '
            'skill’s instructions.',
        ),
    }

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.events = []
        self.skills = {}
        self.kind = None
        self.attributes = {}
        self.field = None
        self.parts = []
        self.payload = ''
        self.key = None
        self.main_ended = False
        self.skill = None

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'section' and 'data-agent-flow-kind' in values:
            kind = values['data-agent-flow-kind']
            if self.kind or self.main_ended or kind not in self.authored | self.selections | self.images | self.plain:
                raise ValueError('Invalid Agent Flow timeline event')
            self.kind = kind
            self.attributes = {}
            self.payload = ''
            self.key = None
        elif self.kind and (tag in ('dt', 'dd') or tag == 'div' and values.get('class') == 'payload'):
            self.field = tag
            self.parts = []
        elif tag == 'pre' and 'data-agent-flow-guidance' in values:
            self.skill = values['data-agent-flow-guidance']
            if (not self.main_ended or self.field or self.skill in self.skills
                    or self.skill not in self.skill_headings):
                raise ValueError('Invalid Agent Flow guidance section')
            self.field = tag
            self.parts = []

    def handle_data(self, data):
        if self.field:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == self.field:
            value = ''.join(self.parts)
            self.field = None
            if tag == 'div':
                self.payload = value
            elif tag == 'dt':
                self.key = value
            elif tag == 'dd':
                if not self.key or self.key in self.attributes:
                    raise ValueError('Invalid Agent Flow timeline attributes')
                self.attributes[self.key] = value
                self.key = None
            elif tag == 'pre':
                self.skills[self.skill] = value
                self.skill = None
        if tag == 'section' and self.kind:
            self.events.append(self.event_xml())
            self.kind = None
        if tag == 'main':
            self.main_ended = True

    def event_xml(self):
        kind = self.kind
        if kind in self.plain:
            return self.payload
        attributes = ''.join(f' {key}="{escape(value, quote=True)}"'
                             for key, value in self.attributes.items())
        if kind in self.images:
            return f'<{kind}{attributes}/>'
        payload = escape(self.payload, quote=False)
        if kind in self.selections:
            return f'<{kind}{attributes}>\n  <text>{payload}</text>\n</{kind}>'
        return f'<{kind}{attributes}>\n\n{payload}\n\n</{kind}>'

    def prompt(self):
        if not self.main_ended or self.kind or self.skill or self.field:
            raise ValueError('Incomplete Agent Flow document')
        parts = list(self.events)
        for skill, text in self.skills.items():
            heading, instructions = self.skill_headings[skill]
            parts.append(f'## {heading}\n\n{instructions}\n\n{text}')
        return '\n\n'.join(parts)


def read_document(path):
    parser = PromptDocument()
    maximum_size = 64 * 1024 * 1024
    # Previews are emitted on their own lines. Leave their pixels out of the
    # HTML parser and the agent's prompt, while keeping the screenshot path.
    with path.open('rb') as document:
        remaining = maximum_size
        while line := document.readline(remaining + 1):
            remaining -= len(line)
            if remaining < 0:
                raise ValueError('Agent Flow document exceeds the reader size limit')
            if not line.startswith(b'<img class="screenshot-image" src="data:image/jpeg;base64,'):
                parser.feed(line.decode('utf-8'))
    parser.close()
    return parser.prompt()

def existing_path(value):
    if value.startswith('file:'):
        url = urlsplit(value)
        if url.netloc not in ('', 'localhost') or url.query or url.fragment:
            raise ValueError('Use a local file URL without query or fragment')
        value = unquote(url.path)
    path = Path(value)
    if not path.is_absolute():
        raise ValueError('Use an absolute local file path')
    if not path.exists():
        path = Path(unquote(value))
    path = path.resolve(strict=True)
    if not path.is_file():
        raise ValueError('Expected a regular local file')
    return path


def canonical_source(value):
    link = urlsplit(value)
    if link.scheme in ('http', 'https'):
        query = parse_qs(link.query, keep_blank_values=True)
        names = query.get('prompt', [])
        if (link.scheme != 'http' or link.netloc != '127.0.0.1:59343'
                or link.path != '/index.html' or link.fragment or set(query) != {'prompt'}
                or len(names) != 1 or not PROMPT_NAME.fullmatch(names[0])):
            raise ValueError('Expected a local Agent Flow prompt viewer link')
        directory = Path.home() / 'Library/Application Support/AgentFlow/Prompts'
        path = directory / names[0]
        if path.is_symlink() or directory.is_symlink():
            raise ValueError('Expected the original Agent Flow archive')
        return existing_path(str(path))
    path = existing_path(value)
    if path.suffix == '.md':
        return path
    if path.suffix != '.html':
        raise ValueError('Expected an Agent Flow .html viewer or .md source')
    with path.open('rb') as viewer:
        header = viewer.read(8192)
    metadata = SourceMetadata()
    metadata.feed(header.decode('utf-8', errors='replace'))
    if metadata.documents:
        if len(metadata.documents) != 1 or metadata.sources:
            raise ValueError('Ambiguous Agent Flow document metadata')
        return path
    if len(metadata.sources) != 1:
        raise ValueError('Expected exactly one source in the first 8 KiB')
    source = existing_path(metadata.sources[0])
    if source.suffix != '.md':
        raise ValueError('Agent Flow source must be Markdown')
    # Agent Flow archives pair same-named files in one directory. Metadata is
    # a route to that archive, never authority to read an unrelated local file.
    if source.parent != path.parent or source.stem != path.stem:
        raise ValueError('Source must be the matching Markdown archive')
    return source


def read_prompts(values):
    sources = list(dict.fromkeys(canonical_source(value) for value in values))
    # Validate/read every supplied archive before emitting any partial result.
    return [(source, read_document(source) if source.suffix == '.html'
             else source.read_bytes().decode('utf-8')) for source in sources]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', help='Agent Flow viewer links or local .html/.md paths')
    parser.add_argument('--from-line', type=int, default=1,
                        help='Continue one canonical prompt from this 1-based line')
    args = parser.parse_args()
    try:
        prompts = read_prompts(args.paths)
        if args.from_line < 1 or (args.from_line != 1 and len(prompts) != 1):
            raise ValueError('Continuation needs one prompt and a positive line')
    except (OSError, ValueError) as error:
        print(f'Cannot read complete Agent Flow prompt: {error}', file=sys.stderr)
        return 1
    for index, (source, text) in enumerate(prompts):
        if index:
            sys.stdout.write('\n')
        lines = text.splitlines(keepends=True)
        if args.from_line > max(1, len(lines)):
            print('Cannot read complete Agent Flow prompt: line is past EOF', file=sys.stderr)
            return 1
        payload = ''.join(lines[args.from_line-1:])
        sys.stdout.write(f'Source: {source}\nBytes: {len(text.encode("utf-8"))}; '
                         f'lines: {args.from_line}..{len(lines)}; '
                         f'{"complete" if args.from_line == 1 else "continuation"}\n')
        sys.stdout.write(payload)
        if not payload.endswith('\n'):
            sys.stdout.write('\n')
        sys.stdout.write(f'END OF CANONICAL PROMPT: {source}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
