#!/usr/bin/env python3
"""Read canonical Agent Flow Markdown without loading its rendered HTML body."""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


class SourceMetadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sources = []

    def handle_starttag(self, tag, attrs):
        if tag != 'meta':
            return
        names = [value for key, value in attrs if key == 'name']
        if 'agent-flow-source' not in names:
            return
        values = [value for key, value in attrs if key == 'content']
        if len(names) != 1 or len(values) != 1 or not values[0]:
            raise ValueError('Ambiguous Agent Flow source metadata')
        self.sources.append(values[0])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)


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
    path = existing_path(value)
    if path.suffix == '.md':
        return path
    if path.suffix != '.html':
        raise ValueError('Expected an Agent Flow .html viewer or .md source')
    with path.open('rb') as viewer:
        header = viewer.read(8192)
    metadata = SourceMetadata()
    metadata.feed(header.decode('utf-8', errors='replace'))
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
    return [(source, source.read_bytes().decode('utf-8')) for source in sources]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', help='Absolute .html/.md paths, in message order')
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
