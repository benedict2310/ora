#!/usr/bin/env python3
"""
Ora Research Agent — runs inside an isolated container.

Reads input.json from the working directory, performs web research
(search + fetch + extract), and writes output.json.

No access to the host filesystem, local network, or credentials.
"""

import json
import os
import sys
import time
import urllib.parse
from datetime import datetime, timezone

import requests
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0.0.0 Safari/537.36"
)
HEADERS = {"User-Agent": USER_AGENT}
DDG_LITE_URL = "https://lite.duckduckgo.com/lite/"
DEFAULT_TIMEOUT = 15


# ---------------------------------------------------------------------------
# Input / Output
# ---------------------------------------------------------------------------

def read_input():
    """Read input.json from the working directory."""
    input_path = os.path.join(os.getcwd(), "input.json")
    with open(input_path, "r") as f:
        return json.load(f)


def write_output(data):
    """Write output.json to the working directory."""
    output_path = os.path.join(os.getcwd(), "output.json")
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Search (DuckDuckGo HTML Lite)
# ---------------------------------------------------------------------------

def search_ddg(query, max_results=10):
    """Search DuckDuckGo HTML Lite and return a list of URLs."""
    try:
        resp = requests.post(
            DDG_LITE_URL,
            data={"q": query},
            headers=HEADERS,
            timeout=DEFAULT_TIMEOUT,
        )
        resp.raise_for_status()
    except Exception:
        return []

    soup = BeautifulSoup(resp.text, "html.parser")
    urls = []
    for link in soup.find_all("a", class_="result-link"):
        href = link.get("href", "")
        if href.startswith("http"):
            urls.append(href)
            if len(urls) >= max_results:
                break

    # Fallback: extract from all links if result-link class not found
    if not urls:
        for link in soup.find_all("a"):
            href = link.get("href", "")
            if href.startswith("http") and "duckduckgo" not in href:
                urls.append(href)
                if len(urls) >= max_results:
                    break

    return urls


def discover_sources(query, constraints):
    """Generate search queries and discover source URLs."""
    max_queries = constraints.get("max_search_queries", 5)
    max_pages = constraints.get("max_pages", 15)
    max_domains = constraints.get("max_domains", 8)

    # Start with the original query, then generate variations
    search_queries = [query]
    words = query.split()
    if len(words) > 3:
        search_queries.append(" ".join(words[:3]) + " latest")
        search_queries.append(query + " analysis")
    search_queries = search_queries[:max_queries]

    seen_urls = set()
    seen_domains = set()
    discovered_urls = []
    used_queries = []

    for sq in search_queries:
        if len(discovered_urls) >= max_pages:
            break

        results = search_ddg(sq, max_results=max_pages)
        used_queries.append(sq)

        for url in results:
            if url in seen_urls:
                continue
            domain = urllib.parse.urlparse(url).netloc
            if len(seen_domains) >= max_domains and domain not in seen_domains:
                continue
            seen_urls.add(url)
            seen_domains.add(domain)
            discovered_urls.append(url)
            if len(discovered_urls) >= max_pages:
                break

    return discovered_urls, used_queries, list(seen_domains)


# ---------------------------------------------------------------------------
# Fetch & Extract
# ---------------------------------------------------------------------------

def fetch_page(url, max_size_bytes=5_242_880, timeout=DEFAULT_TIMEOUT):
    """Fetch a URL and extract text content."""
    try:
        resp = requests.get(
            url, headers=HEADERS, timeout=timeout, stream=True, allow_redirects=True
        )
        resp.raise_for_status()

        # Enforce size limit
        content = b""
        for chunk in resp.iter_content(chunk_size=8192):
            content += chunk
            if len(content) > max_size_bytes:
                break

        final_url = resp.url
        content_type = resp.headers.get("Content-Type", "text/html")
        text_content = content.decode("utf-8", errors="replace")

        # Extract text from HTML
        soup = BeautifulSoup(text_content, "html.parser")

        # Remove script and style elements
        for tag in soup(["script", "style", "nav", "footer", "header"]):
            tag.decompose()

        title = soup.title.string.strip() if soup.title and soup.title.string else None
        text = soup.get_text(separator="\n", strip=True)

        # Collapse excessive whitespace
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        text = "\n".join(lines)

        word_count = len(text.split())

        return {
            "url": url,
            "final_url": str(final_url),
            "title": title,
            "text": text[:50000],  # Cap at 50k chars per page
            "content_type": content_type.split(";")[0].strip(),
            "word_count": word_count,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
        }
    except Exception as e:
        return {"url": url, "error": str(e)}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    started_at = datetime.now(timezone.utc).isoformat()
    input_data = read_input()

    task_id = input_data.get("task_id", "")
    query = input_data.get("query")
    explicit_urls = input_data.get("urls", [])
    constraints = input_data.get("constraints", {})
    timeout_seconds = constraints.get("timeout_seconds", 120)
    max_page_size = constraints.get("max_page_size_bytes", 5_242_880)

    deadline = time.time() + timeout_seconds

    # Discover sources if query is present
    search_queries_used = []
    domains_used = []
    discovery_rationale = None
    all_urls = list(explicit_urls)

    if query:
        discovered, search_queries_used, domains_used = discover_sources(
            query, constraints
        )
        all_urls.extend(u for u in discovered if u not in set(all_urls))
        discovery_rationale = (
            f"Searched for '{query}' with {len(search_queries_used)} queries, "
            f"discovered {len(discovered)} sources across {len(domains_used)} domains."
        )

    # Fetch pages
    pages = []
    failed_urls = []

    for url in all_urls:
        if time.time() >= deadline:
            break

        result = fetch_page(url, max_size_bytes=max_page_size)
        if "error" in result:
            failed_urls.append(
                {"url": url, "code": "fetch_failed", "message": result["error"]}
            )
        else:
            pages.append(result)

    completed_at = datetime.now(timezone.utc).isoformat()

    output = {
        "task_id": task_id,
        "status": "completed",
        "query": query,
        "pages": pages,
        "metadata": {
            "started_at": started_at,
            "completed_at": completed_at,
            "search_queries_used": search_queries_used,
            "requested_url_count": len(all_urls),
            "succeeded_url_count": len(pages),
            "failed_url_count": len(failed_urls),
        },
        "failed_urls": failed_urls,
        "provenance": {
            "search_queries": search_queries_used,
            "discovery_rationale": discovery_rationale,
            "domains_used": domains_used,
        },
    }

    write_output(output)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # Write error output for the host to read
        write_output(
            {
                "task_id": "",
                "status": "failed",
                "query": None,
                "pages": [],
                "metadata": {
                    "started_at": datetime.now(timezone.utc).isoformat(),
                    "completed_at": datetime.now(timezone.utc).isoformat(),
                },
                "failed_urls": [],
                "provenance": None,
                "error": str(e),
            }
        )
        sys.exit(1)
