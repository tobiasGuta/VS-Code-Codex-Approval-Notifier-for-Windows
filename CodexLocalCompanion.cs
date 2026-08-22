using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class CodexLocalCompanion
{
    private sealed class PendingApproval
    {
        public string Handle;
        public object RequestId;
        public string ThreadId;
        public string TurnId;
        public string ItemId;
        public string Command;
        public string Cwd;
        public string Reason;
        public DateTimeOffset CreatedAt;
    }

    private static readonly object Sync = new object();
    private static readonly object SendSync = new object();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 100 };
    private static readonly Dictionary<string, PendingApproval> PendingByHandle = new Dictionary<string, PendingApproval>(StringComparer.Ordinal);
    private static readonly Dictionary<string, string> HandleByRequestId = new Dictionary<string, string>(StringComparer.Ordinal);

    private static ClientWebSocket AppSocket;
    private static string ThreadId;
    private static string ApiToken;
    private static HttpListener Listener;
    private static volatile bool Stopping;

    private static int Main(string[] args)
    {
        try
        {
            var parsed = ParseArgs(args);
            string descriptorPath = Require(parsed, "descriptor");
            ThreadId = Require(parsed, "thread");
            int port = parsed.ContainsKey("port") ? int.Parse(parsed["port"]) : 8765;
            string runtimeDir = parsed.ContainsKey("runtime-dir")
                ? parsed["runtime-dir"]
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexApprovalNotifier", "companion");

            Directory.CreateDirectory(runtimeDir);
            string apiTokenFile = Path.Combine(runtimeDir, "companion-" + Process.GetCurrentProcess().Id + ".token");
            string apiDescriptorFile = Path.Combine(runtimeDir, "companion-" + Process.GetCurrentProcess().Id + ".json");

            IDictionary descriptor = ReadJsonObject(descriptorPath);
            string wsUri = Convert.ToString(descriptor["uri"]);
            string bridgeTokenFile = Convert.ToString(descriptor["tokenFile"]);
            ValidateLoopbackWebSocket(wsUri);
            if (!File.Exists(bridgeTokenFile)) throw new InvalidOperationException("Bridge token file does not exist.");
            string bridgeToken = File.ReadAllText(bridgeTokenFile, Encoding.UTF8).Trim();
            if (string.IsNullOrWhiteSpace(bridgeToken)) throw new InvalidOperationException("Bridge token file was empty.");

            AppSocket = new ClientWebSocket();
            AppSocket.Options.SetRequestHeader("Authorization", "Bearer " + bridgeToken);
            using (var cts = new CancellationTokenSource(10000))
            {
                AppSocket.ConnectAsync(new Uri(wsUri), cts.Token).GetAwaiter().GetResult();
            }
            if (AppSocket.State != WebSocketState.Open) throw new InvalidOperationException("Failed to connect to Codex app-server.");

            BootstrapThreadSubscription();

            ApiToken = CreateToken();
            File.WriteAllText(apiTokenFile, ApiToken + Environment.NewLine, new UTF8Encoding(false));
            string apiBase = "http://127.0.0.1:" + port + "/";
            WriteCompanionDescriptor(apiDescriptorFile, apiBase, apiTokenFile, descriptorPath, ThreadId);

            Thread receiveThread = StartBackgroundThread(ReceiveLoop, "CodexCompanion-AppServerReceive");

            Listener = new HttpListener();
            Listener.Prefixes.Add(apiBase);
            Listener.Start();

            Console.WriteLine("Codex Local Companion started.");
            Console.WriteLine("Thread:     " + ThreadId);
            Console.WriteLine("API:        " + apiBase);
            Console.WriteLine("Descriptor: " + apiDescriptorFile);
            Console.WriteLine("Auth:       bearer token (not displayed)");
            Console.WriteLine("Scope:      loopback only; command approvals accept/decline only");

            try
            {
                while (!Stopping)
                {
                    HttpListenerContext context;
                    try { context = Listener.GetContext(); }
                    catch (HttpListenerException) { if (Stopping) break; throw; }
                    catch (ObjectDisposedException) { break; }
                    ThreadPool.QueueUserWorkItem(_ => HandleHttp(context));
                }
            }
            finally
            {
                Stopping = true;
                try { Listener.Stop(); } catch { }
                try { AppSocket.Dispose(); } catch { }
                try { receiveThread.Join(1500); } catch { }
                SafeDelete(apiDescriptorFile);
                SafeDelete(apiTokenFile);
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Codex Local Companion failed: " + ex.Message);
            return 90;
        }
    }

    private static void BootstrapThreadSubscription()
    {
        SendRequest(51001, "initialize", new Dictionary<string, object>
        {
            { "clientInfo", new Dictionary<string, object>
                {
                    { "name", "codex-local-companion" },
                    { "title", "Codex Local Companion" },
                    { "version", "0.1.0" }
                }
            },
            { "capabilities", new Dictionary<string, object> { { "experimentalApi", true } } }
        });
        IDictionary init = ReceiveResponseForId("51001", 15000, true);
        if (init.Contains("error")) throw new InvalidOperationException("initialize failed: " + Json.Serialize(init));
        SendObject(new Dictionary<string, object> { { "method", "initialized" } });

        SendRequest(51002, "thread/read", new Dictionary<string, object>
        {
            { "threadId", ThreadId }, { "includeTurns", false }
        });
        IDictionary read = ReceiveResponseForId("51002", 15000, true);
        if (read.Contains("error")) throw new InvalidOperationException("thread/read failed: " + Json.Serialize(read));
        IDictionary readResult = AsDictionary(read["result"]);
        IDictionary thread = AsDictionary(readResult["thread"]);
        if (!string.Equals(Convert.ToString(thread["id"]), ThreadId, StringComparison.Ordinal))
            throw new InvalidOperationException("thread/read returned a different thread id.");

        SendRequest(51003, "thread/resume", new Dictionary<string, object> { { "threadId", ThreadId } });
        IDictionary resume = ReceiveResponseForId("51003", 15000, true);
        if (resume.Contains("error")) throw new InvalidOperationException("thread/resume failed: " + Json.Serialize(resume));
    }

    private static void ReceiveLoop()
    {
        try
        {
            while (!Stopping && AppSocket.State == WebSocketState.Open)
            {
                string text = ReceiveText(Timeout.Infinite);
                if (text == null) break;
                IDictionary message = ReadJsonObjectFromText(text);
                HandleAppServerMessage(message);
            }
        }
        catch (Exception ex)
        {
            if (!Stopping)
            {
                Console.Error.WriteLine("App-server receive loop stopped: " + ex.Message);
                Stopping = true;
                try { Listener.Stop(); } catch { }
            }
        }
    }

    private static void HandleAppServerMessage(IDictionary message)
    {
        string method = message.Contains("method") ? Convert.ToString(message["method"]) : null;
        if (string.Equals(method, "item/commandExecution/requestApproval", StringComparison.Ordinal))
        {
            if (!message.Contains("id") || !message.Contains("params")) return;
            IDictionary p = AsDictionary(message["params"]);
            if (!string.Equals(Convert.ToString(p["threadId"]), ThreadId, StringComparison.Ordinal)) return;

            string requestKey = RequestKey(message["id"]);
            lock (Sync)
            {
                if (HandleByRequestId.ContainsKey(requestKey)) return;
                var approval = new PendingApproval
                {
                    Handle = Guid.NewGuid().ToString("N"),
                    RequestId = message["id"],
                    ThreadId = Convert.ToString(p["threadId"]),
                    TurnId = p.Contains("turnId") ? Convert.ToString(p["turnId"]) : null,
                    ItemId = p.Contains("itemId") ? Convert.ToString(p["itemId"]) : null,
                    Command = p.Contains("command") ? CommandText(p["command"]) : null,
                    Cwd = p.Contains("cwd") ? Convert.ToString(p["cwd"]) : null,
                    Reason = p.Contains("reason") ? Convert.ToString(p["reason"]) : null,
                    CreatedAt = DateTimeOffset.Now
                };
                PendingByHandle.Add(approval.Handle, approval);
                HandleByRequestId.Add(requestKey, approval.Handle);
                Console.WriteLine("Pending command approval: " + approval.Handle + "  " + approval.Command);
            }
            return;
        }

        if (string.Equals(method, "serverRequest/resolved", StringComparison.Ordinal) && message.Contains("params"))
        {
            IDictionary p = AsDictionary(message["params"]);
            if (!string.Equals(Convert.ToString(p["threadId"]), ThreadId, StringComparison.Ordinal)) return;
            if (!p.Contains("requestId")) return;
            RemovePendingByRequestId(p["requestId"]);
        }
    }

    private static void HandleHttp(HttpListenerContext context)
    {
        try
        {
            if (!IsAuthorized(context.Request))
            {
                WriteJson(context.Response, 401, new Dictionary<string, object> { { "error", "unauthorized" } });
                return;
            }

            string path = context.Request.Url.AbsolutePath.TrimEnd('/');
            string method = context.Request.HttpMethod.ToUpperInvariant();

            if (method == "GET" && (path == "" || path == "/health"))
            {
                WriteJson(context.Response, 200, new Dictionary<string, object>
                {
                    { "ok", true }, { "threadId", ThreadId }, { "pendingCount", PendingCount() }
                });
                return;
            }

            if (method == "GET" && path == "/api/status")
            {
                WriteJson(context.Response, 200, new Dictionary<string, object>
                {
                    { "connected", AppSocket != null && AppSocket.State == WebSocketState.Open },
                    { "threadId", ThreadId },
                    { "pendingCount", PendingCount() }
                });
                return;
            }

            if (method == "GET" && path == "/api/approvals")
            {
                WriteJson(context.Response, 200, new Dictionary<string, object> { { "data", SnapshotPending() } });
                return;
            }

            if (method == "POST" && path.StartsWith("/api/approvals/", StringComparison.Ordinal))
            {
                string[] parts = path.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 4 && string.Equals(parts[0], "api", StringComparison.Ordinal) && string.Equals(parts[1], "approvals", StringComparison.Ordinal))
                {
                    string handle = parts[2];
                    string decision = parts[3];
                    if (decision != "accept" && decision != "decline")
                    {
                        WriteJson(context.Response, 404, new Dictionary<string, object> { { "error", "not_found" } });
                        return;
                    }
                    ResolveApproval(context.Response, handle, decision);
                    return;
                }
            }

            WriteJson(context.Response, 404, new Dictionary<string, object> { { "error", "not_found" } });
        }
        catch (Exception ex)
        {
            try { WriteJson(context.Response, 500, new Dictionary<string, object> { { "error", "internal_error" }, { "message", ex.Message } }); } catch { }
        }
    }

    private static void ResolveApproval(HttpListenerResponse response, string handle, string decision)
    {
        PendingApproval approval;
        lock (Sync)
        {
            if (!PendingByHandle.TryGetValue(handle, out approval))
            {
                WriteJson(response, 409, new Dictionary<string, object> { { "error", "stale_or_resolved" } });
                return;
            }
            PendingByHandle.Remove(handle);
            HandleByRequestId.Remove(RequestKey(approval.RequestId));
        }

        try
        {
            SendObject(new Dictionary<string, object>
            {
                { "id", approval.RequestId },
                { "result", new Dictionary<string, object> { { "decision", decision } } }
            });
            WriteJson(response, 200, new Dictionary<string, object>
            {
                { "ok", true }, { "handle", handle }, { "decision", decision }
            });
        }
        catch
        {
            lock (Sync)
            {
                if (!PendingByHandle.ContainsKey(handle)) PendingByHandle.Add(handle, approval);
                string key = RequestKey(approval.RequestId);
                if (!HandleByRequestId.ContainsKey(key)) HandleByRequestId.Add(key, handle);
            }
            throw;
        }
    }

    private static bool IsAuthorized(HttpListenerRequest request)
    {
        string header = request.Headers["Authorization"];
        if (string.IsNullOrWhiteSpace(header) || !header.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        string supplied = header.Substring("Bearer ".Length).Trim();
        return FixedTimeEquals(ApiToken, supplied);
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

    private static object[] SnapshotPending()
    {
        lock (Sync)
        {
            var list = new List<object>();
            foreach (PendingApproval a in PendingByHandle.Values)
            {
                list.Add(new Dictionary<string, object>
                {
                    { "handle", a.Handle }, { "threadId", a.ThreadId }, { "turnId", a.TurnId }, { "itemId", a.ItemId },
                    { "command", a.Command }, { "cwd", a.Cwd }, { "reason", a.Reason }, { "createdAt", a.CreatedAt.ToString("o") }
                });
            }
            return list.ToArray();
        }
    }

    private static int PendingCount() { lock (Sync) { return PendingByHandle.Count; } }

    private static void RemovePendingByRequestId(object requestId)
    {
        string key = RequestKey(requestId);
        lock (Sync)
        {
            string handle;
            if (!HandleByRequestId.TryGetValue(key, out handle)) return;
            HandleByRequestId.Remove(key);
            PendingByHandle.Remove(handle);
        }
    }

    private static void SendRequest(int id, string method, object parameters)
    {
        var obj = new Dictionary<string, object> { { "id", id }, { "method", method } };
        if (parameters != null) obj["params"] = parameters;
        SendObject(obj);
    }

    private static void SendObject(object obj)
    {
        string text = Json.Serialize(obj);
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        lock (SendSync)
        {
            using (var cts = new CancellationTokenSource(10000))
            {
                AppSocket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();
            }
        }
    }

    private static IDictionary ReceiveResponseForId(string expectedId, int timeoutMs, bool processOtherMessages)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            int remaining = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
            string text = ReceiveText(remaining);
            IDictionary message = ReadJsonObjectFromText(text);
            bool hasMethod = message.Contains("method");
            if (!hasMethod && message.Contains("id") && string.Equals(Convert.ToString(message["id"]), expectedId, StringComparison.Ordinal)) return message;
            if (processOtherMessages) HandleAppServerMessage(message);
        }
        throw new TimeoutException("Timed out waiting for response id " + expectedId + ".");
    }

    private static string ReceiveText(int timeoutMs)
    {
        byte[] buffer = new byte[65536];
        using (var memory = new MemoryStream())
        {
            WebSocketReceiveResult result;
            do
            {
                CancellationToken token = CancellationToken.None;
                CancellationTokenSource cts = null;
                if (timeoutMs != Timeout.Infinite)
                {
                    cts = new CancellationTokenSource(timeoutMs);
                    token = cts.Token;
                }
                try { result = AppSocket.ReceiveAsync(new ArraySegment<byte>(buffer), token).GetAwaiter().GetResult(); }
                finally { if (cts != null) cts.Dispose(); }

                if (result.MessageType == WebSocketMessageType.Close) return null;
                if (result.MessageType != WebSocketMessageType.Text) throw new InvalidDataException("Unexpected binary frame from app-server.");
                if (result.Count > 0) memory.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);
            return Encoding.UTF8.GetString(memory.ToArray());
        }
    }

    private static IDictionary ReadJsonObject(string path) { return ReadJsonObjectFromText(File.ReadAllText(path, Encoding.UTF8)); }
    private static IDictionary ReadJsonObjectFromText(string text)
    {
        object value = Json.DeserializeObject(text);
        IDictionary d = value as IDictionary;
        if (d == null) throw new InvalidDataException("Expected JSON object.");
        return d;
    }
    private static IDictionary AsDictionary(object value)
    {
        IDictionary d = value as IDictionary;
        if (d == null) throw new InvalidDataException("Expected JSON object field.");
        return d;
    }

    private static void WriteJson(HttpListenerResponse response, int status, object body)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(Json.Serialize(body));
        response.StatusCode = status;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.Headers["Cache-Control"] = "no-store";
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.OutputStream.Close();
    }

    private static string CommandText(object command)
    {
        object[] array = command as object[];
        if (array != null)
        {
            var parts = new List<string>();
            foreach (object item in array) parts.Add(Convert.ToString(item));
            return string.Join(" ", parts.ToArray());
        }
        return Convert.ToString(command);
    }

    private static string RequestKey(object requestId)
    {
        return requestId == null ? "" : requestId.GetType().FullName + ":" + Convert.ToString(requestId, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Unexpected argument: " + arg);
            string key = arg.Substring(2);
            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --" + key);
            result[key] = args[++i];
        }
        return result;
    }

    private static string Require(Dictionary<string, string> args, string key)
    {
        string value;
        if (!args.TryGetValue(key, out value) || string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Missing required --" + key + ".");
        return value;
    }

    private static void ValidateLoopbackWebSocket(string value)
    {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || !string.Equals(uri.Scheme, "ws", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Bridge URI is not ws://.");
        if (uri.Host != "127.0.0.1" && uri.Host != "localhost" && uri.Host != "::1") throw new InvalidOperationException("Bridge URI is not loopback.");
    }

    private static void WriteCompanionDescriptor(string path, string apiBase, string tokenFile, string bridgeDescriptor, string threadId)
    {
        var d = new Dictionary<string, object>
        {
            { "version", 1 }, { "pid", Process.GetCurrentProcess().Id }, { "api", apiBase }, { "tokenFile", tokenFile },
            { "bridgeDescriptor", bridgeDescriptor }, { "threadId", threadId }, { "createdAt", DateTimeOffset.Now.ToString("o") }
        };
        File.WriteAllText(path, Json.Serialize(d), new UTF8Encoding(false));
    }

    private static string CreateToken()
    {
        byte[] bytes = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        var sb = new StringBuilder(64);
        foreach (byte b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    private static Thread StartBackgroundThread(ThreadStart action, string name)
    {
        var t = new Thread(action) { IsBackground = true, Name = name };
        t.Start();
        return t;
    }

    private static void SafeDelete(string path) { if (string.IsNullOrWhiteSpace(path)) return; try { File.Delete(path); } catch { } }
}
