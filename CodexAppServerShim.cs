using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class CodexAppServerShim
{
    private const string TargetFileName = "CodexAppServerShim.target";
    private const string TargetOverrideEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_TARGET";
    private const string ActiveEnvironmentVariable = "CODEX_APPROVAL_NOTIFIER_SHIM_ACTIVE";

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

            var childArgs = new List<string>(args ?? new string[0]);
            if (ShouldEnableRemoteControl(childArgs))
            {
                childArgs.Add("--remote-control");
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = targetPath,
                Arguments = BuildCommandLine(childArgs),
                WorkingDirectory = Environment.CurrentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.EnvironmentVariables[ActiveEnvironmentVariable] = "1";

            child = new Process { StartInfo = startInfo };
            if (!child.Start())
            {
                Console.Error.WriteLine("Codex app-server shim failed to start the target process.");
                return 82;
            }

            // App-server is a bidirectional protocol transport. Forward the
            // inherited pipes as raw bytes; do not decode/re-encode lines or
            // normalize line endings, because that is not transport-transparent.
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
        }
    }

    private static void CopyStream(Stream source, Stream destination, bool closeDestination)
    {
        try
        {
            byte[] buffer = new byte[32768];
            while (true)
            {
                int read = source.Read(buffer, 0, buffer.Length);
                if (read <= 0)
                {
                    break;
                }
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
        if (!File.Exists(targetFile))
        {
            return null;
        }

        string configuredTarget = File.ReadAllText(targetFile, Encoding.UTF8).Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(configuredTarget))
        {
            return null;
        }

        return Environment.ExpandEnvironmentVariables(configuredTarget);
    }

    private static bool ShouldEnableRemoteControl(IList<string> args)
    {
        if (args == null || args.Count == 0)
        {
            return false;
        }

        int appServerIndex = -1;
        for (int i = 0; i < args.Count; i++)
        {
            if (string.Equals(args[i], "app-server", StringComparison.OrdinalIgnoreCase))
            {
                appServerIndex = i;
                break;
            }
        }

        if (appServerIndex < 0)
        {
            return false;
        }

        for (int i = appServerIndex + 1; i < args.Count; i++)
        {
            string arg = args[i] ?? string.Empty;
            if (string.Equals(arg, "--remote-control", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (AppServerToolingSubcommands.Contains(arg))
            {
                return false;
            }
        }

        return true;
    }

    private static Thread StartBackgroundThread(ThreadStart action, string name)
    {
        var thread = new Thread(action)
        {
            IsBackground = true,
            Name = name
        };
        thread.Start();
        return thread;
    }

    private static void JoinBriefly(Thread thread)
    {
        if (thread == null)
        {
            return;
        }

        try { thread.Join(1000); } catch { }
    }

    private static string BuildCommandLine(IEnumerable<string> args)
    {
        var builder = new StringBuilder();
        bool first = true;
        foreach (string arg in args)
        {
            if (!first)
            {
                builder.Append(' ');
            }
            builder.Append(QuoteWindowsArgument(arg ?? string.Empty));
            first = false;
        }
        return builder.ToString();
    }

    // Implements the CommandLineToArgvW-compatible quoting rules used for
    // Windows CreateProcess command lines.
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

        if (backslashes > 0)
        {
            builder.Append('\\', backslashes * 2);
        }

        builder.Append('"');
        return builder.ToString();
    }
}
