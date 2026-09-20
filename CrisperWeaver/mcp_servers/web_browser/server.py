"""Lightweight web-browsing MCP server for local LLMs (LM Studio, etc.).

Exposes three tools over stdio so a local model can reach the live internet:

  - web_search      : search the web and return titles, URLs, and snippets
  - fetch_url       : download a page and return its readable text
  - search_and_read : search and read the top results in one call

Search uses ddgs (multi-engine, no API key). Run directly with
`python server.py` or via `uv run server.py`.
"""

from __future__ import annotations

import logging

import httpx
from bs4 import BeautifulSoup
from ddgs import DDGS
from mcp.server.fastmcp import FastMCP

# Keep stderr quiet: ddgs logs per-engine fallbacks at ERROR (harmless — it just
# tries the next search backend), and httpx/mcp log every request at INFO. Left
# unconfigured these flood LM Studio's MCP log and look like failures.
logging.getLogger("ddgs").setLevel(logging.CRITICAL)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("mcp").setLevel(logging.WARNING)

mcp = FastMCP("web-browser")

# A normal-looking browser UA so sites return real HTML instead of blocking us.
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}

# Tags that never contain the main readable content; dropped before text extraction.
_BOILERPLATE_TAGS = (
    "script", "style", "nav", "header", "footer",
    "aside", "iframe", "noscript", "form", "svg", "button",
)


@mcp.tool()
def web_search(query: str, max_results: int = 5) -> str:
    """Search the live web for current, up-to-date information.

    Use this whenever the answer depends on recent events, news, prices,
    release versions, documentation, or anything that may have changed after
    your training cutoff. Returns a numbered list of results, each with a
    title, URL, and short snippet. To read a result in full, call `fetch_url`
    with its URL.

    Args:
        query: What to search for, phrased as a normal search query.
        max_results: How many results to return (1-10).
    """
    max_results = max(1, min(max_results, 10))
    try:
        with DDGS() as ddgs:
            hits = list(ddgs.text(query, max_results=max_results))
    except Exception as exc:  # network errors, rate limits, library quirks
        return f"Search failed: {exc}"

    if not hits:
        return f"No results found for: {query!r}"

    blocks = []
    for i, hit in enumerate(hits, 1):
        title = (hit.get("title") or "").strip()
        url = (hit.get("href") or hit.get("url") or "").strip()
        snippet = (hit.get("body") or "").strip()
        blocks.append(f"[{i}] {title}\n    URL: {url}\n    {snippet}")
    return "\n\n".join(blocks)


def _fetch_readable(url: str, max_chars: int) -> str:
    """Download `url` and return its title + readable text. Shared by the tools."""
    if not url.lower().startswith(("http://", "https://")):
        return f"Error: {url!r} must start with http:// or https://"

    try:
        with httpx.Client(
            timeout=15.0, follow_redirects=True, headers=_HEADERS
        ) as client:
            resp = client.get(url)
            resp.raise_for_status()
    except Exception as exc:
        return f"Failed to fetch {url}: {exc}"

    # Skip non-HTML payloads (PDFs, images, downloads): feeding their raw bytes
    # to an HTML parser just yields garbage text.
    ctype = resp.headers.get("content-type", "").lower()
    if ctype and not any(t in ctype for t in ("html", "xml", "json", "text", "csv")):
        return f"Skipped {url}: content type '{ctype.split(';')[0].strip()}' is not a readable web page."

    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(_BOILERPLATE_TAGS):
        tag.decompose()

    # .get_text() also handles a <title> with nested tags, which .string misses.
    title = soup.title.get_text(strip=True) if soup.title else ""
    raw = soup.get_text(separator="\n")
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    body = "\n".join(lines)

    max_chars = max(500, min(max_chars, 20000))
    truncated = len(body) > max_chars
    body = body[:max_chars]

    header = f"Title: {title}\nURL: {url}\n\n" if title else f"URL: {url}\n\n"
    footer = "\n\n[...content truncated...]" if truncated else ""
    return header + body + footer


@mcp.tool()
def fetch_url(url: str, max_chars: int = 8000) -> str:
    """Fetch a web page and return its readable text content.

    Use this after `web_search` to read the full content of a promising result,
    or whenever the user gives you a specific link. Scripts, styles, navigation
    and other boilerplate are stripped out. Very long pages are truncated.

    Args:
        url: The full URL to fetch (must start with http:// or https://).
        max_chars: Maximum characters of text to return (500-20000).
    """
    return _fetch_readable(url, max_chars)


@mcp.tool()
def search_and_read(query: str, num_pages: int = 2, max_chars: int = 4000) -> str:
    """Search the web and read the top results in one step — the easy button.

    Best tool when you need current information to answer a question: it runs a
    web search for `query`, then opens and extracts the readable text of the top
    `num_pages` results, returning their snippets and full page text together.
    Prefer this over calling `web_search` and `fetch_url` separately.

    Args:
        query: What to look up.
        num_pages: How many of the top results to open and read (1-4).
        max_chars: Max characters of text from each page (500-8000).
    """
    num_pages = max(1, min(num_pages, 4))
    max_chars = max(500, min(max_chars, 8000))
    try:
        with DDGS() as ddgs:
            hits = list(ddgs.text(query, max_results=num_pages))
    except Exception as exc:
        return f"Search failed: {exc}"

    if not hits:
        return f"No results found for: {query!r}"

    parts = [f"Web results for: {query}"]
    for i, hit in enumerate(hits[:num_pages], 1):
        title = (hit.get("title") or "").strip()
        url = (hit.get("href") or hit.get("url") or "").strip()
        snippet = (hit.get("body") or "").strip()
        parts.append(
            f"\n===== RESULT {i}: {title} =====\n"
            f"URL: {url}\nSnippet: {snippet}\n\n{_fetch_readable(url, max_chars)}"
        )
    return "\n".join(parts)


if __name__ == "__main__":
    mcp.run()  # stdio transport by default — what LM Studio expects
