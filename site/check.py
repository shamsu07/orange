#!/usr/bin/env python3
"""Check the static site without fetching remote links or adding dependencies."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import sys


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.ids = set()
        self.references = []
        self.errors = []
        self.heading_count = 0
        self.has_language = False
        self.has_viewport = False
        self.has_title = False
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "html":
            self.has_language = bool(attrs.get("lang"))
        if tag == "meta" and attrs.get("name") == "viewport":
            self.has_viewport = True
        if tag == "title":
            self.has_title = True
        if tag == "h1":
            self.heading_count += 1
        if "id" in attrs:
            if attrs["id"] in self.ids:
                self.errors.append(f"duplicate id: {attrs['id']}")
            self.ids.add(attrs["id"])
        if tag == "img":
            if "alt" not in attrs:
                self.errors.append("image has no alt attribute")
            if not attrs.get("width") or not attrs.get("height"):
                self.errors.append("image has no explicit width or height")
        if tag == "button" and attrs.get("type") != "button":
            self.errors.append("button should declare type=button")
        for attribute in ("href", "src"):
            if attribute in attrs:
                self.references.append(attrs[attribute])


def local_target(site, source, reference):
    url = urlsplit(reference)
    if url.scheme or url.netloc:
        if url.scheme != "https":
            raise ValueError(f"non-HTTPS reference: {reference}")
        return None, None
    relative = unquote(url.path)
    if relative.startswith("/orange/"):
        target = site / relative.removeprefix("/orange/")
    elif relative.startswith("/"):
        raise ValueError(f"reference bypasses the /orange/ project base: {reference}")
    else:
        target = source.parent / relative if relative else source
    target = target.resolve()
    if not target.is_relative_to(site):
        raise ValueError(f"reference escapes the site: {reference}")
    if target.is_dir():
        target = target / "index.html"
    return target, unquote(url.fragment)


def main():
    site = Path(__file__).resolve().parent
    pages = {path.resolve(): Page(path) for path in sorted(site.rglob("*.html"))}
    errors = []
    references = 0
    for path, page in pages.items():
        label = str(path.relative_to(site))
        for error in page.errors:
            errors.append(f"{label}: {error}")
        if not (page.has_language and page.has_viewport and page.has_title):
            errors.append(f"{label}: missing language, viewport or title")
        if page.heading_count != 1:
            errors.append(f"{label}: expected one h1, found {page.heading_count}")
        for reference in page.references:
            references += 1
            try:
                target, fragment = local_target(site, path, reference)
            except ValueError as error:
                errors.append(f"{label}: {error}")
                continue
            if target is None:
                continue
            if not target.is_file():
                errors.append(f"{label}: missing target for {reference}")
            elif fragment and target in pages and fragment not in pages[target].ids:
                errors.append(f"{label}: unknown fragment in {reference}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Checked {len(pages)} pages and {references} references; local links and basic markup passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
