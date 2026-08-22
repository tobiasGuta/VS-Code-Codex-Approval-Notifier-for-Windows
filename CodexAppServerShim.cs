using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal static class CodexAppServerShim
{
    private const string TargetFileName = "CodexAppServerShim.target";
    private const string ModeFileName = "CodexAppServerShim.mode";
    private const string TargetOverrideEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_TARGET";
    private const string ActiveEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_ACTIVE";
    private const string DisableRemoteControlForTestsEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_DISABLE_REMOTE_CONTROL_FOR_TESTS";
    private const string ForceRemoteControlForTestsEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_FORCE_REMOTE_CONTROL_FOR_TESTS";
    private const string LocalBridgeMode = "local-bridge";

    private static readonly HashSet<string> AppServerToolingSubcommands =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "daemon",
            "proxy",
            "generate-ts",
            "generate-json-schema",
            "generate-internal-json-schema"
        };

    private static int Main(string[] args)
    {
        Process child = null;
        string descriptorPath = null;
        string tokenPath = null;
        try
        {
            string target = ResolveTargetPath();
            if (string.IsNullOrWhiteSpace(target) || !File.Exists(target))
            {
                Console.Error.WriteLine("Codex app-server shim target was not found.");
                return 80;
            }

            string shimPath = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
            string targetPath = Path.GetFullPath(target);
            if (string.Equals(shimPath, targetPath, StringComparison.OrdinalIgnoreCase))
            {
                Console.Error.WriteLine("Codex app-server shim target resolves to the shim itself.");
                return 81;
            }

            var originalArgs = new List<string>(args ?? new string[0]);
            if (ShouldUseLocalBridge(originalArgs))
            {
                return RunLocalBridge(targetPath, originalArgs, out descriptorPath, out tokenPath);
            }

            var childArgs = new List<string>(originalArgs);
            if (ShouldEnableRemoteControl(childArgs))
            {
                childArgs.Add("--remote-control");
            }

            var startInfo = CreateStartInfo(targetPath, childArgs);
            child = new Process { StartInfo = startInfo };
            if (!child.Start())
            {
                Console.Error.WriteLine("Codex app-server shim failed to start the target process.");
                return 82;
            }

            Stream parentStdin = Console.OpenStandardInput();
            Stream parentStdout = Console.OpenStandardOutput();
            Stream parentStderr = Console.OpenStandardError();
            Stream childStdin = child.StandardInput.BaseStream;
            Stream childStdout = child.StandardOutput.BaseStream;
            Stream childStderr = child.StandardError.BaseStream;

            Thread stdinPump = StartBackgroundThread(delegate
            {
                CopyStream(parentStdin, childStdin, true);
            }, "CodexShim-Stdin");

            Thread stdoutPump = StartBackgroundThread(delegate
            {
                CopyStream(childStdout, parentStdout, false);
            }, "CodexShim-Stdout");

            Thread stderrPump = StartBackgroundThread(delegate
            {
                CopyStream(childStderr, parentStderr, false);
            }, "CodexShim-Stderr");

            child.WaitForExit();
            JoinBriefly(stdoutPump);
            JoinBriefly(stderrPump);
            return child.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Codex app-server shim failed: " + ex.Message);
            return 83;
        }
        finally
        {
            if (child != null)
            {
                try
                {
                    if (!child.HasExited)
                    {
                        child.Kill();
                    }
                }
                catch { }
                child.Dispose();
            }
            SafeDelete(descriptorPath);
            SafeDelete(tokenPath);
        }
    }

    private static int RunLocalBridge(
        string targetPath,
        IList<string> originalArgs,
        out string descriptorPath,
        out string tokenPath)
    {
        descriptorPath = null;
        tokenPath = null;
        Process child = null;
        ClientWebSocket socket = null;
        Thread stderrPump = null;
        try
        {
            string runtimeDirectory = GetBridgeRuntimeDirectory();
            Directory.CreateDirectory(runtimeDirectory);

            int shimPid = Process.GetCurrentProcess().Id;
            tokenPath = Path.Combine(runtimeDirectory, "bridge-" + shimPid + ".token");
            descriptorPath = Path.Combine(runtimeDirectory, "bridge-" + shimPid + ".json");
            string token = CreateCapabilityToken();
            File.WriteAllText(tokenPath, token + Environment.NewLine, new UTF8Encoding(false));

            var bridgeArgs = new List<string>(originalArgs);
            bridgeArgs.Add("--listen");
            bridgeArgs.Add("ws://127.0.0.1:0");
            bridgeArgs.Add("--ws-auth");
            bridgeArgs.Add("capability-token");
            bridgeArgs.Add("--ws-token-file");
            bridgeArgs.Add(tokenPath);

            var startInfo = CreateStartInfo(targetPath, bridgeArgs);
            child = new Process { StartInfo = startInfo };
            if (!child.Start())
            {
                throw new InvalidOperationException("Failed to start loopback WebSocket app-server.");
            }

            string wsUri = ReadBoundWebSocketUri(child.StandardError, 30000);
            if (!IsLoopbackWebSocketUri(wsUri))
            {
                throw new InvalidOperationException("Codex app-server reported a non-loopback WebSocket URI: " + wsUri);
            }

            stderrPump = StartBackgroundThread(delegate
            {
                ForwardTextReaderToStderr(child.StandardError);
            }, "CodexBridge-Stderr");

            socket = new ClientWebSocket();
            socket.Options.SetRequestHeader("Authorization", "Bearer " + token);
            var connectCts = new CancellationTokenSource();
            connectCts.CancelAfter(15000);
            try
            {
                socket.ConnectAsync(new Uri(wsUri), connectCts.Token).GetAwaiter().GetResult();
            }
            finally
            {
                connectCts.Dispose();
            }

            if (socket.State != WebSocketState.Open)
            {
                throw new InvalidOperationException("Failed to open bridge WebSocket to Codex app-server.");
            }

            WriteBridgeDescriptor(descriptorPath, shimPid, child.Id, wsUri, tokenPath, targetPath);
            Console.Error.WriteLine("[CodexLocalBridge] Connected to " + wsUri + " (Codex PID " + child.Id + ").");
            Console.Error.WriteLine("[CodexLocalBridge] Descriptor: " + descriptorPath);

            Exception inboundFailure = null;
            Thread inbound = StartBackgroundThread(delegate
            {
                try
                {
                    PumpWebSocketToStdout(socket);
                }
                catch (Exception ex)
                {
                    inboundFailure = ex;
                }
            }, "CodexBridge-WebSocketToStdout");

            try
            {
                PumpStdinToWebSocket(socket);
            }
            finally
            {
                try
                {
                    if (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseReceived)
                    {
                        var closeCts = new CancellationTokenSource();
                        closeCts.CancelAfter(2000);
                        try
                        {
                            socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "stdio closed", closeCts.Token)
                                .GetAwaiter().GetResult();
                        }
                        catch { }
                        finally { closeCts.Dispose(); }
                    }
                }
                catch { }
            }

            JoinBriefly(inbound);
            if (inboundFailure != null)
            {
                throw new InvalidOperationException("WebSocket-to-stdout bridge failed.", inboundFailure);
            }

            try
            {
                if (!child.HasExited)
                {
                    child.Kill();
                }
            }
            catch { }
            child.WaitForExit();
            JoinBriefly(stderrPump);
            return child.ExitCode;
        }
        finally
        {
            if (socket != null)
            {
                try { socket.Dispose(); } catch { }
            }
            if (child != null)
            {
                try
                {
                    if (!child.HasExited)
                    {
                        child.Kill();
                    }
                }
                catch { }
                child.Dispose();
            }
            SafeDelete(descriptorPath);
            SafeDelete(tokenPath);
        }
    }

    private static ProcessStartInfo CreateStartInfo(string targetPath, IList<string> args)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = targetPath,
            Arguments = BuildCommandLine(args),
            WorkingDirectory = Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.EnvironmentVariables[ActiveEnvironmentVariable] = "1";
        return startInfo;
    }

    private static string ReadBoundWebSocketUri(TextReader stderr, int timeoutMilliseconds)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
        var regex = new Regex(@"ws://(?:127\.0\.0\.1|localhost|\[::1\]):\d+", RegexOptions.IgnoreCase);
        var readTask = stderr.ReadLineAsync();

        while (DateTime.UtcNow < deadline)
        {
            int remaining = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
            if (!readTask.Wait(Math.Min(500, remaining)))
            {
                continue;
            }

            string line = readTask.Result;
            if (line == null)
            {
                break;
            }

            Console.Error.WriteLine(line);
            Match match = regex.Match(StripAnsi(line));
            if (match.Success)
            {
                return match.Value;
            }

            readTask = stderr.ReadLineAsync();
        }

        throw new TimeoutException("Timed out waiting for Codex app-server to report its loopback WebSocket URI.");
    }

    private static void ForwardTextReaderToStderr(TextReader reader)
    {
        try
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                Console.Error.WriteLine(line);
                Console.Error.Flush();
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    private static void PumpStdinToWebSocket(ClientWebSocket socket)
    {
        string line;
        while ((line = Console.In.ReadLine()) != null)
        {
            byte[] payload = Encoding.UTF8.GetBytes(line);
            var segment = new ArraySegment<byte>(payload);
            var cts = new CancellationTokenSource();
            cts.CancelAfter(30000);
            try
            {
                socket.SendAsync(segment, WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();
            }
            finally
            {
                cts.Dispose();
            }
        }
    }

    private static void PumpWebSocketToStdout(ClientWebSocket socket)
    {
        byte[] buffer = new byte[65536];
        while (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseSent)
        {
            using (var memory = new MemoryStream())
            {
                WebSocketReceiveResult result;
                do
                {
                    var cts = new CancellationTokenSource();
                    cts.CancelAfter(60000);
                    try
                    {
                        result = socket.ReceiveAsync(new ArraySegment<byte>(buffer), cts.Token)
                            .GetAwaiter().GetResult();
                    }
                    finally
                    {
                        cts.Dispose();
                    }

                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        return;
                    }
                    if (result.MessageType != WebSocketMessageType.Text)
                    {
                        throw new InvalidDataException("Unexpected binary WebSocket frame from Codex app-server.");
                    }
                    if (result.Count > 0)
                    {
                        memory.Write(buffer, 0, result.Count);
                    }
                }
                while (!result.EndOfMessage);

                string message = Encoding.UTF8.GetString(memory.ToArray());
                Console.Out.WriteLine(message);
                Console.Out.Flush();
            }
        }
    }

    private static string GetBridgeRuntimeDirectory()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "CodexApprovalNotifier", "local-bridge");
    }

    private static string CreateCapabilityToken()
    {
        byte[] bytes = new byte[32];
        using (var rng = RandomNumberGenerator.Create())
        {
            rng.GetBytes(bytes);
        }
        var builder = new StringBuilder(bytes.Length * 2);
        for (int i = 0; i < bytes.Length; i++)
        {
            builder.Append(bytes[i].ToString("x2"));
        }
        return builder.ToString();
    }

    private static void WriteBridgeDescriptor(
        string path,
        int shimPid,
        int codexPid,
        string wsUri,
        string tokenPath,
        string targetPath)
    {
        string json = "{" +
            "\"version\":1," +
            "\"shimPid\":" + shimPid + "," +
            "\"codexPid\":" + codexPid + "," +
            "\"uri\":\"" + JsonEscape(wsUri) + "\"," +
            "\"tokenFile\":\"" + JsonEscape(tokenPath) + "\"," +
            "\"target\":\"" + JsonEscape(targetPath) + "\"," +
            "\"createdAt\":\"" + DateTimeOffset.Now.ToString("o") + "\"" +
            "}";
        File.WriteAllText(path, json, new UTF8Encoding(false));
    }

    private static string JsonEscape(string value)
    {
        if (value == null) return string.Empty;
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static bool IsLoopbackWebSocketUri(string value)
    {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri)) return false;
        if (!string.Equals(uri.Scheme, "ws", StringComparison.OrdinalIgnoreCase)) return false;
        return string.Equals(uri.Host, "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(uri.Host, "::1", StringComparison.OrdinalIgnoreCase);
    }

    private static string StripAnsi(string value)
    {
        return Regex.Replace(value ?? string.Empty, "\\x1B\\[[0-?]*[ -/]*[@-~]", string.Empty);
    }

    private static void CopyStream(Stream source, Stream destination, bool closeDestination)
    {
        try
        {
            byte[] buffer = new byte[32768];
            while (true)
            {
                int read = source.Read(buffer, 0, buffer.Length);
                if (read <= 0) break;
                destination.Write(buffer, 0, read);
                destination.Flush();
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            if (closeDestination)
            {
                try { destination.Close(); } catch { }
            }
        }
    }

    private static string ResolveTargetPath()
    {
        string environmentTarget = Environment.GetEnvironmentVariable(TargetOverrideEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(environmentTarget))
        {
            return Environment.ExpandEnvironmentVariables(environmentTarget.Trim().Trim('"'));
        }

        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string targetFile = Path.Combine(baseDirectory, TargetFileName);
        if (!File.Exists(targetFile)) return null;

        string configuredTarget = File.ReadAllText(targetFile, Encoding.UTF8).Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(configuredTarget)) return null;
        return Environment.ExpandEnvironmentVariables(configuredTarget);
    }

    private static string ReadMode()
    {
        string modePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ModeFileName);
        if (!File.Exists(modePath)) return "passthrough";
        return File.ReadAllText(modePath, Encoding.UTF8).Trim();
    }

    private static bool ShouldUseLocalBridge(IList<string> args)
    {
        return IsLiveAppServerInvocation(args) &&
               string.Equals(ReadMode(), LocalBridgeMode, StringComparison.OrdinalIgnoreCase);
    }

    private static bool ShouldEnableRemoteControl(IList<string> args)
    {
        if (string.Equals(
            Environment.GetEnvironmentVariable(DisableRemoteControlForTestsEnvironmentVariable),
            "1",
            StringComparison.Ordinal))
        {
            return false;
        }

        bool forceForTest = string.Equals(
            Environment.GetEnvironmentVariable(ForceRemoteControlForTestsEnvironmentVariable),
            "1",
            StringComparison.Ordinal);

        if (!IsLiveAppServerInvocation(args)) return false;
        if (forceForTest) return true;
        return string.Equals(ReadMode(), "remote-control", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsLiveAppServerInvocation(IList<string> args)
    {
        if (args == null || args.Count == 0) return false;

        int appServerIndex = -1;
        for (int i = 0; i < args.Count; i++)
        {
            if (string.Equals(args[i], "app-server", StringComparison.OrdinalIgnoreCase))
            {
                appServerIndex = i;
                break;
            }
        }
        if (appServerIndex < 0) return false;

        for (int i = appServerIndex + 1; i < args.Count; i++)
        {
            string arg = args[i] ?? string.Empty;
            if (string.Equals(arg, "--remote-control", StringComparison.OrdinalIgnoreCase)) return false;
            if (string.Equals(arg, "--listen", StringComparison.OrdinalIgnoreCase)) return false;
            if (string.Equals(arg, "--help", StringComparison.OrdinalIgnoreCase)) return false;
            if (string.Equals(arg, "-h", StringComparison.OrdinalIgnoreCase)) return false;
            if (AppServerToolingSubcommands.Contains(arg)) return false;
        }
        return true;
    }

    private static Thread StartBackgroundThread(ThreadStart action, string name)
    {
        var thread = new Thread(action) { IsBackground = true, Name = name };
        thread.Start();
        return thread;
    }

    private static void JoinBriefly(Thread thread)
    {
        if (thread == null) return;
        try { thread.Join(1000); } catch { }
    }

    private static void SafeDelete(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try { File.Delete(path); } catch { }
    }

    private static string BuildCommandLine(IEnumerable<string> args)
    {
        var builder = new StringBuilder();
        bool first = true;
        foreach (string arg in args)
        {
            if (!first) builder.Append(' ');
            builder.Append(QuoteWindowsArgument(arg ?? string.Empty));
            first = false;
        }
        return builder.ToString();
    }

    private static string QuoteWindowsArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        var builder = new StringBuilder();
        builder.Append('"');
        int backslashes = 0;

        for (int i = 0; i < value.Length; i++)
        {
            char ch = value[i];
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }
            if (ch == '"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                builder.Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes > 0)
            {
                builder.Append('\\', backslashes);
                backslashes = 0;
            }
            builder.Append(ch);
        }

        if (backslashes > 0) builder.Append('\\', backslashes * 2);
        builder.Append('"');
        return builder.ToString();
    }
}
