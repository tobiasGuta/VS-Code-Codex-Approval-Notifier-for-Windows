using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

internal static class CodexMobileUiServer
{
    private static TcpListener Listener;
    private static volatile bool Stopping;
    private static string GatewayBase;
    private static string WebRoot;

    private static int Main(string[] args)
    {
        try
        {
            var parsed = ParseArgs(args);
            string listenAddressText = Require(parsed, "listen-address");
            int port = parsed.ContainsKey("port") ? int.Parse(parsed["port"]) : 8767;
            GatewayBase = Require(parsed, "gateway-base");
            WebRoot = Path.GetFullPath(Require(parsed, "web-root"));

            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            IPAddress listenAddress;
            if (!IPAddress.TryParse(listenAddressText, out listenAddress) || listenAddress.AddressFamily != AddressFamily.InterNetwork)
                throw new InvalidOperationException("listen-address must be an explicit IPv4 address.");
            if (IPAddress.Any.Equals(listenAddress)) throw new InvalidOperationException("0.0.0.0 is not allowed.");
            if (!IsPrivateOrLoopback(listenAddress)) throw new InvalidOperationException("listen-address must be private IPv4 or loopback.");
            if (!GatewayBase.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("gateway-base must use http:// for this prototype.");
            if (!Directory.Exists(WebRoot)) throw new InvalidOperationException("web-root does not exist: " + WebRoot);

            RequireAsset("index.html");
            RequireAsset("app.js");
            RequireAsset("app.css");

            // Verify the gateway before opening the mobile listener.
            Proxy("GET", "pairing/status", null);

            Listener = new TcpListener(listenAddress, port);
            Listener.Start();
            int actualPort = ((IPEndPoint)Listener.LocalEndpoint).Port;
            Console.WriteLine("Codex Mobile UI Server started.");
            Console.WriteLine("Mobile UI:  http://" + listenAddress + ":" + actualPort + "/");
            Console.WriteLine("Gateway:    " + GatewayBase);
            Console.WriteLine("Web root:   " + WebRoot);
            Console.WriteLine("Scope:      static mobile UI + allowlisted LAN gateway proxy only");
            Console.WriteLine("WARNING:    prototype transport is HTTP on the trusted home LAN.");

            while (!Stopping)
            {
                TcpClient client;
                try { client = Listener.AcceptTcpClient(); }
                catch (SocketException) { if (Stopping) break; throw; }
                catch (ObjectDisposedException) { break; }
                ThreadPool.QueueUserWorkItem(_ => HandleClient(client));
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Codex Mobile UI Server failed: " + ex.Message);
            return 92;
        }
        finally
        {
            Stopping = true;
            try { if (Listener != null) Listener.Stop(); } catch { }
        }
    }

    private static void HandleClient(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                NetworkStream stream = client.GetStream();
                var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
                string requestLine = reader.ReadLine();
                if (string.IsNullOrWhiteSpace(requestLine)) return;
                string[] parts = requestLine.Split(' ');
                if (parts.Length != 3) { WriteText(stream, 400, "text/plain; charset=utf-8", "bad request", false); return; }

                string method = parts[0].ToUpperInvariant();
                Uri target;
                if (!Uri.TryCreate("http://mobile" + parts[1], UriKind.Absolute, out target)) { WriteText(stream, 400, "text/plain; charset=utf-8", "bad request", false); return; }
                string path = target.AbsolutePath;

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (true)
                {
                    string line = reader.ReadLine();
                    if (line == null || line.Length == 0) break;
                    int colon = line.IndexOf(':');
                    if (colon <= 0) continue;
                    headers[line.Substring(0, colon).Trim()] = line.Substring(colon + 1).Trim();
                }

                if (method == "GET" && path == "/") { WriteAsset(stream, "index.html", "text/html; charset=utf-8"); return; }
                if (method == "GET" && path == "/app.js") { WriteAsset(stream, "app.js", "application/javascript; charset=utf-8"); return; }
                if (method == "GET" && path == "/app.css") { WriteAsset(stream, "app.css", "text/css; charset=utf-8"); return; }

                string relative;
                if (!TryMapProxyRoute(method, path, out relative)) { WriteText(stream, 404, "application/json; charset=utf-8", "{\"error\":\"not_found\"}", false); return; }

                Dictionary<string, string> forwardHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                string value;
                if (headers.TryGetValue("Authorization", out value)) forwardHeaders["Authorization"] = value;
                if (headers.TryGetValue("X-Pairing-Code", out value)) forwardHeaders["X-Pairing-Code"] = value;

                ProxyResult proxied = Proxy(method, relative, forwardHeaders);
                WriteText(stream, proxied.Status, "application/json; charset=utf-8", proxied.Body, false);
            }
            catch (Exception ex)
            {
                try { WriteText(client.GetStream(), 502, "application/json; charset=utf-8", "{\"error\":\"mobile_proxy_error\",\"message\":" + JsonString(ex.Message) + "}", false); } catch { }
            }
        }
    }

    private static bool TryMapProxyRoute(string method, string path, out string relative)
    {
        relative = null;
        if (method == "GET" && path == "/pairing/status") { relative = "pairing/status"; return true; }
        if (method == "POST" && path == "/pair") { relative = "pair"; return true; }
        if (method == "GET" && path == "/api/status") { relative = "api/status"; return true; }
        if (method == "GET" && path == "/api/approvals") { relative = "api/approvals"; return true; }
        if (method == "POST" && path == "/api/device/revoke") { relative = "api/device/revoke"; return true; }
        if (method == "POST" && path.StartsWith("/api/approvals/", StringComparison.Ordinal))
        {
            string[] route = path.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (route.Length == 4 && route[0] == "api" && route[1] == "approvals" && IsOpaqueHandle(route[2]) && (route[3] == "accept" || route[3] == "decline"))
            {
                relative = "api/approvals/" + route[2] + "/" + route[3];
                return true;
            }
        }
        return false;
    }

    private sealed class ProxyResult { public int Status; public string Body; }

    private static ProxyResult Proxy(string method, string relative, IDictionary<string, string> headers)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(GatewayBase + relative);
        request.Method = method;
        request.Timeout = 5000;
        request.ReadWriteTimeout = 5000;
        request.KeepAlive = false;
        if (headers != null)
        {
            string value;
            if (headers.TryGetValue("Authorization", out value)) request.Headers[HttpRequestHeader.Authorization] = value;
            if (headers.TryGetValue("X-Pairing-Code", out value)) request.Headers["X-Pairing-Code"] = value;
        }
        try
        {
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                return new ProxyResult { Status = (int)response.StatusCode, Body = ReadAll(response.GetResponseStream()) };
        }
        catch (WebException ex)
        {
            HttpWebResponse response = ex.Response as HttpWebResponse;
            if (response == null) throw;
            using (response)
                return new ProxyResult { Status = (int)response.StatusCode, Body = ReadAll(response.GetResponseStream()) };
        }
    }

    private static void WriteAsset(NetworkStream stream, string name, string contentType)
    {
        string path = Path.Combine(WebRoot, name);
        byte[] bytes = File.ReadAllBytes(path);
        WriteBytes(stream, 200, contentType, bytes, true);
    }

    private static void WriteText(NetworkStream stream, int status, string contentType, string text, bool csp)
    {
        WriteBytes(stream, status, contentType, Encoding.UTF8.GetBytes(text ?? string.Empty), csp);
    }

    private static void WriteBytes(NetworkStream stream, int status, string contentType, byte[] body, bool csp)
    {
        string reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : status == 410 ? "Gone" : status == 429 ? "Too Many Requests" : status == 502 ? "Bad Gateway" : "Error";
        var sb = new StringBuilder();
        sb.Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
        sb.Append("Content-Type: ").Append(contentType).Append("\r\n");
        sb.Append("Content-Length: ").Append(body.Length).Append("\r\n");
        sb.Append("Cache-Control: no-store\r\n");
        sb.Append("X-Content-Type-Options: nosniff\r\n");
        sb.Append("Referrer-Policy: no-referrer\r\n");
        sb.Append("X-Frame-Options: DENY\r\n");
        if (csp) sb.Append("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n");
        sb.Append("Connection: close\r\n\r\n");
        byte[] head = Encoding.ASCII.GetBytes(sb.ToString());
        stream.Write(head, 0, head.Length);
        stream.Write(body, 0, body.Length);
        stream.Flush();
    }

    private static bool IsOpaqueHandle(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length != 32) return false;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    private static bool IsPrivateOrLoopback(IPAddress address)
    {
        if (IPAddress.IsLoopback(address)) return true;
        byte[] b = address.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
    }

    private static void RequireAsset(string name)
    {
        string path = Path.Combine(WebRoot, name);
        if (!File.Exists(path)) throw new InvalidOperationException("Missing mobile asset: " + path);
    }

    private static string ReadAll(Stream stream)
    {
        if (stream == null) return "{}";
        using (stream)
        using (var reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Unknown argument: " + args[i]);
            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for " + args[i]);
            result[args[i].Substring(2)] = args[++i];
        }
        return result;
    }

    private static string Require(Dictionary<string, string> args, string name)
    {
        string value;
        if (!args.TryGetValue(name, out value) || string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Missing --" + name);
        return value;
    }

    private static string JsonString(string value)
    {
        return "\"" + (value ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
    }
}
