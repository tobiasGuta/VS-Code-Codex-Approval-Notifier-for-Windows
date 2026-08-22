using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class CodexLanGateway
{
    private sealed class PairRate
    {
        public int Failures;
        public DateTimeOffset WindowStarted;
    }

    private static readonly object Sync = new object();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 100 };
    private static readonly Dictionary<string, PairRate> PairRates = new Dictionary<string, PairRate>(StringComparer.Ordinal);

    private static TcpListener Listener;
    private static volatile bool Stopping;
    private static string CompanionApi;
    private static string CompanionToken;
    private static string PairingCode;
    private static DateTimeOffset PairingExpiresAt;
    private static bool PairingConsumed;
    private static string DeviceToken;

    private static int Main(string[] args)
    {
        string descriptorFile = null;
        try
        {
            Dictionary<string, string> parsed = ParseArgs(args);
            string companionDescriptorPath = Require(parsed, "companion-descriptor");
            string listenAddressText = Require(parsed, "listen-address");
            int port = parsed.ContainsKey("port") ? int.Parse(parsed["port"]) : 8766;
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");

            IPAddress listenAddress;
            if (!IPAddress.TryParse(listenAddressText, out listenAddress) || listenAddress.AddressFamily != AddressFamily.InterNetwork)
                throw new InvalidOperationException("listen-address must be an explicit IPv4 address.");
            if (IPAddress.Any.Equals(listenAddress))
                throw new InvalidOperationException("0.0.0.0 is not allowed. Bind the gateway to one explicit interface address.");
            if (!IsPrivateOrLoopback(listenAddress))
                throw new InvalidOperationException("listen-address must be loopback or an RFC1918 private IPv4 address.");

            IDictionary<string, object> companion = ReadJson(companionDescriptorPath);
            CompanionApi = Convert.ToString(companion["api"]);
            string companionTokenFile = Convert.ToString(companion["tokenFile"]);
            int companionPid = Convert.ToInt32(companion["pid"]);
            if (!CompanionApi.StartsWith("http://127.0.0.1:", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Companion API must remain loopback-only.");
            if (Process.GetProcessById(companionPid) == null)
                throw new InvalidOperationException("Companion process is not running.");
            if (!File.Exists(companionTokenFile))
                throw new InvalidOperationException("Companion token file does not exist.");
            CompanionToken = File.ReadAllText(companionTokenFile, Encoding.UTF8).Trim();
            if (string.IsNullOrWhiteSpace(CompanionToken))
                throw new InvalidOperationException("Companion token file is empty.");

            // Verify the companion before exposing any LAN listener.
            ProxyJson("GET", "api/status");

            PairingCode = CreateNumericCode(6);
            PairingExpiresAt = DateTimeOffset.Now.AddMinutes(5);
            PairingConsumed = false;
            DeviceToken = null;

            string runtimeDir = parsed.ContainsKey("runtime-dir")
                ? parsed["runtime-dir"]
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexApprovalNotifier", "lan-gateway");
            Directory.CreateDirectory(runtimeDir);

            Listener = new TcpListener(listenAddress, port);
            Listener.Start();
            int actualPort = ((IPEndPoint)Listener.LocalEndpoint).Port;
            string baseUrl = "http://" + listenAddress + ":" + actualPort + "/";

            descriptorFile = Path.Combine(runtimeDir, "gateway-" + Process.GetCurrentProcess().Id + ".json");
            WriteDescriptor(descriptorFile, baseUrl, companionDescriptorPath, PairingExpiresAt);

            Console.WriteLine("Codex LAN Gateway started.");
            Console.WriteLine("LAN API:     " + baseUrl);
            Console.WriteLine("Descriptor:  " + descriptorFile);
            Console.WriteLine("Pairing code: " + PairingCode);
            Console.WriteLine("Expires:      " + PairingExpiresAt.ToString("o"));
            Console.WriteLine("Scope:        status + command approvals accept/decline only");
            Console.WriteLine("Security:     explicit private IPv4 bind; one-time pairing; single in-memory device token");
            Console.WriteLine("WARNING:      prototype uses HTTP on the trusted home LAN; HTTPS is not enabled yet.");

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
            Console.Error.WriteLine("Codex LAN Gateway failed: " + ex.Message);
            return 91;
        }
        finally
        {
            Stopping = true;
            try { if (Listener != null) Listener.Stop(); } catch { }
            SafeDelete(descriptorFile);
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
                if (parts.Length != 3)
                {
                    WriteJson(stream, 400, Obj("error", "bad_request"));
                    return;
                }

                string method = parts[0].ToUpperInvariant();
                Uri target;
                if (!Uri.TryCreate("http://gateway" + parts[1], UriKind.Absolute, out target))
                {
                    WriteJson(stream, 400, Obj("error", "bad_request"));
                    return;
                }
                string path = target.AbsolutePath.TrimEnd('/');

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (true)
                {
                    string line = reader.ReadLine();
                    if (line == null || line.Length == 0) break;
                    int colon = line.IndexOf(':');
                    if (colon <= 0) continue;
                    headers[line.Substring(0, colon).Trim()] = line.Substring(colon + 1).Trim();
                }

                string remoteIp = ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString();

                if (method == "GET" && path == "/pairing/status")
                {
                    bool available;
                    DateTimeOffset expires;
                    lock (Sync) { available = !PairingConsumed && DateTimeOffset.Now < PairingExpiresAt; expires = PairingExpiresAt; }
                    WriteJson(stream, 200, new Dictionary<string, object>
                    {
                        { "pairingAvailable", available },
                        { "expiresAt", expires.ToString("o") },
                        { "paired", HasDeviceToken() }
                    });
                    return;
                }

                if (method == "POST" && path == "/pair")
                {
                    string supplied;
                    headers.TryGetValue("X-Pairing-Code", out supplied);
                    HandlePair(stream, remoteIp, supplied);
                    return;
                }

                if (!IsDeviceAuthorized(headers))
                {
                    WriteJson(stream, 401, Obj("error", "unauthorized"));
                    return;
                }

                if (method == "POST" && path == "/api/device/revoke")
                {
                    lock (Sync) { DeviceToken = null; }
                    WriteJson(stream, 200, new Dictionary<string, object> { { "ok", true }, { "revoked", true } });
                    return;
                }

                if (method == "GET" && path == "/api/status")
                {
                    WriteProxy(stream, ProxyJson("GET", "api/status"));
                    return;
                }
                if (method == "GET" && path == "/api/approvals")
                {
                    WriteProxy(stream, ProxyJson("GET", "api/approvals"));
                    return;
                }
                if (method == "POST" && path.StartsWith("/api/approvals/", StringComparison.Ordinal))
                {
                    string[] route = path.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                    if (route.Length == 4 && route[0] == "api" && route[1] == "approvals" &&
                        (route[3] == "accept" || route[3] == "decline") && IsOpaqueHandle(route[2]))
                    {
                        WriteProxy(stream, ProxyJson("POST", "api/approvals/" + route[2] + "/" + route[3]));
                        return;
                    }
                }

                WriteJson(stream, 404, Obj("error", "not_found"));
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                int status = response != null ? (int)response.StatusCode : 502;
                string body = response != null ? ReadAll(response.GetResponseStream()) : Json.Serialize(Obj("error", "companion_unavailable"));
                try { WriteRawJson(client.GetStream(), status, body); } catch { }
            }
            catch (Exception ex)
            {
                try { WriteJson(client.GetStream(), 500, new Dictionary<string, object> { { "error", "internal_error" }, { "message", ex.Message } }); } catch { }
            }
        }
    }

    private static void HandlePair(NetworkStream stream, string remoteIp, string supplied)
    {
        DateTimeOffset now = DateTimeOffset.Now;
        lock (Sync)
        {
            PairRate rate;
            if (!PairRates.TryGetValue(remoteIp, out rate) || now - rate.WindowStarted > TimeSpan.FromMinutes(5))
            {
                rate = new PairRate { Failures = 0, WindowStarted = now };
                PairRates[remoteIp] = rate;
            }
            if (rate.Failures >= 5)
            {
                WriteJson(stream, 429, Obj("error", "pairing_rate_limited"));
                return;
            }
            if (PairingConsumed)
            {
                WriteJson(stream, 409, Obj("error", "pairing_already_used"));
                return;
            }
            if (now >= PairingExpiresAt)
            {
                WriteJson(stream, 410, Obj("error", "pairing_expired"));
                return;
            }
            if (string.IsNullOrWhiteSpace(supplied) || !FixedTimeEquals(PairingCode, supplied.Trim()))
            {
                rate.Failures++;
                WriteJson(stream, 401, Obj("error", "invalid_pairing_code"));
                return;
            }

            DeviceToken = CreateToken();
            PairingConsumed = true;
            rate.Failures = 0;
            WriteJson(stream, 200, new Dictionary<string, object>
            {
                { "ok", true },
                { "deviceToken", DeviceToken },
                { "tokenType", "Bearer" }
            });
        }
    }

    private static string ProxyJson(string method, string relativePath)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(CompanionApi + relativePath);
        request.Method = method;
        request.Headers[HttpRequestHeader.Authorization] = "Bearer " + CompanionToken;
        request.Timeout = 5000;
        request.ReadWriteTimeout = 5000;
        request.KeepAlive = false;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        {
            return ReadAll(response.GetResponseStream());
        }
    }

    private static void WriteProxy(NetworkStream stream, string json)
    {
        WriteRawJson(stream, 200, json);
    }

    private static bool IsDeviceAuthorized(IDictionary<string, string> headers)
    {
        string token;
        lock (Sync) { token = DeviceToken; }
        if (string.IsNullOrWhiteSpace(token)) return false;
        string header;
        if (!headers.TryGetValue("Authorization", out header)) return false;
        if (string.IsNullOrWhiteSpace(header) || !header.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        return FixedTimeEquals(token, header.Substring("Bearer ".Length).Trim());
    }

    private static bool HasDeviceToken() { lock (Sync) { return !string.IsNullOrWhiteSpace(DeviceToken); } }

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

    private static string CreateNumericCode(int digits)
    {
        byte[] bytes = new byte[4];
        using (var rng = RandomNumberGenerator.Create()) { rng.GetBytes(bytes); }
        uint value = BitConverter.ToUInt32(bytes, 0);
        uint modulus = 1;
        for (int i = 0; i < digits; i++) modulus *= 10;
        return (value % modulus).ToString(new string('0', digits));
    }

    private static string CreateToken()
    {
        byte[] bytes = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) { rng.GetBytes(bytes); }
        var sb = new StringBuilder(64);
        foreach (byte b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    private static bool FixedTimeEquals(string a, string b)
    {
        if (a == null || b == null) return false;
        byte[] aa = Encoding.UTF8.GetBytes(a);
        byte[] bb = Encoding.UTF8.GetBytes(b);
        int diff = aa.Length ^ bb.Length;
        int max = Math.Max(aa.Length, bb.Length);
        for (int i = 0; i < max; i++)
        {
            byte av = i < aa.Length ? aa[i] : (byte)0;
            byte bv = i < bb.Length ? bb[i] : (byte)0;
            diff |= av ^ bv;
        }
        return diff == 0;
    }

    private static void WriteDescriptor(string path, string api, string companionDescriptor, DateTimeOffset expires)
    {
        var data = new Dictionary<string, object>
        {
            { "version", 1 }, { "pid", Process.GetCurrentProcess().Id }, { "api", api },
            { "companionDescriptor", companionDescriptor }, { "pairingExpiresAt", expires.ToString("o") }
        };
        File.WriteAllText(path, Json.Serialize(data), new UTF8Encoding(false));
    }

    private static IDictionary<string, object> ReadJson(string path)
    {
        object value = Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
        IDictionary<string, object> dict = value as IDictionary<string, object>;
        if (dict == null) throw new InvalidDataException("Expected JSON object: " + path);
        return dict;
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Unknown argument: " + arg);
            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for " + arg);
            result[arg.Substring(2)] = args[++i];
        }
        return result;
    }

    private static string Require(Dictionary<string, string> args, string name)
    {
        string value;
        if (!args.TryGetValue(name, out value) || string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Missing --" + name);
        return value;
    }

    private static Dictionary<string, object> Obj(string key, object value)
    {
        return new Dictionary<string, object> { { key, value } };
    }

    private static string ReadAll(Stream stream)
    {
        if (stream == null) return "{}";
        using (stream)
        using (var reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static void WriteJson(NetworkStream stream, int status, object body) { WriteRawJson(stream, status, Json.Serialize(body)); }

    private static void WriteRawJson(NetworkStream stream, int status, string body)
    {
        byte[] bodyBytes = Encoding.UTF8.GetBytes(body ?? "{}");
        string reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : status == 410 ? "Gone" : status == 429 ? "Too Many Requests" : status == 502 ? "Bad Gateway" : "Internal Server Error";
        string headers = "HTTP/1.1 " + status + " " + reason + "\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: " + bodyBytes.Length + "\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
        stream.Write(headerBytes, 0, headerBytes.Length);
        stream.Write(bodyBytes, 0, bodyBytes.Length);
        stream.Flush();
    }

    private static void SafeDelete(string path) { if (!string.IsNullOrWhiteSpace(path)) { try { File.Delete(path); } catch { } } }
}
