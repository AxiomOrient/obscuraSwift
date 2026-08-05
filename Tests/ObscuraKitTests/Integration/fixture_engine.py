#!/usr/bin/env python3
"""Deterministic Obscura-compatible process fixture used by integration tests.

It intentionally implements only the exact product contract: discovery endpoints,
the browser WebSocket/session handshake, and the allow-listed CDP methods used by
ObscuraKit.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import html.parser
import json
import os
import re
import signal
import struct
import sys
import urllib.parse
from dataclasses import dataclass, field
from typing import Any

MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 16 * 1024 * 1024


def argument_value(name: str, default: str | None = None) -> str | None:
    try:
        index = sys.argv.index(name)
    except ValueError:
        return default
    if index + 1 >= len(sys.argv):
        return default
    return sys.argv[index + 1]


MODE = os.environ.get("OBSCURA_FIXTURE_MODE", "normal")
PORT = int(argument_value("--port", "9222") or "9222")
HOST = argument_value("--host", "127.0.0.1") or "127.0.0.1"
PID_FILE = os.environ.get("OBSCURA_FIXTURE_PID_FILE")
REQUEST_LOG = os.environ.get("OBSCURA_FIXTURE_REQUEST_LOG")
DELAYED_DISCOVERY_PENDING = MODE == "delayed-first-discovery"


@dataclass
class Element:
    tag: str
    attributes: dict[str, str]
    text: str = ""
    value: str = ""
    clicked: bool = False


class DocumentParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.in_title = False
        self.stack: list[Element] = []
        self.elements: dict[str, Element] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key: value or "" for key, value in attrs}
        if tag.lower() == "title":
            self.in_title = True
        element_id = attributes.get("id")
        if element_id is not None:
            element = Element(tag=tag.lower(), attributes=attributes, value=attributes.get("value", ""))
            self.elements[f"#{element_id}"] = element
            self.stack.append(element)
        else:
            self.stack.append(Element(tag=tag.lower(), attributes=attributes))

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if self.stack:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self.in_title = False
        if self.stack:
            self.stack.pop()

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)
        for element in self.stack:
            element.text += data

    @property
    def title(self) -> str:
        return "".join(self.title_parts)


@dataclass
class PageState:
    url: str = "about:blank"
    html: str = "<html><head></head><body></body></html>"
    title: str = ""
    elements: dict[str, Element] = field(default_factory=dict)
    cookies: list[dict[str, Any]] = field(default_factory=list)
    navigation_count: int = 0

    def navigate(self, url: str) -> None:
        self.url = url
        self.navigation_count += 1
        if url.startswith("data:"):
            header, payload = url.split(",", 1)
            if ";base64" in header:
                raw = base64.b64decode(payload).decode("utf-8")
            else:
                raw = urllib.parse.unquote(payload)
            self.html = raw
        elif url == "about:blank":
            self.html = "<html><head></head><body></body></html>"
        else:
            self.html = f"<html><head><title>Fixture</title></head><body><div id='url'>{url}</div></body></html>"
        parser = DocumentParser()
        parser.feed(self.html)
        self.title = parser.title
        self.elements = parser.elements


PAGE = PageState()
PAGE_TARGET_ID = "page-1"
PAGE_SESSION_ID = f"{PAGE_TARGET_ID}-session"
SHUTDOWN: asyncio.Event | None = None


def log_request(record: dict[str, Any]) -> None:
    if not REQUEST_LOG:
        return
    with open(REQUEST_LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def discovery_body(path: str) -> bytes:
    if MODE == "malformed-discovery" and path == "/json/version":
        return b"{not-json"
    if path == "/json/version":
        value = {
            "Browser": "Chrome/145.0.0.0",
            "Protocol-Version": "1.3",
            "V8-Version": "14.5.0",
            "webSocketDebuggerUrl": f"ws://127.0.0.1:{PORT}/devtools/browser",
        }
    elif path == "/json":
        value = [
            {
                "id": "page-1",
                "type": "page",
                "title": PAGE.title,
                "url": PAGE.url,
                "webSocketDebuggerUrl": f"ws://127.0.0.1:{PORT}/devtools/page/page-1",
            }
        ]
    elif path == "/json/protocol":
        if MODE == "missing-protocol":
            value = {}
        else:
            value = {"version": {"major": "1", "minor": "3"}}
    else:
        raise KeyError(path)
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


async def send_http(writer: asyncio.StreamWriter, status: str, body: bytes, content_type: str = "application/json") -> None:
    headers = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii")
    writer.write(headers + body)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def read_http_request(reader: asyncio.StreamReader) -> tuple[str, dict[str, str]]:
    data = await reader.readuntil(b"\r\n\r\n")
    if len(data) > 64 * 1024:
        raise ValueError("request headers too large")
    text = data.decode("latin-1")
    lines = text.split("\r\n")
    request = lines[0].split(" ")
    if len(request) != 3 or request[0] != "GET":
        raise ValueError("unsupported request")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return request[1], headers


async def read_exact(reader: asyncio.StreamReader, count: int) -> bytes:
    if count > MAX_FRAME:
        raise ValueError("frame too large")
    return await reader.readexactly(count)


async def read_ws_message(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    fragments = bytearray()
    initial_opcode: int | None = None
    while True:
        first, second = await read_exact(reader, 2)
        final = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", await read_exact(reader, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", await read_exact(reader, 8))[0]
        if length > MAX_FRAME:
            raise ValueError("frame too large")
        mask = await read_exact(reader, 4) if masked else b""
        payload = bytearray(await read_exact(reader, length))
        if masked:
            for index in range(length):
                payload[index] ^= mask[index % 4]
        if opcode in (0x8, 0x9, 0xA):
            return opcode, bytes(payload)
        if opcode != 0:
            if initial_opcode is not None:
                raise ValueError("nested fragmented message")
            initial_opcode = opcode
        elif initial_opcode is None:
            raise ValueError("unexpected continuation")
        fragments.extend(payload)
        if len(fragments) > MAX_FRAME:
            raise ValueError("message too large")
        if final:
            return initial_opcode or opcode, bytes(fragments)


async def send_ws_frame(writer: asyncio.StreamWriter, opcode: int, payload: bytes = b"") -> None:
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(length)
    elif length <= 0xFFFF:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    writer.write(bytes(header) + payload)
    await writer.drain()


async def send_ws_json(writer: asyncio.StreamWriter, value: dict[str, Any]) -> None:
    await send_ws_frame(writer, 0x1, json.dumps(value, separators=(",", ":")).encode("utf-8"))


def unwrap_source(expression: str) -> str:
    match = re.search(r"const __obscuraKitSource = (\"(?:\\.|[^\"\\])*\");", expression)
    if not match:
        raise ValueError("missing ObscuraKit source literal")
    return json.loads(match.group(1))


def selector_from_script(source: str) -> str | None:
    match = re.search(r"document\.querySelector\((\"(?:\\.|[^\"\\])*\")\)", source)
    return json.loads(match.group(1)) if match else None


def attribute_from_script(source: str) -> str | None:
    match = re.search(r"\.getAttribute\((\"(?:\\.|[^\"\\])*\")\)", source)
    return json.loads(match.group(1)) if match else None


def assigned_value_from_script(source: str) -> str | None:
    match = re.search(r"descriptor\.set\.call\(__obscuraKitElement, (\"(?:\\.|[^\"\\])*\")\)", source)
    return json.loads(match.group(1)) if match else None


def evaluate_source(source: str) -> Any:
    stripped = source.strip()
    if stripped == "document.title":
        return PAGE.title
    if stripped == "location.href":
        return "relative/path" if MODE == "invalid-current-url" else PAGE.url
    if stripped == "document.documentElement.outerHTML":
        return PAGE.html
    if stripped == "1 + 2":
        return 3
    if stripped in ("({ answer: 42, text: 'ok' })", '( { answer: 42, text: "ok" } )'):
        return {"answer": 42, "text": "ok"}
    if stripped == "Promise.resolve(7)":
        return 7
    if stripped == "__fixture_delay__":
        return "delayed"
    if stripped == "undefined":
        return _Undefined
    if stripped == "__fixture_throw__":
        raise RuntimeError("fixture JavaScript exception")
    if stripped == "__fixture_unserializable__":
        return {"unsupported": _Unserializable()}

    selector = selector_from_script(source)
    if selector is not None:
        element = PAGE.elements.get(selector)
        if element is None:
            return {"__obscuraKitElementMissing": True}
        value: Any
        if ".textContent" in source:
            value = element.text
        elif ".getAttribute(" in source:
            name = attribute_from_script(source)
            value = element.attributes.get(name or "")
        elif ".click()" in source:
            element.clicked = True
            value = True
        elif "descriptor.set.call" in source:
            value_to_set = assigned_value_from_script(source)
            if value_to_set is None:
                raise ValueError("missing setValue literal")
            element.value = value_to_set
            element.attributes["value"] = value_to_set
            value = True
        else:
            raise ValueError("unsupported locator operation")
        return {"__obscuraKitElementMissing": False, "value": value}

    # Explicit fixture-only introspection used by integration tests.
    if stripped.startswith("globalThis.__fixtureElementState("):
        literal = stripped[len("globalThis.__fixtureElementState(") : -1]
        selector = json.loads(literal)
        element = PAGE.elements.get(selector)
        return None if element is None else {"clicked": element.clicked, "value": element.value}
    raise ValueError(f"unsupported fixture expression: {stripped[:120]}")


class _UndefinedType:
    pass


class _Unserializable:
    pass


_Undefined = _UndefinedType()


def runtime_evaluate_result(expression: str) -> dict[str, Any]:
    try:
        source = unwrap_source(expression)
        value = evaluate_source(source)
    except RuntimeError as error:
        envelope = {"ok": False, "kind": "exception", "message": str(error)}
    except Exception as error:  # fixture protocol mismatch should be visible as JS failure
        envelope = {"ok": False, "kind": "exception", "message": f"fixture evaluator: {error}"}
    else:
        if value is _Undefined:
            envelope = {"ok": False, "kind": "unsupported", "message": "JavaScript returned undefined"}
        else:
            try:
                encoded = json.dumps(value, separators=(",", ":"))
            except (TypeError, ValueError) as error:
                envelope = {
                    "ok": False,
                    "kind": "unsupported",
                    "message": f"JavaScript result is not JSON-serializable: {error}",
                }
            else:
                envelope = {"ok": True, "json": encoded}
    return {"result": {"type": "object", "value": envelope}}


def normalize_cookie(raw: dict[str, Any]) -> dict[str, Any] | None:
    if not isinstance(raw.get("name"), str) or not isinstance(raw.get("value"), str):
        return None
    domain = raw.get("domain")
    if not isinstance(domain, str) or not domain:
        return None
    result: dict[str, Any] = {
        "name": raw["name"],
        "value": raw["value"],
        "domain": domain,
        "path": raw.get("path", "/"),
        "secure": bool(raw.get("secure", False)),
        "httpOnly": bool(raw.get("httpOnly", False)),
        "sameSite": raw.get("sameSite", "Lax"),
        "expires": raw.get("expires", -1),
    }
    return result


async def handle_cdp(request: dict[str, Any], writer: asyncio.StreamWriter) -> bool:
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}
    session_id = request.get("sessionId")
    log_request({"id": request_id, "method": method, "params": params, "sessionId": session_id})
    if not isinstance(request_id, int) or not isinstance(method, str) or not isinstance(params, dict):
        await send_ws_json(writer, {"id": request_id or 0, "error": {"code": -32600, "message": "invalid request"}})
        return True

    if MODE == "exit-on-first-command":
        os._exit(73)
    if MODE == "exit-on-evaluate" and method == "Runtime.evaluate":
        os._exit(74)
    if MODE == "wrong-response-id":
        await send_ws_json(writer, {"id": request_id + 10_000, "result": {}})
        return True
    if MODE == "malformed-cdp":
        await send_ws_frame(writer, 0x1, b"{malformed")
        return True

    if method == "Target.createTarget":
        if params.get("url") != "about:blank":
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32602, "message": "about:blank required"}})
            return True
        result = {"targetId": PAGE_TARGET_ID}
    elif method == "Target.attachToTarget":
        if params.get("targetId") != PAGE_TARGET_ID or params.get("flatten") is not True:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32602, "message": "page-1 with flatten required"}})
            return True
        result = {"sessionId": PAGE_SESSION_ID}
    elif method in ("Page.enable", "Runtime.enable", "Network.enable"):
        if session_id != PAGE_SESSION_ID:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": "No page for session"}})
            return True
        result: dict[str, Any] = {}
    elif method == "Browser.getVersion":
        result = {
            "protocolVersion": "1.3",
            "product": "Chrome/145.0.0.0",
            "revision": "fixture",
            "userAgent": "ObscuraFixture",
            "jsVersion": "14.5.0",
        }
    elif method == "Page.navigate":
        if session_id != PAGE_SESSION_ID:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": "No page for session"}})
            return True
        url = params.get("url")
        if not isinstance(url, str):
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32602, "message": "url required"}})
            return True
        PAGE.navigate(url)
        result = {"frameId": "main-frame", "loaderId": f"loader-{PAGE.navigation_count}"}
    elif method == "Runtime.evaluate":
        if session_id != PAGE_SESSION_ID:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": "No page for session"}})
            return True
        expression = params.get("expression")
        if not isinstance(expression, str):
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32602, "message": "expression required"}})
            return True
        try:
            source = unwrap_source(expression)
        except Exception:
            source = ""
        if source == "__fixture_delay__":
            delay = float(os.environ.get("OBSCURA_FIXTURE_DELAY_SECONDS", "2.0"))
            await asyncio.sleep(delay)
        result = runtime_evaluate_result(expression)
    elif method == "Network.setCookies":
        if session_id != PAGE_SESSION_ID:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": "No page for session"}})
            return True
        for raw in params.get("cookies", []):
            if not isinstance(raw, dict):
                continue
            cookie = normalize_cookie(raw)
            if cookie is None:
                continue
            PAGE.cookies = [
                existing
                for existing in PAGE.cookies
                if not (
                    existing["name"] == cookie["name"]
                    and existing["domain"] == cookie["domain"]
                    and existing["path"] == cookie["path"]
                )
            ]
            PAGE.cookies.append(cookie)
        result = {}
    elif method == "Network.getAllCookies":
        if session_id != PAGE_SESSION_ID:
            await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": "No page for session"}})
            return True
        result = {"cookies": PAGE.cookies}
    else:
        await send_ws_json(writer, {"id": request_id, "error": {"code": -32601, "message": f"unsupported method {method}"}})
        return True

    response: dict[str, Any] = {"id": request_id, "result": result}
    if isinstance(session_id, str):
        response["sessionId"] = session_id
    await send_ws_json(writer, response)
    return method != "Browser.close"


async def websocket_session(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while SHUTDOWN is not None and not SHUTDOWN.is_set():
        try:
            opcode, payload = await read_ws_message(reader)
        except (asyncio.IncompleteReadError, ConnectionError):
            return
        if opcode == 0x8:
            await send_ws_frame(writer, 0x8, payload[:125])
            return
        if opcode == 0x9:
            await send_ws_frame(writer, 0xA, payload[:125])
            continue
        if opcode == 0xA:
            continue
        if opcode not in (0x1, 0x2):
            await send_ws_frame(writer, 0x8, struct.pack("!H", 1003))
            return
        try:
            request = json.loads(payload.decode("utf-8"))
        except Exception:
            await send_ws_frame(writer, 0x1, b"{malformed")
            continue
        if not await handle_cdp(request, writer):
            return


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    global DELAYED_DISCOVERY_PENDING
    try:
        path, headers = await read_http_request(reader)
        log_request({"httpPath": path, "headers": headers})
        if headers.get("upgrade", "").lower() == "websocket":
            if path != "/devtools/browser":
                await send_http(writer, "404 Not Found", b"not found", "text/plain")
                return
            key = headers.get("sec-websocket-key")
            if not key:
                await send_http(writer, "400 Bad Request", b"missing key", "text/plain")
                return
            accept = base64.b64encode(hashlib.sha1((key + MAGIC).encode("ascii")).digest()).decode("ascii")
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            )
            writer.write(response.encode("ascii"))
            await writer.drain()
            await websocket_session(reader, writer)
            writer.close()
            await writer.wait_closed()
            return
        try:
            if (
                MODE == "accept-sensitive-protocol"
                and path == "/json/protocol"
                and headers.get("accept") == "application/json"
            ):
                body = discovery_body("/json")
            else:
                body = discovery_body(path)
        except KeyError:
            await send_http(writer, "404 Not Found", b"not found", "text/plain")
            return
        if DELAYED_DISCOVERY_PENDING and path == "/json/version":
            DELAYED_DISCOVERY_PENDING = False
            await asyncio.sleep(float(os.environ.get("OBSCURA_FIXTURE_DELAY_SECONDS", "0.75")))
        if MODE == "oversized-discovery" and path == "/json/version":
            body = b"x" * (2 * 1024 * 1024)
        if MODE == "duplicate-content-length" and path == "/json/version":
            header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            writer.write(header + body)
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return
        if MODE == "transfer-encoding" and path == "/json/version":
            header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                "Transfer-Encoding: chunked\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            writer.write(header + b"0\r\n\r\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return
        if MODE == "invalid-content-type" and path == "/json/version":
            header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/jsonBAD\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            writer.write(header + body)
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return
        if MODE == "signed-content-length" and path == "/json/version":
            header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                f"Content-Length: +{len(body)}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            writer.write(header + body)
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return
        await send_http(writer, "200 OK", body)
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main() -> int:
    global SHUTDOWN
    shutdown = asyncio.Event()
    SHUTDOWN = shutdown
    if PID_FILE:
        with open(PID_FILE, "w", encoding="ascii") as handle:
            handle.write(str(os.getpid()))
    if MODE == "early-exit":
        print("fixture early exit", file=sys.stderr, flush=True)
        return 72
    if MODE == "no-listen":
        await shutdown.wait()
        return 0
    if MODE == "stderr-flood":
        sys.stderr.write("X" * (2 * 1024 * 1024))
        sys.stderr.flush()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(signal_number, shutdown.set)
        except NotImplementedError:
            pass
    server = await asyncio.start_server(handle_client, HOST, PORT)
    async with server:
        await shutdown.wait()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        raise SystemExit(130)
