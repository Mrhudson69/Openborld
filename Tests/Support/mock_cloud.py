#!/usr/bin/env python3
"""
A local stand-in for Azure Blob Storage and S3, used to test the real providers.

Two jobs:

1. **Verify signatures independently.** Azure SharedKey and AWS SigV4 are
   reimplemented here from the specs, in a different language, by different
   code. When the Swift signer and this verifier agree across awkward object
   keys, query orderings and unicode, that agreement is evidence; when they
   disagree, the mismatch report says exactly which component differed.

2. **Behave enough like the real services** — paginated XML listings, block and
   multipart uploads, range reads, server-side copy — that the provider code
   paths are genuinely exercised rather than mocked out.

Only the standard library is used, so the tests have no install step.
"""

import base64
import hashlib
import hmac
import json
import re
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Fixed credentials the Swift tests also use.
AZURE_ACCOUNT = "devstoreaccount1"
AZURE_KEY_B64 = base64.b64encode(b"openborld-test-account-key-0123456789").decode()
S3_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"
S3_SECRET_KEY = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
S3_REGION = "us-east-1"


# --------------------------------------------------------------------------
# Store
# --------------------------------------------------------------------------

class Store:
    """In-memory objects, shared by both the Azure and S3 front ends."""

    def __init__(self):
        self.lock = threading.RLock()
        # containers[name] = {"created": iso}
        self.containers = {}
        # objects[(container, key)] = {"data": bytes, "modified": .., "type": ..,
        #                              "etag": .., "meta": {}}
        self.objects = {}
        # staged blocks / parts, keyed by (container, key)
        self.blocks = {}
        self.uploads = {}
        self.upload_counter = 0
        # Every signature check, for the tests to inspect.
        self.auth_log = []

    def put(self, container, key, data, content_type="application/octet-stream", meta=None):
        with self.lock:
            self.containers.setdefault(container, {"created": iso_now()})
            self.objects[(container, key)] = {
                "data": data,
                "modified": time.time(),
                "type": content_type,
                "etag": '"%s"' % hashlib.md5(data).hexdigest(),
                "meta": meta or {},
            }

    def get(self, container, key):
        with self.lock:
            return self.objects.get((container, key))

    def delete(self, container, key):
        with self.lock:
            return self.objects.pop((container, key), None)

    def list_keys(self, container):
        with self.lock:
            return sorted(k for (c, k) in self.objects if c == container)


STORE = Store()


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")


def rfc1123(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S GMT"
    )


# --------------------------------------------------------------------------
# Azure SharedKey verification
# --------------------------------------------------------------------------

def azure_canonical_headers(headers):
    """x-ms-* headers: lowercased, sorted, whitespace collapsed, one per line."""
    rows = []
    for name in headers.keys():
        lower = name.lower()
        if lower.startswith("x-ms-"):
            value = " ".join(headers[name].split())
            rows.append("%s:%s" % (lower, value))
    rows.sort()
    return "\n".join(rows)


def azure_canonical_resource(account, path, query):
    """`/account/path`, then one sorted lowercased line per query parameter."""
    resource = "/%s%s" % (account, path if path else "/")
    if not query:
        return resource
    grouped = {}
    for name, values in urllib.parse.parse_qs(query, keep_blank_values=True).items():
        grouped.setdefault(name.lower(), []).extend(values)
    for name in sorted(grouped):
        resource += "\n%s:%s" % (name, ",".join(sorted(grouped[name])))
    return resource


def azure_string_to_sign(method, headers, account, path, query):
    def header(name):
        for key in headers.keys():
            if key.lower() == name.lower():
                return headers[key]
        return ""

    # Azure wants an empty field, not "0", when there is no body.
    length = header("Content-Length")
    if length in ("0", ""):
        length = ""

    parts = [
        method,
        header("Content-Encoding"),
        header("Content-Language"),
        length,
        header("Content-MD5"),
        header("Content-Type"),
        "" if header("x-ms-date") else header("Date"),
        header("If-Modified-Since"),
        header("If-Match"),
        header("If-None-Match"),
        header("If-Unmodified-Since"),
        header("Range"),
        azure_canonical_headers(headers),
    ]
    return "\n".join(parts) + "\n" + azure_canonical_resource(account, path, query)


def verify_azure(handler, method, path, query):
    """Returns (ok, detail). Accepts SharedKey or any well-formed SAS token."""
    authorization = handler.headers.get("Authorization", "")

    if not authorization:
        params = urllib.parse.parse_qs(query, keep_blank_values=True)
        # A SAS token is opaque to clients and to us; check it is present and
        # structurally complete, which is what the provider is responsible for.
        if "sig" in params and "sv" in params:
            STORE.auth_log.append({"scheme": "sas", "ok": True, "path": path})
            return True, "sas"
        return False, "no Authorization header and no SAS token in the query string"

    match = re.match(r"SharedKey ([^:]+):(.+)$", authorization)
    if not match:
        return False, "Authorization header is not SharedKey: %r" % authorization[:40]
    account, provided = match.group(1), match.group(2)
    if account != AZURE_ACCOUNT:
        return False, "unknown account %r" % account

    expected_sts = azure_string_to_sign(method, handler.headers, account, path, query)
    key = base64.b64decode(AZURE_KEY_B64)
    expected = base64.b64encode(
        hmac.new(key, expected_sts.encode("utf-8"), hashlib.sha256).digest()
    ).decode()

    ok = hmac.compare_digest(expected, provided)
    STORE.auth_log.append({
        "scheme": "sharedkey",
        "ok": ok,
        "path": path,
        "query": query,
        "string_to_sign": expected_sts,
    })
    if ok:
        return True, "sharedkey"
    return False, (
        "SharedKey signature mismatch.\n"
        "--- string-to-sign the server expected (repr) ---\n%r\n"
        "--- expected signature ---\n%s\n--- client sent ---\n%s"
        % (expected_sts, expected, provided)
    )


# --------------------------------------------------------------------------
# AWS SigV4 verification
# --------------------------------------------------------------------------

def uri_encode(value, encode_slash=True):
    """RFC 3986 unreserved set only — stricter than urllib's default."""
    safe = "-._~" if encode_slash else "-._~/"
    return urllib.parse.quote(value, safe=safe)


def sigv4_canonical_query(query):
    if not query:
        return ""
    pairs = []
    for chunk in query.split("&"):
        if not chunk:
            continue
        if "=" in chunk:
            name, value = chunk.split("=", 1)
        else:
            name, value = chunk, ""
        pairs.append((
            uri_encode(urllib.parse.unquote(name)),
            uri_encode(urllib.parse.unquote(value)),
        ))
    pairs.sort()
    return "&".join("%s=%s" % pair for pair in pairs)


def sigv4_signing_key(secret, day, region, service):
    key = hmac.new(("AWS4" + secret).encode(), day.encode(), hashlib.sha256).digest()
    key = hmac.new(key, region.encode(), hashlib.sha256).digest()
    key = hmac.new(key, service.encode(), hashlib.sha256).digest()
    return hmac.new(key, b"aws4_request", hashlib.sha256).digest()


def verify_sigv4(handler, method, path, query):
    authorization = handler.headers.get("Authorization", "")

    # Presigned URLs carry the signature in the query string instead.
    params = urllib.parse.parse_qs(query, keep_blank_values=True)
    if not authorization and "X-Amz-Signature" in params:
        return verify_presigned(handler, method, path, query, params)

    match = re.match(
        r"AWS4-HMAC-SHA256 Credential=([^/]+)/(\S+?), ?SignedHeaders=(\S+?), ?Signature=([0-9a-f]+)$",
        authorization,
    )
    if not match:
        return False, "Authorization header is not SigV4: %r" % authorization[:60]

    access_key, scope, signed_headers, provided = match.groups()
    if access_key != S3_ACCESS_KEY:
        return False, "unknown access key %r" % access_key

    day, region, service, terminator = scope.split("/")
    if terminator != "aws4_request":
        return False, "bad credential scope %r" % scope

    payload_hash = handler.headers.get("x-amz-content-sha256", "")
    if not payload_hash:
        return False, "missing x-amz-content-sha256"

    # Only the headers the client said it signed, in the order it declared.
    names = signed_headers.split(";")
    canonical_headers = ""
    for name in names:
        value = None
        for key in handler.headers.keys():
            if key.lower() == name:
                value = " ".join(handler.headers[key].split())
                break
        if value is None:
            return False, "signed header %r was not sent" % name
        canonical_headers += "%s:%s\n" % (name, value)

    canonical_request = "\n".join([
        method,
        uri_encode(urllib.parse.unquote(path), encode_slash=False) or "/",
        sigv4_canonical_query(query),
        canonical_headers,
        signed_headers,
        payload_hash,
    ])

    timestamp = handler.headers.get("x-amz-date", "")
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        timestamp,
        scope,
        hashlib.sha256(canonical_request.encode()).hexdigest(),
    ])

    expected = hmac.new(
        sigv4_signing_key(S3_SECRET_KEY, day, region, service),
        string_to_sign.encode(),
        hashlib.sha256,
    ).hexdigest()

    ok = hmac.compare_digest(expected, provided)
    STORE.auth_log.append({
        "scheme": "sigv4",
        "ok": ok,
        "path": path,
        "query": query,
        "canonical_request": canonical_request,
    })
    if ok:
        return True, "sigv4"
    return False, (
        "SigV4 signature mismatch.\n"
        "--- canonical request the server built (repr) ---\n%r\n"
        "--- string to sign ---\n%r\n"
        "--- expected ---\n%s\n--- client sent ---\n%s"
        % (canonical_request, string_to_sign, expected, provided)
    )


def verify_presigned(handler, method, path, query, params):
    provided = params["X-Amz-Signature"][0]
    scope = params["X-Amz-Credential"][0].split("/", 1)[1]
    day, region, service, _ = scope.split("/")
    timestamp = params["X-Amz-Date"][0]

    # The signature itself is excluded from the canonical query string.
    filtered = "&".join(
        chunk for chunk in query.split("&")
        if not chunk.startswith("X-Amz-Signature=")
    )
    host = handler.headers.get("Host", "")
    canonical_request = "\n".join([
        method,
        uri_encode(urllib.parse.unquote(path), encode_slash=False) or "/",
        sigv4_canonical_query(filtered),
        "host:%s\n" % host,
        "host",
        "UNSIGNED-PAYLOAD",
    ])
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", timestamp, scope,
        hashlib.sha256(canonical_request.encode()).hexdigest(),
    ])
    expected = hmac.new(
        sigv4_signing_key(S3_SECRET_KEY, day, region, service),
        string_to_sign.encode(), hashlib.sha256,
    ).hexdigest()

    ok = hmac.compare_digest(expected, provided)
    STORE.auth_log.append({"scheme": "presigned", "ok": ok, "path": path})
    if ok:
        return True, "presigned"
    return False, (
        "Presigned signature mismatch.\n--- canonical request ---\n%r\n--- expected ---\n%s\n--- sent ---\n%s"
        % (canonical_request, expected, provided)
    )


# --------------------------------------------------------------------------
# Request handling
# --------------------------------------------------------------------------

def xml_escape(value):
    return (
        str(value)
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace('"', "&quot;").replace("'", "&apos;")
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockCloud/1.0"

    def log_message(self, *args):
        pass  # Quiet; the tests read auth_log instead.

    # -- plumbing ---------------------------------------------------------

    def respond(self, status, body=b"", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, str(value))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def fail(self, status, code, message):
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<Error><Code>%s</Code><Message>%s</Message></Error>"
            % (xml_escape(code), xml_escape(message))
        )
        self.respond(status, body, {"Content-Type": "application/xml"})

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            return self.rfile.read(length)
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = b""
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks += self.rfile.read(size)
                self.rfile.readline()
            return chunks
        return b""

    def split(self):
        parsed = urllib.parse.urlsplit(self.path)
        return parsed.path, parsed.query

    def query_params(self, query):
        return urllib.parse.parse_qs(query, keep_blank_values=True)

    def do_GET(self):
        self.route("GET")

    def do_HEAD(self):
        self.route("HEAD")

    def do_PUT(self):
        self.route("PUT")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        path, query = self.split()

        # A control endpoint so tests can inspect and seed the server.
        if path.startswith("/__control"):
            return self.control(method, path, query)

        if path.startswith("/" + AZURE_ACCOUNT):
            ok, detail = verify_azure(self, method, path, query)
            if not ok:
                return self.fail(403, "AuthenticationFailed", detail)
            return self.azure(method, path, query)

        ok, detail = verify_sigv4(self, method, path, query)
        if not ok:
            return self.fail(403, "SignatureDoesNotMatch", detail)
        return self.s3(method, path, query)

    def control(self, method, path, query):
        if path == "/__control/auth_log":
            return self.respond(
                200, json.dumps(STORE.auth_log), {"Content-Type": "application/json"}
            )
        if path == "/__control/reset":
            with STORE.lock:
                STORE.containers.clear()
                STORE.objects.clear()
                STORE.blocks.clear()
                STORE.uploads.clear()
                STORE.auth_log.clear()
            return self.respond(200, "ok")
        if path == "/__control/seed":
            params = self.query_params(query)
            container = params["container"][0]
            count = int(params.get("count", ["10"])[0])
            prefix = params.get("prefix", [""])[0]
            with STORE.lock:
                STORE.containers.setdefault(container, {"created": iso_now()})
            for index in range(count):
                STORE.put(container, "%sfile-%05d.txt" % (prefix, index),
                          ("content %d" % index).encode())
            return self.respond(200, "ok")
        return self.respond(404, "unknown control endpoint")

    # -- Azure ------------------------------------------------------------

    def azure(self, method, path, query):
        params = self.query_params(query)
        # /devstoreaccount1[/container[/key...]]
        rest = path[len("/" + AZURE_ACCOUNT):].lstrip("/")
        segments = rest.split("/", 1)
        container = urllib.parse.unquote(segments[0]) if segments[0] else None
        key = urllib.parse.unquote(segments[1]) if len(segments) > 1 else ""

        if container is None:
            if method == "GET" and params.get("comp", [""])[0] == "list":
                return self.azure_list_containers(params)
            return self.fail(400, "InvalidUri", "unsupported account-level request")

        restype = params.get("restype", [""])[0]
        comp = params.get("comp", [""])[0]

        if restype == "container" and not key:
            if method == "PUT":
                with STORE.lock:
                    if container in STORE.containers:
                        return self.fail(409, "ContainerAlreadyExists", "already exists")
                    STORE.containers[container] = {"created": iso_now()}
                return self.respond(201)
            if method == "DELETE":
                with STORE.lock:
                    if container not in STORE.containers:
                        return self.fail(404, "ContainerNotFound", container)
                    if any(c == container for (c, _) in STORE.objects):
                        return self.fail(409, "ContainerNotEmpty", "container is not empty")
                    del STORE.containers[container]
                return self.respond(202)
            if method == "GET" and comp == "list":
                return self.azure_list_blobs(container, params)
            if method in ("GET", "HEAD"):
                if container not in STORE.containers:
                    return self.fail(404, "ContainerNotFound", container)
                return self.respond(200)

        if not key:
            return self.fail(400, "InvalidUri", "missing blob name")

        if method == "PUT" and comp == "block":
            block_id = params.get("blockid", [""])[0]
            data = self.read_body()
            with STORE.lock:
                STORE.blocks.setdefault((container, key), {})[block_id] = data
            return self.respond(201)

        if method == "PUT" and comp == "blocklist":
            body = self.read_body()
            try:
                root = ET.fromstring(body)
            except ET.ParseError as error:
                return self.fail(400, "InvalidXmlDocument", str(error))
            ids = [node.text for node in root if node.tag in ("Latest", "Committed", "Uncommitted")]
            with STORE.lock:
                staged = STORE.blocks.get((container, key), {})
                missing = [i for i in ids if i not in staged]
                if missing:
                    return self.fail(
                        400, "InvalidBlockList",
                        "block list references %d unstaged block(s)" % len(missing),
                    )
                data = b"".join(staged[i] for i in ids)
                STORE.blocks.pop((container, key), None)
            STORE.put(container, key, data,
                      self.headers.get("x-ms-blob-content-type", "application/octet-stream"))
            return self.respond(201, b"", {"ETag": STORE.get(container, key)["etag"]})

        if method == "GET" and comp == "blocklist":
            with STORE.lock:
                staged = STORE.blocks.get((container, key), {})
            if not staged:
                return self.fail(404, "BlobNotFound", key)
            rows = "".join(
                "<Block><Name>%s</Name><Size>%d</Size></Block>" % (xml_escape(i), len(d))
                for i, d in staged.items()
            )
            body = (
                '<?xml version="1.0" encoding="utf-8"?>'
                "<BlockList><UncommittedBlocks>%s</UncommittedBlocks></BlockList>" % rows
            )
            return self.respond(200, body, {"Content-Type": "application/xml"})

        if method == "PUT":
            source = self.headers.get("x-ms-copy-source")
            if source:
                return self.azure_copy(container, key, source)
            data = self.read_body()
            STORE.put(container, key, data,
                      self.headers.get("Content-Type", "application/octet-stream"),
                      self.azure_meta())
            return self.respond(201, b"", {"ETag": STORE.get(container, key)["etag"]})

        if method in ("GET", "HEAD"):
            obj = STORE.get(container, key)
            if obj is None:
                return self.fail(404, "BlobNotFound", key)
            data = obj["data"]
            headers = {
                "Content-Type": obj["type"],
                "ETag": obj["etag"],
                "Last-Modified": rfc1123(obj["modified"]),
                "x-ms-blob-type": "BlockBlob",
                "x-ms-creation-time": rfc1123(obj["modified"]),
                "x-ms-access-tier": "Hot",
                "Accept-Ranges": "bytes",
            }
            for name, value in obj["meta"].items():
                headers["x-ms-meta-" + name] = value

            range_header = self.headers.get("Range")
            if range_header:
                match = re.match(r"bytes=(\d+)-(\d*)", range_header)
                if match:
                    start = int(match.group(1))
                    end = int(match.group(2)) if match.group(2) else len(data) - 1
                    end = min(end, len(data) - 1)
                    if start > end:
                        return self.fail(416, "InvalidRange", range_header)
                    sliced = data[start:end + 1]
                    headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, len(data))
                    return self.respond(206, sliced, headers)
            return self.respond(200, data, headers)

        if method == "DELETE":
            if STORE.delete(container, key) is None:
                return self.fail(404, "BlobNotFound", key)
            return self.respond(202)

        return self.fail(405, "UnsupportedHttpVerb", method)

    def azure_meta(self):
        meta = {}
        for name in self.headers.keys():
            if name.lower().startswith("x-ms-meta-"):
                meta[name[len("x-ms-meta-"):]] = self.headers[name]
        return meta

    def azure_copy(self, container, key, source):
        parsed = urllib.parse.urlsplit(source)
        rest = parsed.path[len("/" + AZURE_ACCOUNT):].lstrip("/")
        segments = rest.split("/", 1)
        if len(segments) < 2:
            return self.fail(400, "InvalidUri", "copy source is not a blob: %s" % source)
        source_container = urllib.parse.unquote(segments[0])
        source_key = urllib.parse.unquote(segments[1])
        obj = STORE.get(source_container, source_key)
        if obj is None:
            return self.fail(404, "CannotVerifyCopySource", source_key)
        STORE.put(container, key, obj["data"], obj["type"], dict(obj["meta"]))
        return self.respond(202, b"", {
            "x-ms-copy-status": "success",
            "x-ms-copy-id": "mock-copy",
        })

    def azure_list_containers(self, params):
        max_results = int(params.get("maxresults", ["5000"])[0])
        marker = params.get("marker", [""])[0]
        with STORE.lock:
            names = sorted(STORE.containers)
        if marker:
            names = [n for n in names if n > marker]
        page = names[:max_results]
        next_marker = page[-1] if len(names) > max_results else ""
        rows = "".join(
            "<Container><Name>%s</Name><Properties>"
            "<Last-Modified>%s</Last-Modified><Etag>&quot;0x1&quot;</Etag>"
            "</Properties></Container>" % (xml_escape(n), rfc1123(time.time()))
            for n in page
        )
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<EnumerationResults ServiceEndpoint="http://127.0.0.1/">'
            "<Containers>%s</Containers><NextMarker>%s</NextMarker>"
            "</EnumerationResults>" % (rows, xml_escape(next_marker))
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    def azure_list_blobs(self, container, params):
        with STORE.lock:
            if container not in STORE.containers:
                return self.fail(404, "ContainerNotFound", container)

        prefix = params.get("prefix", [""])[0]
        delimiter = params.get("delimiter", [""])[0]
        marker = params.get("marker", [""])[0]
        max_results = int(params.get("maxresults", ["5000"])[0])

        keys = [k for k in STORE.list_keys(container) if k.startswith(prefix)]

        blobs, prefixes = [], []
        if delimiter:
            seen = set()
            for key in keys:
                remainder = key[len(prefix):]
                index = remainder.find(delimiter)
                if index >= 0:
                    group = prefix + remainder[:index + 1]
                    if group not in seen:
                        seen.add(group)
                        prefixes.append(group)
                else:
                    blobs.append(key)
        else:
            blobs = keys

        # Azure pages over the merged, ordered result set.
        entries = sorted(
            [("prefix", p) for p in prefixes] + [("blob", b) for b in blobs],
            key=lambda pair: pair[1],
        )
        if marker:
            entries = [e for e in entries if e[1] > marker]
        page = entries[:max_results]
        next_marker = page[-1][1] if len(entries) > max_results and page else ""

        rows = ""
        for kind, name in page:
            if kind == "prefix":
                rows += "<BlobPrefix><Name>%s</Name></BlobPrefix>" % xml_escape(name)
            else:
                obj = STORE.get(container, name)
                rows += (
                    "<Blob><Name>%s</Name><Properties>"
                    "<Creation-Time>%s</Creation-Time>"
                    "<Last-Modified>%s</Last-Modified>"
                    "<Etag>%s</Etag>"
                    "<Content-Length>%d</Content-Length>"
                    "<Content-Type>%s</Content-Type>"
                    "<BlobType>BlockBlob</BlobType>"
                    "<AccessTier>Hot</AccessTier>"
                    "</Properties></Blob>"
                    % (
                        xml_escape(name),
                        rfc1123(obj["modified"]),
                        rfc1123(obj["modified"]),
                        xml_escape(obj["etag"]),
                        len(obj["data"]),
                        xml_escape(obj["type"]),
                    )
                )

        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<EnumerationResults ContainerName="%s">'
            "<Prefix>%s</Prefix><Delimiter>%s</Delimiter>"
            "<Blobs>%s</Blobs><NextMarker>%s</NextMarker>"
            "</EnumerationResults>"
            % (xml_escape(container), xml_escape(prefix), xml_escape(delimiter),
               rows, xml_escape(next_marker))
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    # -- S3 ---------------------------------------------------------------

    def s3(self, method, path, query):
        params = self.query_params(query)
        rest = path.lstrip("/")
        segments = rest.split("/", 1)
        bucket = urllib.parse.unquote(segments[0]) if segments[0] else None
        key = urllib.parse.unquote(segments[1]) if len(segments) > 1 else ""

        if bucket is None:
            if method == "GET":
                return self.s3_list_buckets()
            return self.fail(405, "MethodNotAllowed", method)

        if not key:
            if method == "PUT":
                self.read_body()
                with STORE.lock:
                    STORE.containers.setdefault(bucket, {"created": iso_now()})
                return self.respond(200, b"", {"Location": "/" + bucket})
            if method == "DELETE":
                with STORE.lock:
                    if any(c == bucket for (c, _) in STORE.objects):
                        return self.fail(409, "BucketNotEmpty", "bucket is not empty")
                    STORE.containers.pop(bucket, None)
                return self.respond(204)
            if method == "POST" and "delete" in params:
                return self.s3_delete_batch(bucket)
            if method == "GET" and "uploads" in params:
                return self.s3_list_uploads(bucket, params)
            if method == "GET":
                return self.s3_list_objects(bucket, params)

        if method == "POST" and "uploads" in params:
            with STORE.lock:
                STORE.upload_counter += 1
                upload_id = "upload-%d" % STORE.upload_counter
                STORE.uploads[upload_id] = {
                    "bucket": bucket, "key": key, "parts": {},
                    "initiated": iso_now(),
                }
            body = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<InitiateMultipartUploadResult><Bucket>%s</Bucket><Key>%s</Key>"
                "<UploadId>%s</UploadId></InitiateMultipartUploadResult>"
                % (xml_escape(bucket), xml_escape(key), upload_id)
            )
            return self.respond(200, body, {"Content-Type": "application/xml"})

        upload_id = params.get("uploadId", [None])[0]

        if method == "PUT" and upload_id and "partNumber" in params:
            number = int(params["partNumber"][0])
            source = self.headers.get("x-amz-copy-source")
            if source:
                return self.s3_copy_part(upload_id, number, source)
            data = self.read_body()
            with STORE.lock:
                upload = STORE.uploads.get(upload_id)
                if upload is None:
                    return self.fail(404, "NoSuchUpload", upload_id)
                upload["parts"][number] = data
            etag = '"%s"' % hashlib.md5(data).hexdigest()
            return self.respond(200, b"", {"ETag": etag})

        if method == "POST" and upload_id:
            body = self.read_body()
            with STORE.lock:
                upload = STORE.uploads.pop(upload_id, None)
            if upload is None:
                return self.fail(404, "NoSuchUpload", upload_id)
            try:
                root = ET.fromstring(body)
            except ET.ParseError as error:
                return self.fail(400, "MalformedXML", str(error))
            numbers = []
            for node in root:
                number = node.find("PartNumber")
                if number is None:
                    number = node.find("{http://s3.amazonaws.com/doc/2006-03-01/}PartNumber")
                if number is not None:
                    numbers.append(int(number.text))
            missing = [n for n in numbers if n not in upload["parts"]]
            if missing:
                return self.fail(400, "InvalidPart", "parts not uploaded: %r" % missing)
            data = b"".join(upload["parts"][n] for n in numbers)
            STORE.put(upload["bucket"], upload["key"], data)
            result = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<CompleteMultipartUploadResult><Bucket>%s</Bucket><Key>%s</Key>"
                "<ETag>%s</ETag></CompleteMultipartUploadResult>"
                % (xml_escape(upload["bucket"]), xml_escape(upload["key"]),
                   xml_escape(STORE.get(upload["bucket"], upload["key"])["etag"]))
            )
            return self.respond(200, result, {"Content-Type": "application/xml"})

        if method == "DELETE" and upload_id:
            with STORE.lock:
                STORE.uploads.pop(upload_id, None)
            return self.respond(204)

        if method == "GET" and upload_id:
            with STORE.lock:
                upload = STORE.uploads.get(upload_id)
                if upload is None:
                    return self.fail(404, "NoSuchUpload", upload_id)
                rows = "".join(
                    "<Part><PartNumber>%d</PartNumber><ETag>&quot;%s&quot;</ETag>"
                    "<Size>%d</Size></Part>"
                    % (n, hashlib.md5(d).hexdigest(), len(d))
                    for n, d in sorted(upload["parts"].items())
                )
            body = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<ListPartsResult><Bucket>%s</Bucket><Key>%s</Key><UploadId>%s</UploadId>"
                "<IsTruncated>false</IsTruncated>%s</ListPartsResult>"
                % (xml_escape(bucket), xml_escape(key), upload_id, rows)
            )
            return self.respond(200, body, {"Content-Type": "application/xml"})

        if method == "PUT":
            source = self.headers.get("x-amz-copy-source")
            if source:
                decoded = urllib.parse.unquote(source).lstrip("/")
                parts = decoded.split("/", 1)
                if len(parts) < 2:
                    return self.fail(400, "InvalidArgument", "bad copy source %r" % source)
                obj = STORE.get(parts[0], parts[1])
                if obj is None:
                    return self.fail(404, "NoSuchKey", parts[1])
                STORE.put(bucket, key, obj["data"], obj["type"])
                body = (
                    '<?xml version="1.0" encoding="UTF-8"?>'
                    "<CopyObjectResult><ETag>%s</ETag></CopyObjectResult>"
                    % xml_escape(obj["etag"])
                )
                return self.respond(200, body, {"Content-Type": "application/xml"})
            data = self.read_body()
            STORE.put(bucket, key, data,
                      self.headers.get("Content-Type", "application/octet-stream"))
            return self.respond(200, b"", {"ETag": STORE.get(bucket, key)["etag"]})

        if method in ("GET", "HEAD"):
            obj = STORE.get(bucket, key)
            if obj is None:
                return self.fail(404, "NoSuchKey", key)
            data = obj["data"]
            headers = {
                "Content-Type": obj["type"],
                "ETag": obj["etag"],
                "Last-Modified": rfc1123(obj["modified"]),
                "x-amz-storage-class": "STANDARD",
                "Accept-Ranges": "bytes",
            }
            range_header = self.headers.get("Range")
            if range_header:
                match = re.match(r"bytes=(\d+)-(\d*)", range_header)
                if match:
                    start = int(match.group(1))
                    end = int(match.group(2)) if match.group(2) else len(data) - 1
                    end = min(end, len(data) - 1)
                    if start > end:
                        return self.fail(416, "InvalidRange", range_header)
                    headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, len(data))
                    return self.respond(206, data[start:end + 1], headers)
            return self.respond(200, data, headers)

        if method == "DELETE":
            STORE.delete(bucket, key)
            return self.respond(204)

        return self.fail(405, "MethodNotAllowed", method)

    def s3_copy_part(self, upload_id, number, source):
        decoded = urllib.parse.unquote(source).lstrip("/")
        parts = decoded.split("/", 1)
        obj = STORE.get(parts[0], parts[1]) if len(parts) == 2 else None
        if obj is None:
            return self.fail(404, "NoSuchKey", source)
        data = obj["data"]
        range_header = self.headers.get("x-amz-copy-source-range")
        if range_header:
            match = re.match(r"bytes=(\d+)-(\d+)", range_header)
            if match:
                data = data[int(match.group(1)):int(match.group(2)) + 1]
        with STORE.lock:
            upload = STORE.uploads.get(upload_id)
            if upload is None:
                return self.fail(404, "NoSuchUpload", upload_id)
            upload["parts"][number] = data
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<CopyPartResult><ETag>&quot;%s&quot;</ETag></CopyPartResult>"
            % hashlib.md5(data).hexdigest()
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    def s3_list_buckets(self):
        with STORE.lock:
            rows = "".join(
                "<Bucket><Name>%s</Name><CreationDate>%s</CreationDate></Bucket>"
                % (xml_escape(name), info["created"])
                for name, info in sorted(STORE.containers.items())
            )
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            "<Owner><ID>mock</ID><DisplayName>mock</DisplayName></Owner>"
            "<Buckets>%s</Buckets></ListAllMyBucketsResult>" % rows
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    def s3_list_objects(self, bucket, params):
        prefix = params.get("prefix", [""])[0]
        delimiter = params.get("delimiter", [""])[0]
        max_keys = int(params.get("max-keys", ["1000"])[0])
        token = params.get("continuation-token", [""])[0]

        keys = [k for k in STORE.list_keys(bucket) if k.startswith(prefix)]

        contents, prefixes = [], []
        if delimiter:
            seen = set()
            for key in keys:
                remainder = key[len(prefix):]
                index = remainder.find(delimiter)
                if index >= 0:
                    group = prefix + remainder[:index + 1]
                    if group not in seen:
                        seen.add(group)
                        prefixes.append(group)
                else:
                    contents.append(key)
        else:
            contents = keys

        entries = sorted(
            [("prefix", p) for p in prefixes] + [("key", k) for k in contents],
            key=lambda pair: pair[1],
        )
        if token:
            entries = [e for e in entries if e[1] > token]
        page = entries[:max_keys]
        truncated = len(entries) > max_keys
        next_token = page[-1][1] if truncated and page else ""

        rows = ""
        for kind, name in page:
            if kind == "prefix":
                rows += "<CommonPrefixes><Prefix>%s</Prefix></CommonPrefixes>" % xml_escape(name)
            else:
                obj = STORE.get(bucket, name)
                rows += (
                    "<Contents><Key>%s</Key><LastModified>%s</LastModified>"
                    "<ETag>%s</ETag><Size>%d</Size>"
                    "<StorageClass>STANDARD</StorageClass></Contents>"
                    % (
                        xml_escape(name),
                        datetime.fromtimestamp(obj["modified"], timezone.utc)
                        .strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                        xml_escape(obj["etag"]),
                        len(obj["data"]),
                    )
                )

        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            "<Name>%s</Name><Prefix>%s</Prefix><KeyCount>%d</KeyCount>"
            "<MaxKeys>%d</MaxKeys><Delimiter>%s</Delimiter>"
            "<IsTruncated>%s</IsTruncated>%s%s</ListBucketResult>"
            % (
                xml_escape(bucket), xml_escape(prefix), len(page), max_keys,
                xml_escape(delimiter), "true" if truncated else "false",
                ("<NextContinuationToken>%s</NextContinuationToken>" % xml_escape(next_token))
                if truncated else "",
                rows,
            )
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    def s3_list_uploads(self, bucket, params):
        prefix = params.get("prefix", [""])[0]
        with STORE.lock:
            rows = "".join(
                "<Upload><Key>%s</Key><UploadId>%s</UploadId>"
                "<Initiated>%s</Initiated></Upload>"
                % (xml_escape(u["key"]), xml_escape(uid), u["initiated"])
                for uid, u in STORE.uploads.items()
                if u["bucket"] == bucket and u["key"].startswith(prefix)
            )
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<ListMultipartUploadsResult><Bucket>%s</Bucket>"
            "<IsTruncated>false</IsTruncated>%s</ListMultipartUploadsResult>"
            % (xml_escape(bucket), rows)
        )
        return self.respond(200, body, {"Content-Type": "application/xml"})

    def s3_delete_batch(self, bucket):
        body = self.read_body()
        try:
            root = ET.fromstring(body)
        except ET.ParseError as error:
            return self.fail(400, "MalformedXML", str(error))
        deleted = 0
        for node in root.iter():
            if node.tag.endswith("Key") and node.text:
                if STORE.delete(bucket, node.text) is not None:
                    deleted += 1
        result = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<DeleteResult><!-- %d deleted --></DeleteResult>" % deleted
        )
        return self.respond(200, result, {"Content-Type": "application/xml"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    # The test harness reads this line to learn the port.
    print("MOCK_CLOUD_PORT=%d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
