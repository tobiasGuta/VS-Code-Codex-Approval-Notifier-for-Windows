using System;
using System.Diagnostics;
using System.IO;

internal static class ActionLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args == null || args.Length < 1 || string.IsNullOrWhiteSpace(args[0]))
        {
            return 0;
        }

        try
        {
            string installDir = AppDomain.CurrentDomain.BaseDirectory;
            string handlerPath = Path.Combine(installDir, "HandleAction.ps1");
            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");

            if (!File.Exists(handlerPath) || !File.Exists(powershellPath))
            {
                return 2;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments =
                    "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " +
                    Quote(handlerPath) + " " + Quote(args[0]),
                WorkingDirectory = installDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(startInfo);
            return 0;
        }
        catch
        {
            return 1;
        }
    }

    private static string Quote(string value)
    {
        if (value == null)
        {
            value = string.Empty;
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
