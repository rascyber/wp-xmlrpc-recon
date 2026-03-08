from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time

TARGETS = {
    18080: {
        "plugins": ["contact-form-7", "woocommerce"],
        "users": [{"id": 1, "slug": "admin", "name": "Administrator"}],
        "posts": [{"id": 11, "slug": "hello-world", "status": "publish"}],
        "namespaces": ["wp/v2", "oembed/1.0", "acf/v3"],
        "routes": {
            "/": {},
            "/wp/v2/users": {},
            "/wp/v2/posts": {},
            "/acf/v3/options": {},
        },
        "xmlrpc_methods": [
            "system.listMethods",
            "system.multicall",
            "pingback.ping",
            "wp.getUsersBlogs",
        ],
        "login_rate_limit": "no",
    },
    18081: {
        "plugins": ["wordfence"],
        "users": [],
        "posts": [{"id": 22, "slug": "news", "status": "publish"}],
        "namespaces": ["wp/v2", "oembed/1.0"],
        "routes": {
            "/": {},
            "/wp/v2/posts": {},
        },
        "xmlrpc_methods": ["system.listMethods", "wp.getUsersBlogs"],
        "login_rate_limit": "yes",
    },
}


def html_page(port):
    target = TARGETS[port]
    plugin_refs = "".join(
        f'<script src="/wp-content/plugins/{plugin}/app.js"></script>'
        for plugin in target["plugins"]
    )
    return (
        '<!DOCTYPE html><html><head><meta name="generator" '
        'content="WordPress 6.8.1"></head><body>'
        '<a href="/author/admin/">Author</a>'
        f"{plugin_refs}</body></html>"
    ).encode()


def wp_json_root(port):
    target = TARGETS[port]
    return json.dumps(
        {
            "name": f"Mock WordPress {port}",
            "namespaces": target["namespaces"],
            "routes": target["routes"],
        }
    ).encode()


def xmlrpc_methods(port):
    values = "".join(
        f"<value><string>{method}</string></value>"
        for method in TARGETS[port]["xmlrpc_methods"]
    )
    return (
        "<?xml version='1.0'?>"
        "<methodResponse><params><param><value><array><data>"
        f"{values}"
        "</data></array></value></param></params></methodResponse>"
    ).encode()


AUTH_FAULT = (
    "<?xml version='1.0'?>"
    "<methodResponse><fault><value><struct>"
    "<member><name>faultCode</name><value><int>403</int></value></member>"
    "<member><name>faultString</name>"
    "<value><string>Incorrect username or password.</string></value></member>"
    "</struct></value></fault></methodResponse>"
).encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.path == "/":
            payload = html_page(port)
            code = 200
            content_type = "text/html"
        elif self.path == "/wp-json":
            payload = wp_json_root(port)
            code = 200
            content_type = "application/json"
        elif self.path == "/wp-json/wp/v2/users":
            payload = json.dumps(TARGETS[port]["users"]).encode()
            code = 200
            content_type = "application/json"
        elif self.path == "/wp-json/wp/v2/posts":
            payload = json.dumps(TARGETS[port]["posts"]).encode()
            code = 200
            content_type = "application/json"
        elif self.path == "/robots.txt":
            payload = (
                f"Allow: /wp-content/plugins/{TARGETS[port]['plugins'][0]}/\n"
            ).encode()
            code = 200
            content_type = "text/plain"
        elif self.path == "/wp-login.php":
            payload = (
                b'<html><body><form><input name="log"><input name="pwd">'
                b'<input type="submit" name="wp-submit"></form></body></html>'
            )
            code = 200
            content_type = "text/html"
        elif self.path == "/wp-admin/":
            payload = b"<html><body>admin</body></html>"
            code = 302
            content_type = "text/html"
        elif self.path == "/wp-sitemap-users-1.xml":
            payload = (
                b'<?xml version="1.0"?><urlset><url><loc>'
                b"http://127.0.0.1/author/admin/"
                b"</loc></url></urlset>"
            )
            code = 200
            content_type = "application/xml"
        elif self.path == "/feed":
            payload = (
                b'<?xml version="1.0"?><rss><channel><item>'
                b"<dc:creator><![CDATA[admin]]></dc:creator>"
                b"</item></channel></rss>"
            )
            code = 200
            content_type = "application/xml"
        elif self.path.startswith("/author/"):
            payload = b"<html><body>Author page</body></html>"
            code = 200
            content_type = "text/html"
        else:
            payload = b"not found"
            code = 404
            content_type = "text/plain"

        self.send_response(code)
        if self.path == "/wp-admin/":
            self.send_header("Location", "/wp-login.php")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        port = self.server.server_port
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "ignore")
        if self.path == "/xmlrpc.php":
            payload = xmlrpc_methods(port) if "system.listMethods" in body else AUTH_FAULT
            self.send_response(200)
            self.send_header("Content-Type", "text/xml")
        elif self.path == "/wp-login.php":
            payload = b'<div id="login_error">Invalid username</div>'
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            if TARGETS[port]["login_rate_limit"] == "yes":
                self.send_header("Retry-After", "60")
        else:
            payload = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")

        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


def main():
    servers = []
    for port in (18080, 18081):
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        servers.append(server)

    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
