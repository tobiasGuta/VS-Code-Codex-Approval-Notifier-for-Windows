using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class CodexLocalCompanion
{
    private enum ApprovalState
    {
        Pending,
        UserClaimed,
        ExpiredDeclinePending
    }

    private enum ApprovalKind
    {
        Command,
        FileChange
    }

    private sealed class FileChangeEvidence
    {
        public object[] Changes;
        public string Signature;
        public bool AllowOnceAvailable;
        public string EvidenceStatus;
    }

    private sealed class PendingApproval
    {
        public string Handle;
        public object RequestId;
        public ApprovalKind Kind;
        public string ThreadId;
        public string TurnId;
        public string ItemId;
        public string Command;
        public string Cwd;
        public string Reason;
        public FileChangeEvidence FileEvidence;
        public string ClaimedEvidenceSignature;
        public bool EvidenceChangedSinceClaim;
        public DateTimeOffset CreatedAt;
        public DateTimeOffset ExpiresAt;
        public DateTimeOffset NextExpiryAttemptAt;
        public ApprovalState State;
    }

    private static readonly object Sync = new object();
    private static readonly object SendSync = new object();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 100 };
    private static readonly Dictionary<string, PendingApproval> PendingByHandle = new Dictionary<string, PendingApproval>(StringComparer.Ordinal);
    private static readonly Dictionary<string, PendingApproval> ActiveByRequestId = new Dictionary<string, PendingApproval>(StringComparer.Ordinal);
    private static readonly HashSet<string> CompletedRequestIds = new HashSet<string>(StringComparer.Ordinal);
    private static readonly Dictionary<string, FileChangeEvidence> FileEvidenceByItem = new Dictionary<string, FileChangeEvidence>(StringComparer.Ordinal);
    private static readonly HashSet<string> TerminalFileItems = new HashSet<string>(StringComparer.Ordinal);
    private static readonly List<IDictionary> QuarantinedFileMessages = new List<IDictionary>();

    private static ClientWebSocket AppSocket;
    private static string ThreadId;
    private static string ApiToken;
    private static TcpListener ApiListener;
    private static volatile bool Stopping;
    private static bool Resuming;
    private static int ApprovalTtlSeconds = 300;
    private static int ExpiredDeclineCount;
    private const int MaxFileChangeCount = 100;
    private const int MaxFileEvidenceBytes = 262144;

    private static int Main(string[] args)
    {
        string apiDescriptorFile = null;
        string apiTokenFile = null;
        try
        {
            var parsed = ParseArgs(args);
            string descriptorPath = Require(parsed, "descriptor");
            ThreadId = Require(parsed, "thread");
            int port = parsed.ContainsKey("port") ? int.Parse(parsed["port"]) : 8765;
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            ApprovalTtlSeconds = parsed.ContainsKey("approval-ttl-seconds") ? int.Parse(parsed["approval-ttl-seconds"]) : 300;
            if (ApprovalTtlSeconds < 5 || ApprovalTtlSeconds > 3600)
                throw new ArgumentOutOfRangeException("approval-ttl-seconds", "approval-ttl-seconds must be between 5 and 3600.");
            string runtimeDir = parsed.ContainsKey("runtime-dir")
                ? parsed["runtime-dir"]
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexApprovalNotifier", "companion");

            Directory.CreateDirectory(runtimeDir);
            apiTokenFile = Path.Combine(runtimeDir, "companion-" + Process.GetCurrentProcess().Id + ".token");
            apiDescriptorFile = Path.Combine(runtimeDir, "companion-" + Process.GetCurrentProcess().Id + ".json");

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

            ApiListener = new TcpListener(IPAddress.Loopback, port);
            ApiListener.Start();
            int actualPort = ((IPEndPoint)ApiListener.LocalEndpoint).Port;
            string apiBase = "http://127.0.0.1:" + actualPort + "/";
            WriteCompanionDescriptor(apiDescriptorFile, apiBase, apiTokenFile, descriptorPath, ThreadId);

            Thread receiveThread = StartBackgroundThread(ReceiveLoop, "CodexCompanion-AppServerReceive");
            Thread expiryThread = StartBackgroundThread(ExpiryLoop, "CodexCompanion-ApprovalExpiry");

            Console.WriteLine("Codex Local Companion started.");
            Console.WriteLine("Thread:       " + ThreadId);
            Console.WriteLine("API:          " + apiBase);
            Console.WriteLine("Descriptor:   " + apiDescriptorFile);
            Console.WriteLine("Approval TTL: " + ApprovalTtlSeconds + " seconds (expired approvals auto-decline)");
            Console.WriteLine("Auth:         bearer token (not displayed)");
            Console.WriteLine("Scope:        loopback only; command and file-change approvals accept/decline only");

            try
            {
                while (!Stopping)
                {
                    TcpClient client;
                    try { client = ApiListener.AcceptTcpClient(); }
                    catch (SocketException) { if (Stopping) break; throw; }
                    catch (ObjectDisposedException) { break; }
                    ThreadPool.QueueUserWorkItem(_ => HandleHttp(client));
                }
            }
            finally
            {
                Stopping = true;
                try { ApiListener.Stop(); } catch { }
                try { AppSocket.Dispose(); } catch { }
                try { receiveThread.Join(1500); } catch { }
                try { expiryThread.Join(1500); } catch { }
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Codex Local Companion failed: " + ex.Message);
            return 90;
        }
        finally
        {
            Stopping = true;
            try { if (ApiListener != null) ApiListener.Stop(); } catch { }
            try { if (AppSocket != null) AppSocket.Dispose(); } catch { }
            SafeDelete(apiDescriptorFile);
            SafeDelete(apiTokenFile);
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
                    { "version", "0.2.0" }
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

        lock (Sync) { Resuming = true; QuarantinedFileMessages.Clear(); }
        SendRequest(51003, "thread/resume", new Dictionary<string, object> { { "threadId", ThreadId } });
        IDictionary resume = ReceiveResponseForId("51003", 15000, true);
        if (resume.Contains("error")) throw new InvalidOperationException("thread/resume failed: " + Json.Serialize(resume));

        List<IDictionary> replay;
        lock (Sync)
        {
            Resuming = false;
            replay = new List<IDictionary>(QuarantinedFileMessages);
            QuarantinedFileMessages.Clear();
        }
        foreach (IDictionary message in replay) HandleAppServerMessageCore(message);
    }

    private static void ReceiveLoop()
    {
        try
        {
            while (!Stopping && AppSocket.State == WebSocketState.Open)
            {
                string text = ReceiveText(Timeout.Infinite);
                if (text == null) break;
                HandleAppServerMessage(ReadJsonObjectFromText(text));
            }
        }
        catch (Exception ex)
        {
            if (!Stopping)
            {
                Console.Error.WriteLine("App-server receive loop stopped: " + ex.Message);
                Stopping = true;
                try { ApiListener.Stop(); } catch { }
            }
        }
    }

    private static void ExpiryLoop()
    {
        while (!Stopping)
        {
            try
            {
                foreach (PendingApproval approval in CollectDueExpiryDeclines())
                {
                    if (Stopping) break;
                    SendExpiredDecline(approval);
                }
            }
            catch (Exception ex)
            {
                if (!Stopping) Console.Error.WriteLine("Approval expiry loop error: " + ex.Message);
            }
            for (int i = 0; i < 4 && !Stopping; i++) Thread.Sleep(50);
        }
    }

    private static List<PendingApproval> CollectDueExpiryDeclines()
    {
        var due = new List<PendingApproval>();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        lock (Sync)
        {
            foreach (PendingApproval approval in ActiveByRequestId.Values)
            {
                if (approval.State == ApprovalState.Pending && now >= approval.ExpiresAt)
                {
                    PendingByHandle.Remove(approval.Handle);
                    approval.State = ApprovalState.ExpiredDeclinePending;
                    approval.NextExpiryAttemptAt = now;
                    Console.WriteLine("Approval expired; auto-decline queued: " + approval.Handle + "  " + ApprovalLabel(approval));
                }
                if (approval.State == ApprovalState.ExpiredDeclinePending && now >= approval.NextExpiryAttemptAt)
                {
                    approval.NextExpiryAttemptAt = now.AddSeconds(1);
                    due.Add(approval);
                }
            }
        }
        return due;
    }

    private static void SendExpiredDecline(PendingApproval approval)
    {
        string requestKey = RequestKey(approval.RequestId);
        lock (Sync)
        {
            PendingApproval current;
            if (!ActiveByRequestId.TryGetValue(requestKey, out current) || !object.ReferenceEquals(current, approval) || approval.State != ApprovalState.ExpiredDeclinePending) return;
        }
        try
        {
            SendDecision(approval, "decline");
            CompleteApproval(approval);
            Interlocked.Increment(ref ExpiredDeclineCount);
            Console.WriteLine("Expired approval auto-declined: " + approval.Handle + "  " + ApprovalLabel(approval));
        }
        catch (Exception ex)
        {
            bool stillActive;
            lock (Sync)
            {
                PendingApproval current;
                stillActive = ActiveByRequestId.TryGetValue(requestKey, out current) && object.ReferenceEquals(current, approval);
            }
            if (stillActive && !Stopping) Console.Error.WriteLine("Expired approval auto-decline send failed; retrying: " + ex.Message);
        }
    }

    private static void HandleAppServerMessage(IDictionary message)
    {
        string method = message.Contains("method") ? Convert.ToString(message["method"]) : null;
        if (IsFileLifecycleMethod(method))
        {
            lock (Sync)
            {
                if (Resuming)
                {
                    QuarantinedFileMessages.Add(message);
                    return;
                }
            }
        }
        HandleAppServerMessageCore(message);
    }

    private static bool IsFileLifecycleMethod(string method)
    {
        return string.Equals(method, "item/started", StringComparison.Ordinal) ||
               string.Equals(method, "item/fileChange/patchUpdated", StringComparison.Ordinal) ||
               string.Equals(method, "item/fileChange/requestApproval", StringComparison.Ordinal) ||
               string.Equals(method, "item/completed", StringComparison.Ordinal);
    }

    private static void HandleAppServerMessageCore(IDictionary message)
    {
        string method = message.Contains("method") ? Convert.ToString(message["method"]) : null;

        if (string.Equals(method, "item/commandExecution/requestApproval", StringComparison.Ordinal))
        {
            HandleCommandApprovalRequest(message);
            return;
        }
        if (string.Equals(method, "item/started", StringComparison.Ordinal))
        {
            HandleFileItemSnapshot(message, false);
            return;
        }
        if (string.Equals(method, "item/fileChange/patchUpdated", StringComparison.Ordinal))
        {
            HandlePatchUpdated(message);
            return;
        }
        if (string.Equals(method, "item/fileChange/requestApproval", StringComparison.Ordinal))
        {
            HandleFileApprovalRequest(message);
            return;
        }
        if (string.Equals(method, "item/completed", StringComparison.Ordinal))
        {
            HandleFileItemSnapshot(message, true);
            return;
        }
        if (string.Equals(method, "serverRequest/resolved", StringComparison.Ordinal) && message.Contains("params"))
        {
            IDictionary p = AsDictionary(message["params"]);
            if (!string.Equals(Convert.ToString(p["threadId"]), ThreadId, StringComparison.Ordinal)) return;
            if (!p.Contains("requestId")) return;
            RemoveActiveByRequestId(p["requestId"]);
        }
    }

    private static void HandleCommandApprovalRequest(IDictionary message)
    {
        if (!message.Contains("id") || !message.Contains("params")) return;
        IDictionary p = AsDictionary(message["params"]);
        if (!string.Equals(Convert.ToString(p["threadId"]), ThreadId, StringComparison.Ordinal)) return;
        string requestKey = RequestKey(message["id"]);
        lock (Sync)
        {
            if (ActiveByRequestId.ContainsKey(requestKey) || CompletedRequestIds.Contains(requestKey)) return;
            DateTimeOffset created = DateTimeOffset.UtcNow;
            var approval = new PendingApproval
            {
                Handle = NewHandle(), RequestId = message["id"], Kind = ApprovalKind.Command,
                ThreadId = Convert.ToString(p["threadId"]), TurnId = p.Contains("turnId") ? Convert.ToString(p["turnId"]) : null,
                ItemId = p.Contains("itemId") ? Convert.ToString(p["itemId"]) : null,
                Command = p.Contains("command") ? CommandText(p["command"]) : null,
                Cwd = p.Contains("cwd") ? Convert.ToString(p["cwd"]) : null,
                Reason = p.Contains("reason") ? Convert.ToString(p["reason"]) : null,
                CreatedAt = created, ExpiresAt = created.AddSeconds(ApprovalTtlSeconds), NextExpiryAttemptAt = created,
                State = ApprovalState.Pending
            };
            PendingByHandle.Add(approval.Handle, approval);
            ActiveByRequestId.Add(requestKey, approval);
            Console.WriteLine("Pending command approval: " + approval.Handle + "  " + approval.Command);
        }
    }

    private static void HandleFileItemSnapshot(IDictionary message, bool completed)
    {
        if (!message.Contains("params")) return;
        IDictionary p = AsDictionary(message["params"]);
        string threadId = p.Contains("threadId") ? Convert.ToString(p["threadId"]) : null;
        string turnId = p.Contains("turnId") ? Convert.ToString(p["turnId"]) : null;
        if (!string.Equals(threadId, ThreadId, StringComparison.Ordinal) || !p.Contains("item")) return;
        IDictionary item = AsDictionary(p["item"]);
        if (!string.Equals(Convert.ToString(item["type"]), "fileChange", StringComparison.Ordinal)) return;
        string itemId = item.Contains("id") ? Convert.ToString(item["id"]) : null;
        if (string.IsNullOrWhiteSpace(turnId) || string.IsNullOrWhiteSpace(itemId)) return;
        string itemKey = FileItemKey(threadId, turnId, itemId);

        if (completed)
        {
            lock (Sync)
            {
                TerminalFileItems.Add(itemKey);
                FileEvidenceByItem.Remove(itemKey);
                RemoveActiveFileApprovalByItemLocked(threadId, turnId, itemId);
            }
            return;
        }

        object changes = item.Contains("changes") ? item["changes"] : null;
        FileChangeEvidence evidence = NormalizeFileEvidence(changes);
        ApplyEvidenceUpdate(threadId, turnId, itemId, evidence);
    }

    private static void HandlePatchUpdated(IDictionary message)
    {
        if (!message.Contains("params")) return;
        IDictionary p = AsDictionary(message["params"]);
        string threadId = p.Contains("threadId") ? Convert.ToString(p["threadId"]) : null;
        string turnId = p.Contains("turnId") ? Convert.ToString(p["turnId"]) : null;
        string itemId = p.Contains("itemId") ? Convert.ToString(p["itemId"]) : null;
        if (!string.Equals(threadId, ThreadId, StringComparison.Ordinal) || string.IsNullOrWhiteSpace(turnId) || string.IsNullOrWhiteSpace(itemId)) return;
        FileChangeEvidence evidence = NormalizeFileEvidence(p.Contains("changes") ? p["changes"] : null);
        ApplyEvidenceUpdate(threadId, turnId, itemId, evidence);
    }

    private static void ApplyEvidenceUpdate(string threadId, string turnId, string itemId, FileChangeEvidence evidence)
    {
        string itemKey = FileItemKey(threadId, turnId, itemId);
        lock (Sync)
        {
            if (TerminalFileItems.Contains(itemKey)) return;
            FileEvidenceByItem[itemKey] = evidence;
            foreach (PendingApproval approval in ActiveByRequestId.Values)
            {
                if (approval.Kind != ApprovalKind.FileChange || !ApprovalMatchesItem(approval, threadId, turnId, itemId)) continue;
                string prior = approval.FileEvidence == null ? null : approval.FileEvidence.Signature;
                bool changed = !string.Equals(prior, evidence.Signature, StringComparison.Ordinal);
                approval.FileEvidence = evidence;
                if (!changed) return;

                if (approval.State == ApprovalState.Pending)
                {
                    PendingByHandle.Remove(approval.Handle);
                    approval.Handle = NewHandle();
                    PendingByHandle[approval.Handle] = approval;
                }
                else if (approval.State == ApprovalState.UserClaimed)
                {
                    approval.EvidenceChangedSinceClaim = true;
                }
                return;
            }
        }
    }

    private static void HandleFileApprovalRequest(IDictionary message)
    {
        if (!message.Contains("id") || !message.Contains("params")) return;
        IDictionary p = AsDictionary(message["params"]);
        string threadId = p.Contains("threadId") ? Convert.ToString(p["threadId"]) : null;
        string turnId = p.Contains("turnId") ? Convert.ToString(p["turnId"]) : null;
        string itemId = p.Contains("itemId") ? Convert.ToString(p["itemId"]) : null;
        if (!string.Equals(threadId, ThreadId, StringComparison.Ordinal) || string.IsNullOrWhiteSpace(turnId) || string.IsNullOrWhiteSpace(itemId)) return;
        string requestKey = RequestKey(message["id"]);
        string itemKey = FileItemKey(threadId, turnId, itemId);
        lock (Sync)
        {
            if (ActiveByRequestId.ContainsKey(requestKey) || CompletedRequestIds.Contains(requestKey) || TerminalFileItems.Contains(itemKey)) return;
            FileChangeEvidence evidence;
            if (!FileEvidenceByItem.TryGetValue(itemKey, out evidence)) evidence = UnavailableFileEvidence();
            DateTimeOffset created = DateTimeOffset.UtcNow;
            var approval = new PendingApproval
            {
                Handle = NewHandle(), RequestId = message["id"], Kind = ApprovalKind.FileChange,
                ThreadId = threadId, TurnId = turnId, ItemId = itemId,
                Reason = p.Contains("reason") ? Convert.ToString(p["reason"]) : null,
                FileEvidence = evidence,
                CreatedAt = created, ExpiresAt = created.AddSeconds(ApprovalTtlSeconds), NextExpiryAttemptAt = created,
                State = ApprovalState.Pending
            };
            PendingByHandle.Add(approval.Handle, approval);
            ActiveByRequestId.Add(requestKey, approval);
            Console.WriteLine("Pending file-change approval: " + approval.Handle + "  " + itemId + (evidence.AllowOnceAvailable ? "" : " (deny-only)"));
        }
    }

    private static FileChangeEvidence NormalizeFileEvidence(object rawChanges)
    {
        object[] array = rawChanges as object[];
        if (array == null || array.Length == 0) return UnavailableFileEvidence();
        if (array.Length > MaxFileChangeCount) return OversizedFileEvidence();

        var normalized = new List<object>();
        bool valid = true;
        int utf8Bytes = 0;
        foreach (object raw in array)
        {
            IDictionary change = raw as IDictionary;
            if (change == null) { valid = false; break; }
            string path = change.Contains("path") ? Convert.ToString(change["path"]) : null;
            string diff = change.Contains("diff") ? Convert.ToString(change["diff"]) : null;
            IDictionary kind = change.Contains("kind") ? change["kind"] as IDictionary : null;
            string type = kind != null && kind.Contains("type") ? Convert.ToString(kind["type"]) : null;
            string movePath = kind != null && kind.Contains("move_path") ? Convert.ToString(kind["move_path"]) : null;

            bool recognized = type == "add" || type == "delete" || type == "update";
            bool meaningfulDiff = !string.IsNullOrWhiteSpace(diff);
            bool meaningfulMove = type == "update" && !string.IsNullOrWhiteSpace(movePath);
            if (string.IsNullOrWhiteSpace(path) || !recognized) valid = false;
            if ((type == "add" || type == "delete") && !meaningfulDiff) valid = false;
            if (type == "update" && !meaningfulDiff && !meaningfulMove) valid = false;

            var n = new Dictionary<string, object>
            {
                { "path", path }, { "changeType", type }, { "movePath", string.IsNullOrWhiteSpace(movePath) ? null : movePath },
                { "diff", diff ?? "" }
            };
            normalized.Add(n);
            utf8Bytes += Encoding.UTF8.GetByteCount(path ?? "") + Encoding.UTF8.GetByteCount(type ?? "") + Encoding.UTF8.GetByteCount(movePath ?? "") + Encoding.UTF8.GetByteCount(diff ?? "");
            if (utf8Bytes > MaxFileEvidenceBytes) return OversizedFileEvidence(SummarizeFileChanges(normalized.ToArray()));
        }

        object[] changes = normalized.ToArray();
        string signature = Json.Serialize(changes);
        return new FileChangeEvidence
        {
            Changes = changes,
            Signature = signature,
            AllowOnceAvailable = valid,
            EvidenceStatus = valid ? "complete" : "unavailable"
        };
    }

    private static FileChangeEvidence UnavailableFileEvidence()
    {
        return new FileChangeEvidence { Changes = new object[0], Signature = "unavailable", AllowOnceAvailable = false, EvidenceStatus = "unavailable" };
    }

    private static object[] SummarizeFileChanges(object[] changes)
    {
        var summary = new List<object>();
        foreach (object raw in changes)
        {
            IDictionary change = raw as IDictionary;
            if (change == null) continue;
            summary.Add(new Dictionary<string, object>
            {
                { "path", change.Contains("path") ? change["path"] : null },
                { "changeType", change.Contains("changeType") ? change["changeType"] : null },
                { "movePath", change.Contains("movePath") ? change["movePath"] : null },
                { "diff", "" }
            });
        }
        return summary.ToArray();
    }

    private static FileChangeEvidence OversizedFileEvidence(object[] pathsOnly = null)
    {
        object[] safe = pathsOnly ?? new object[0];
        return new FileChangeEvidence { Changes = safe, Signature = "oversized:" + Json.Serialize(safe), AllowOnceAvailable = false, EvidenceStatus = "incomplete" };
    }

    private static void HandleHttp(TcpClient client)
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
                string[] requestParts = requestLine.Split(' ');
                if (requestParts.Length != 3) { WriteHttpJson(stream, 400, new Dictionary<string, object> { { "error", "bad_request" } }); return; }
                string method = requestParts[0].ToUpperInvariant();
                Uri targetUri;
                if (!Uri.TryCreate("http://127.0.0.1" + requestParts[1], UriKind.Absolute, out targetUri)) { WriteHttpJson(stream, 400, new Dictionary<string, object> { { "error", "bad_request" } }); return; }
                string path = targetUri.AbsolutePath.TrimEnd('/');

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (true)
                {
                    string line = reader.ReadLine();
                    if (line == null || line.Length == 0) break;
                    int colon = line.IndexOf(':');
                    if (colon <= 0) continue;
                    headers[line.Substring(0, colon).Trim()] = line.Substring(colon + 1).Trim();
                }
                if (!IsAuthorized(headers)) { WriteHttpJson(stream, 401, new Dictionary<string, object> { { "error", "unauthorized" } }); return; }

                if (method == "GET" && (path == "" || path == "/health"))
                {
                    WriteHttpJson(stream, 200, new Dictionary<string, object> { { "ok", true }, { "threadId", ThreadId }, { "pendingCount", PendingCount() } }); return;
                }
                if (method == "GET" && path == "/api/status")
                {
                    WriteHttpJson(stream, 200, new Dictionary<string, object>
                    {
                        { "connected", AppSocket != null && AppSocket.State == WebSocketState.Open }, { "threadId", ThreadId }, { "pendingCount", PendingCount() },
                        { "approvalTtlSeconds", ApprovalTtlSeconds }, { "expiredDeclineCount", Volatile.Read(ref ExpiredDeclineCount) }
                    }); return;
                }
                if (method == "GET" && path == "/api/approvals")
                {
                    WriteHttpJson(stream, 200, new Dictionary<string, object> { { "data", SnapshotPending() } }); return;
                }
                if (method == "POST" && path.StartsWith("/api/approvals/", StringComparison.Ordinal))
                {
                    string[] parts = path.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length == 4 && parts[0] == "api" && parts[1] == "approvals" && (parts[3] == "accept" || parts[3] == "decline"))
                    {
                        ResolveApproval(stream, parts[2], parts[3]); return;
                    }
                }
                WriteHttpJson(stream, 404, new Dictionary<string, object> { { "error", "not_found" } });
            }
            catch (IOException) { }
            catch (Exception ex)
            {
                try { WriteHttpJson(client.GetStream(), 500, new Dictionary<string, object> { { "error", "internal_error" }, { "message", ex.Message } }); } catch { }
            }
        }
    }

    private static void ResolveApproval(NetworkStream stream, string handle, string decision)
    {
        PendingApproval approval;
        lock (Sync)
        {
            if (!PendingByHandle.TryGetValue(handle, out approval) || approval.State != ApprovalState.Pending)
            {
                WriteHttpJson(stream, 409, new Dictionary<string, object> { { "error", "stale_or_resolved" } }); return;
            }
            if (approval.Kind == ApprovalKind.FileChange && decision == "accept" && (approval.FileEvidence == null || !approval.FileEvidence.AllowOnceAvailable))
            {
                WriteHttpJson(stream, 409, new Dictionary<string, object> { { "error", "allow_unavailable" } }); return;
            }
            PendingByHandle.Remove(handle);
            if (DateTimeOffset.UtcNow >= approval.ExpiresAt)
            {
                approval.State = ApprovalState.ExpiredDeclinePending;
                approval.NextExpiryAttemptAt = DateTimeOffset.UtcNow;
                WriteHttpJson(stream, 409, new Dictionary<string, object> { { "error", "stale_or_resolved" } }); return;
            }
            approval.State = ApprovalState.UserClaimed;
            approval.ClaimedEvidenceSignature = approval.FileEvidence == null ? null : approval.FileEvidence.Signature;
            approval.EvidenceChangedSinceClaim = false;
        }

        try
        {
            SendDecision(approval, decision);
            CompleteApproval(approval);
            WriteHttpJson(stream, 200, new Dictionary<string, object> { { "ok", true }, { "handle", handle }, { "decision", decision } });
        }
        catch
        {
            RestoreAfterUserDecisionFailure(approval);
            throw;
        }
    }

    private static void SendDecision(PendingApproval approval, string decision)
    {
        SendObject(new Dictionary<string, object> { { "id", approval.RequestId }, { "result", new Dictionary<string, object> { { "decision", decision } } } });
    }

    private static void CompleteApproval(PendingApproval approval)
    {
        string requestKey = RequestKey(approval.RequestId);
        lock (Sync)
        {
            PendingByHandle.Remove(approval.Handle);
            PendingApproval current;
            if (ActiveByRequestId.TryGetValue(requestKey, out current) && object.ReferenceEquals(current, approval)) ActiveByRequestId.Remove(requestKey);
            CompletedRequestIds.Add(requestKey);
        }
    }

    private static void RestoreAfterUserDecisionFailure(PendingApproval approval)
    {
        string requestKey = RequestKey(approval.RequestId);
        lock (Sync)
        {
            PendingApproval current;
            if (!ActiveByRequestId.TryGetValue(requestKey, out current) || !object.ReferenceEquals(current, approval) || approval.State != ApprovalState.UserClaimed) return;
            if (DateTimeOffset.UtcNow >= approval.ExpiresAt)
            {
                approval.State = ApprovalState.ExpiredDeclinePending;
                approval.NextExpiryAttemptAt = DateTimeOffset.UtcNow;
                return;
            }
            approval.State = ApprovalState.Pending;
            if (approval.Kind == ApprovalKind.FileChange && approval.EvidenceChangedSinceClaim) approval.Handle = NewHandle();
            PendingByHandle[approval.Handle] = approval;
        }
    }

    private static object[] SnapshotPending()
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        lock (Sync)
        {
            var list = new List<object>();
            foreach (PendingApproval a in PendingByHandle.Values)
            {
                if (a.State != ApprovalState.Pending || now >= a.ExpiresAt) continue;
                var item = new Dictionary<string, object>
                {
                    { "handle", a.Handle }, { "kind", a.Kind == ApprovalKind.Command ? "command" : "fileChange" },
                    { "threadId", a.ThreadId }, { "turnId", a.TurnId }, { "itemId", a.ItemId }, { "reason", a.Reason },
                    { "createdAt", a.CreatedAt.ToString("o") }, { "expiresAt", a.ExpiresAt.ToString("o") }
                };
                if (a.Kind == ApprovalKind.Command)
                {
                    item["command"] = a.Command;
                    item["cwd"] = a.Cwd;
                }
                else
                {
                    FileChangeEvidence evidence = a.FileEvidence ?? UnavailableFileEvidence();
                    item["evidenceStatus"] = evidence.EvidenceStatus;
                    item["allowOnceAvailable"] = evidence.AllowOnceAvailable;
                    item["changes"] = evidence.Changes;
                }
                list.Add(item);
            }
            return list.ToArray();
        }
    }

    private static int PendingCount()
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        lock (Sync)
        {
            int count = 0;
            foreach (PendingApproval a in PendingByHandle.Values) if (a.State == ApprovalState.Pending && now < a.ExpiresAt) count++;
            return count;
        }
    }

    private static void RemoveActiveByRequestId(object requestId)
    {
        string key = RequestKey(requestId);
        lock (Sync)
        {
            PendingApproval approval;
            if (ActiveByRequestId.TryGetValue(key, out approval))
            {
                PendingByHandle.Remove(approval.Handle);
                ActiveByRequestId.Remove(key);
            }
            CompletedRequestIds.Add(key);
        }
    }

    private static void RemoveActiveFileApprovalByItemLocked(string threadId, string turnId, string itemId)
    {
        var removeKeys = new List<string>();
        foreach (KeyValuePair<string, PendingApproval> pair in ActiveByRequestId)
        {
            PendingApproval a = pair.Value;
            if (a.Kind == ApprovalKind.FileChange && ApprovalMatchesItem(a, threadId, turnId, itemId))
            {
                PendingByHandle.Remove(a.Handle);
                removeKeys.Add(pair.Key);
            }
        }
        foreach (string key in removeKeys)
        {
            ActiveByRequestId.Remove(key);
            CompletedRequestIds.Add(key);
        }
    }

    private static bool ApprovalMatchesItem(PendingApproval a, string threadId, string turnId, string itemId)
    {
        return string.Equals(a.ThreadId, threadId, StringComparison.Ordinal) && string.Equals(a.TurnId, turnId, StringComparison.Ordinal) && string.Equals(a.ItemId, itemId, StringComparison.Ordinal);
    }

    private static string FileItemKey(string threadId, string turnId, string itemId)
    {
        return (threadId ?? "") + "\n" + (turnId ?? "") + "\n" + (itemId ?? "");
    }

    private static string ApprovalLabel(PendingApproval approval)
    {
        return approval.Kind == ApprovalKind.Command ? (approval.Command ?? "command") : (approval.ItemId ?? "file change");
    }

    private static string NewHandle() { return Guid.NewGuid().ToString("N"); }

    private static bool IsAuthorized(IDictionary<string, string> headers)
    {
        string header;
        if (!headers.TryGetValue("Authorization", out header)) return false;
        if (string.IsNullOrWhiteSpace(header) || !header.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        return FixedTimeEquals(ApiToken, header.Substring("Bearer ".Length).Trim());
    }

    private static bool FixedTimeEquals(string a, string b)
    {
        if (a == null || b == null) return false;
        byte[] aa = Encoding.UTF8.GetBytes(a); byte[] bb = Encoding.UTF8.GetBytes(b);
        int diff = aa.Length ^ bb.Length; int max = Math.Max(aa.Length, bb.Length);
        for (int i = 0; i < max; i++) diff |= (i < aa.Length ? aa[i] : (byte)0) ^ (i < bb.Length ? bb[i] : (byte)0);
        return diff == 0;
    }

    private static void SendRequest(int id, string method, object parameters)
    {
        var obj = new Dictionary<string, object> { { "id", id }, { "method", method } };
        if (parameters != null) obj["params"] = parameters;
        SendObject(obj);
    }

    private static void SendObject(object obj)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(Json.Serialize(obj));
        lock (SendSync)
        {
            using (var cts = new CancellationTokenSource(10000)) AppSocket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();
        }
    }

    private static IDictionary ReceiveResponseForId(string expectedId, int timeoutMs, bool processOtherMessages)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            int remaining = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
            string text = ReceiveText(remaining);
            if (text == null) throw new IOException("App-server closed while waiting for response id " + expectedId + ".");
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
                CancellationToken token = CancellationToken.None; CancellationTokenSource cts = null;
                if (timeoutMs != Timeout.Infinite) { cts = new CancellationTokenSource(timeoutMs); token = cts.Token; }
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
        object value = Json.DeserializeObject(text); IDictionary d = value as IDictionary;
        if (d == null) throw new InvalidDataException("Expected JSON object."); return d;
    }
    private static IDictionary AsDictionary(object value)
    {
        IDictionary d = value as IDictionary; if (d == null) throw new InvalidDataException("Expected JSON object field."); return d;
    }

    private static void WriteHttpJson(NetworkStream stream, int status, object body)
    {
        byte[] bodyBytes = Encoding.UTF8.GetBytes(Json.Serialize(body));
        string reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : "Internal Server Error";
        string headers = "HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " + bodyBytes.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
        stream.Write(headerBytes, 0, headerBytes.Length); stream.Write(bodyBytes, 0, bodyBytes.Length); stream.Flush();
    }

    private static string CommandText(object command)
    {
        object[] array = command as object[];
        if (array != null) { var parts = new List<string>(); foreach (object item in array) parts.Add(Convert.ToString(item)); return string.Join(" ", parts.ToArray()); }
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
            string arg = args[i]; if (!arg.StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Unexpected argument: " + arg);
            string key = arg.Substring(2); if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --" + key); result[key] = args[++i];
        }
        return result;
    }

    private static string Require(Dictionary<string, string> args, string key)
    {
        string value; if (!args.TryGetValue(key, out value) || string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Missing required --" + key + "."); return value;
    }

    private static void ValidateLoopbackWebSocket(string value)
    {
        Uri uri; if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || !string.Equals(uri.Scheme, "ws", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Bridge URI is not ws://.");
        if (uri.Host != "127.0.0.1" && uri.Host != "localhost" && uri.Host != "::1") throw new InvalidOperationException("Bridge URI is not loopback.");
    }

    private static void WriteCompanionDescriptor(string path, string apiBase, string tokenFile, string bridgeDescriptor, string threadId)
    {
        var d = new Dictionary<string, object>
        {
            { "version", 1 }, { "pid", Process.GetCurrentProcess().Id }, { "api", apiBase }, { "tokenFile", tokenFile },
            { "bridgeDescriptor", bridgeDescriptor }, { "threadId", threadId }, { "approvalTtlSeconds", ApprovalTtlSeconds }, { "createdAt", DateTimeOffset.UtcNow.ToString("o") }
        };
        File.WriteAllText(path, Json.Serialize(d), new UTF8Encoding(false));
    }

    private static string CreateToken()
    {
        byte[] bytes = new byte[32]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        var sb = new StringBuilder(64); foreach (byte b in bytes) sb.Append(b.ToString("x2")); return sb.ToString();
    }

    private static Thread StartBackgroundThread(ThreadStart action, string name)
    {
        var t = new Thread(action) { IsBackground = true, Name = name }; t.Start(); return t;
    }

    private static void SafeDelete(string path) { if (string.IsNullOrWhiteSpace(path)) return; try { File.Delete(path); } catch { } }
}
